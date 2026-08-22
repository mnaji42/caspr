import AVFoundation
import Foundation

/// Capture micro, convertie à la volée au format attendu par le moteur.
///
/// Le matériel délivre typiquement du 44,1 ou 48 kHz ; Whisper veut du 16 kHz
/// mono. On convertit pendant l'enregistrement plutôt qu'à la fin : ça étale
/// le coût sur la durée de la dictée au lieu de l'ajouter à la latence
/// perçue, qui commence au relâchement de la touche.
final class AudioRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case noInputDevice
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Accès au micro refusé. Réglages › Confidentialité › Microphone."
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

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.targetSampleRate
    }

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
    /// oublié de mettre ailleurs.
    static var microphoneModeLabel: String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: "Isolement de la voix"
        case .wideSpectrum: "Large spectre"
        default: "Standard"
        }
    }

    /// Ouvre le panneau de macOS où ce mode se change.
    static func showMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
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
        guard !isRunning else { return }

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

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        level = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            append(buffer, using: converter, outputFormat: outputFormat)
            onBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Arrête la capture et rend les échantillons accumulés.
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else { return [] }
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
