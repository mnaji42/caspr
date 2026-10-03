import AVFoundation
import Foundation

/// Capture micro, convertie à la volée en 16 kHz mono.
///
/// Le matériel délivre typiquement du 44,1 ou 48 kHz. Le 16 kHz est un héritage
/// du moteur local, qui l'exigeait ; il reste parce qu'il suffit à la voix et
/// tient une longue dictée en trois fois moins de mémoire. `SpeechTranscriber`
/// le reconvertit au format de son analyseur (cf. `AppleSpeechEngine.ceder`),
/// `SFSpeechRecognizer` le prend tel quel.
///
/// On convertit pendant l'enregistrement plutôt qu'à la fin : ça étale le coût
/// sur la durée de la dictée au lieu de l'ajouter à la latence perçue, qui
/// commence au relâchement de la touche.
final class AudioRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "Aucun micro disponible."
            case .converterUnavailable:
                return "Conversion audio impossible."
            }
        }
    }

    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var isRunning = false

    /// Second consommateur des tampons micro, pour l'aperçu en direct.
    ///
    /// Les tampons sont passés **bruts**, au format du matériel : l'aperçu
    /// utilise un autre moteur, qui réclame son propre format. Le convertir
    /// deux fois coûterait moins cher que de le convertir mal.
    ///
    /// Appelé depuis le thread audio : ce qui est fait ici doit être court et
    /// ne jamais bloquer, sous peine de trous dans l'enregistrement.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Niveau sonore courant, entre 0 et 1, pour l'indicateur d'enregistrement.
    ///
    /// Lissé par une moyenne mobile : la valeur brute par tampon saute trop
    /// pour donner un affichage lisible, et un indicateur qui clignote
    /// n'apprend rien à l'utilisateur sur le fait qu'on l'entend.
    private(set) var level: Float = 0

    private func updateLevel(_ frame: UnsafeBufferPointer<Float>) {
        var sum: Float = 0
        for value in frame { sum += value * value }
        let rms = (sum / Float(max(frame.count, 1))).squareRoot()
        // Échelle racine : la perception sonore est loin d'être linéaire, et
        // une voix normale occuperait sinon le bas de la jauge.
        let scaled = min(1, (rms * 8).squareRoot())
        level += (scaled - level) * 0.3
    }

    enum MicrophoneAccess {
        case granted
        /// Jamais demandé : c'est le seul état où macOS acceptera d'afficher
        /// le dialogue système.
        case undetermined
        /// Refusé ou restreint : plus aucun dialogue possible, il faut passer
        /// par les Réglages Système.
        case denied
    }

    /// Mode micro courant, tel que macOS le rapporte.
    ///
    /// **Lecture seule, et c'est une contrainte du système, pas un oubli.**
    /// Apple ne laisse aucune application imposer ce réglage : il vaut pour
    /// toutes les apps à la fois, et c'est l'utilisateur qui le choisit. Tout
    /// ce qu'on peut faire est l'afficher et ouvrir le panneau système.
    ///
    /// Partagé entre la barre et les réglages : la barre l'affichait seule,
    /// ce qui laissait croire que c'était un réglage de dictée qu'on avait
    /// oublié de mettre ailleurs. Les réglages le disent en entier, la barre
    /// en un mot — elle n'a pas la place.
    static var microphoneModeLabel: String { microphoneMode(court: false) }
    static var microphoneModeShortLabel: String { microphoneMode(court: true) }

    private static func microphoneMode(court: Bool) -> String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: court ? "Isolement" : "Isolement de la voix"
        case .wideSpectrum: court ? "Large" : "Large spectre"
        default: "Standard"
        }
    }

    static var microphoneAccess: MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    /// Déclenche le dialogue système d'autorisation micro.
    ///
    /// À n'appeler que sur `.undetermined` : une fois l'utilisateur passé par
    /// un refus, `requestAccess` retourne `false` sans rien afficher, et l'app
    /// semble cassée sans explication.
    ///
    /// Le dialogue est présenté par le système mais s'affiche derrière les
    /// autres fenêtres tant que l'app reste en arrière-plan — ce qui est le
    /// cas permanent d'une app de barre de menus. L'appelant doit donc activer
    /// l'app avant (cf. CasprApp.requestMicrophoneIfNeeded).
    static func requestPermission() async -> Bool {
        guard microphoneAccess == .undetermined else {
            return microphoneAccess == .granted
        }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        // Avant la garde, et non après : un démarrage sur un magnétophone
        // resté en marche sortait ici en silence, en gardant l'audio de la
        // dictée précédente — la suivante rendait alors deux phrases collées.
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !isRunning else { return }
        coupure = nil
        level = 0
        formatEntree = try brancher()
        isRunning = true
        observateur = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.suivreLeChangementDeMicro() }
    }

    /// Où la capture s'est arrêtée, en secondes, quand un changement de micro
    /// n'a pas pu être suivi ; `nil` quand elle a tout reçu.
    ///
    /// Gardé jusqu'au démarrage suivant, pour que la barre le dise une fois
    /// l'audio rendu : ce qui précède la coupure est livré, mais présenté
    /// comme une dictée entière, la fin perdue passait inaperçue.
    private(set) var coupure: TimeInterval?
    private var formatEntree: AVAudioFormat?
    private var observateur: NSObjectProtocol?

    /// Pose le tap au format actuel de l'entrée, et démarre le moteur ; rend
    /// ce format.
    private func brancher() throws -> AVAudioFormat {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.converterUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            append(buffer, using: converter, outputFormat: outputFormat)
            onBuffer?(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Le tap survivrait à l'échec : `stop()` ne le retire que si l'on
            // a démarré, et le `installTap` suivant sur le même bus ferait
            // planter l'app — une exception d'AVFoundation, que Swift ne
            // rattrape pas. Le même magnétophone sert toute la vie de l'app.
            input.removeTap(onBus: 0)
            engine.reset()
            self.converter = nil
            throw error
        }
        return inputFormat
    }

    /// Reprend la capture sur le nouveau micro.
    ///
    /// Des AirPods qui se connectent, un casque débranché, une bascule
    /// Bluetooth : macOS arrête alors le moteur et publie
    /// `AVAudioEngineConfigurationChange`. Le tap ne recevait plus rien, la
    /// jauge restait figée, et l'arrêt rendait le début de la dictée comme si
    /// c'était toute la dictée. La suite s'ajoute à l'audio déjà acquis,
    /// convertie au même 16 kHz ; l'aperçu, qui reçoit les tampons bruts, les
    /// reçoit désormais à la fréquence du nouveau micro.
    private func suivreLeChangementDeMicro() {
        guard isRunning else { return }
        let ancien = formatEntree.map(Self.decrire) ?? "?"
        let niveau = level
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            let nouveau = try brancher()
            formatEntree = nouveau
            Log.info("micro changé (\(ancien) → \(Self.decrire(nouveau))), capture reprise ; "
                     + "niveau \(String(format: "%.3f", niveau))")
        } catch {
            lock.lock()
            let secondes = Double(samples.count) / Self.targetSampleRate
            lock.unlock()
            coupure = secondes
            level = 0
            Log.error("micro changé (\(ancien) → \(Self.decrire(engine.inputNode.inputFormat(forBus: 0)))), "
                      + "capture interrompue à \(String(format: "%.1f", secondes)) s : "
                      + "\(error.localizedDescription) ; niveau \(String(format: "%.3f", niveau))")
        }
    }

    private static func decrire(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz, \(format.channelCount) can."
    }

    /// Arrête la capture et rend les échantillons accumulés.
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else { return [] }
        if let observateur { NotificationCenter.default.removeObserver(observateur) }
        observateur = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil

        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        return captured
    }

    func cancel() {
        _ = stop()
    }

    /// Rend un enregistrement aux moteurs, une seconde à la fois, au format
    /// où il a été capturé : 16 kHz mono en flottants.
    ///
    /// Tranche par tranche plutôt qu'en un tableau de tous les tampons : une
    /// dictée de dix minutes pèse déjà près de 40 Mo, et la doubler d'un coup
    /// n'apporte rien à des moteurs qui la lisent en flux.
    static func parSeconde(_ samples: [Float], _ corps: (AVAudioPCMBuffer) -> Void) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
                                         channels: 1, interleaved: false) else { return }
        let seconde = Int(targetSampleRate)
        var debut = 0
        while debut < samples.count {
            let compte = min(seconde, samples.count - debut)
            guard let tampon = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(compte)) else { return }
            tampon.frameLength = AVAudioFrameCount(compte)
            samples[debut..<(debut + compte)].withUnsafeBufferPointer { source in
                tampon.floatChannelData![0].update(from: source.baseAddress!, count: compte)
            }
            corps(tampon)
            debut += compte
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer,
                        using converter: AVAudioConverter,
                        outputFormat: AVAudioFormat) {
        // Le ré-échantillonnage change le nombre de trames : on dimensionne la
        // sortie au ratio des fréquences, avec une trame de marge pour les
        // arrondis.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            // Un seul buffer disponible par appel : au second passage on
            // signale la fin d'entrée, sinon le convertisseur boucle.
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, out.frameLength > 0,
              let channel = out.floatChannelData?[0] else { return }

        let converted = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        updateLevel(converted)
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()

    }
}
