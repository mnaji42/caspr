import AVFoundation
import Foundation
import Speech
import CasprCore

/// Le moteur de la dictée de macOS, celui qui existe depuis toujours.
///
/// C'est l'autre reconnaissance vocale d'Apple : `SFSpeechRecognizer`,
/// disponible depuis macOS 10.15, celle qui fait fonctionner la Dictée du
/// système. `SpeechTranscriber` — l'API de macOS 26 qu'utilise
/// `AppleSpeechEngine` — est plus récente et taillée pour la transcription
/// longue, mais elle exige macOS 26, une puce Apple Silicon, et des modèles
/// livrés avec Apple Intelligence.
///
/// Cette contrainte laissait des Mac entiers sans aucun moteur : un Mac Intel
/// sous macOS 26 n'a pas Apple Intelligence, alors que la
/// Dictée d'Apple y fonctionne parfaitement. Le constat est venu d'une machine
/// virtuelle où la Dictée dictait très bien pendant que Caspr annonçait
/// qu'aucune langue n'était disponible — deux familles d'actifs distinctes,
/// `UAF_Siri_UnderstandingASRHammer` d'un côté,
/// `UAF_Speech_AutomaticSpeechRecognition` de l'autre.
///
/// Mesuré sur cette machine, ce moteur couvre **63 langues** contre 30.
///
/// ## Tout reste sur la machine, ou rien ne se fait
///
/// `SFSpeechRecognizer` envoie l'audio aux serveurs d'Apple **par défaut**.
/// Caspr promet exactement l'inverse, et cette promesse ne se négocie pas :
/// `requiresOnDeviceRecognition` est donc forcé, et si la machine ne sait pas
/// reconnaître hors ligne, ce moteur se déclare indisponible au lieu de
/// transmettre quoi que ce soit. Un repli qui trahirait la promesse serait
/// pire que l'absence de repli.
final class LegacySpeechEngine: TranscripteurMacOS {
    enum EngineError: LocalizedError {
        case unavailable
        case notAuthorised
        case offlineUnsupported(String)
        case dictationDisabled

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "La dictée de macOS n'est pas disponible pour cette langue."
            case .dictationDisabled:
                SystemDictation.instruction
            case .notAuthorised:
                "macOS n'a pas autorisé Caspr à utiliser la reconnaissance "
                    + "vocale. Réglages Système › Confidentialité et sécurité › "
                    + "Reconnaissance vocale."
            case .offlineUnsupported(let code):
                "macOS ne sait pas reconnaître « \(code) » hors ligne sur cette "
                    + "machine. Caspr n'enverra pas votre voix à un serveur "
                    + "sans que vous l'ayez choisi : dictez dans une autre "
                    + "langue, ou passez par ChatGPT dans l'onglet Voie."
            }
        }
    }

    // MARK: - Disponibilité

    /// Ce moteur peut-il travailler pour cette langue, **sans réseau** ?
    ///
    /// Les deux conditions comptent autant l'une que l'autre : un
    /// `SFSpeechRecognizer` disponible mais incapable de travailler hors ligne
    /// ne nous sert à rien, puisqu'on ne l'utilisera jamais dans ce mode.
    static func isAvailable(for language: String) -> Bool {
        guard let recognizer = recognizer(for: language) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    /// Pourquoi cette langue ne marche pas, quand elle ne marche pas.
    ///
    /// « Aucun moteur de macOS n'est utilisable » était vrai et inutilisable :
    /// sur une machine où la Dictée a été activée en français, l'anglais n'a
    /// simplement pas ses modèles, et il suffit de les ajouter. Distinguer les
    /// deux cas change une impasse en une action.
    @MainActor
    static func unavailabilityReason(for language: String) -> String? {
        // Passe avant tout le reste, y compris avant `isAvailable` : avec la
        // Dictée éteinte, ce dernier peut très bien répondre « oui » — c'est le
        // cas mesuré sur la machine virtuelle — et on expliquerait alors une
        // absence de modèles là où il n'y a qu'un interrupteur à basculer.
        if SystemDictation.isDisabled { return SystemDictation.instruction }
        if isAvailable(for: language) { return nil }
        // Les autres langues déclarées par l'utilisateur, et non un couple
        // codé en dur : c'est parmi celles-là qu'il reconnaîtra « ah oui,
        // l'espagnol marche », et le message n'a d'intérêt que s'il parle
        // d'une langue qui le concerne.
        let others = Preferences.shared.selectedLanguages.filter { $0 != language }
        let elsewhere = others.first { isAvailable(for: $0) }
        let name = Language.named(language).displayName

        if let elsewhere {
            let working = Language.named(elsewhere).displayName
            return "La Dictée de macOS fonctionne ici en \(working), mais pas "
                + "encore en \(name) : ses modèles ne sont pas installés. "
                + "Ajoutez la langue dans Réglages Système › Clavier › Dictée, "
                + "puis revenez — Caspr la verra aussitôt."
        }
        return "La Dictée de macOS n'est pas activée sur cette machine. "
            + "Activez-la dans Réglages Système › Clavier › Dictée : c'est "
            + "elle qui installe les modèles dont Caspr se sert."
    }

    /// Le reconnaisseur d'une langue, résolu par la liste du système.
    ///
    /// La version précédente concaténait « -FR » quand le code court ne
    /// suffisait pas — ce qui donnait « en-FR » pour l'anglais, un identifiant
    /// qui n'existe pas. D'où un moteur nul et un « transcription impossible »
    /// en anglais pendant que le français marchait : la faute n'était pas dans
    /// l'accent, elle était dans cette ligne.
    ///
    /// La région de la machine passe en premier — un francophone au Canada
    /// veut `fr-CA` — puis n'importe quelle région de la même langue.
    static func recognizer(for language: String) -> SFSpeechRecognizer? {
        if let exact = SFSpeechRecognizer(locale: Locale(identifier: language)),
           exact.isAvailable { return exact }

        let code = Locale(identifier: language).language.languageCode?.identifier
            ?? language
        let here = Locale.current.region?.identifier
        let candidates = SFSpeechRecognizer.supportedLocales()
            .filter { $0.language.languageCode?.identifier == code }
            .sorted { a, _ in a.region?.identifier == here }
        for locale in candidates {
            if let found = SFSpeechRecognizer(locale: locale), found.isAvailable {
                return found
            }
        }
        return nil
    }

    /// Demande l'autorisation, une fois.
    ///
    /// Distincte du micro : macOS considère la reconnaissance vocale comme un
    /// droit séparé, et l'accorder ne dit rien de l'autre. Demandée au moment
    /// où ce moteur est retenu, pas au lancement — inutile d'inquiéter
    /// quelqu'un qui ne s'en servira jamais.
    static func requestAuthorisation() async -> Bool {
        // Comme `AudioRecorder.requestPermission` : hors de `.undetermined`, on
        // rend l'état tel quel plutôt que d'appeler un dialogue qui ne viendra
        // pas. L'appelant doit alors mener vers les Réglages Système.
        guard authorisation == .undetermined else { return authorisation == .granted }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Les trois états qui comptent, exactement comme pour le micro.
    ///
    /// C'est la même mécanique TCC, et donc le **même piège** : macOS ne
    /// présente son dialogue qu'une fois. Passé un refus — ou une révocation
    /// depuis les Réglages Système — `requestAuthorization` rappelle aussitôt
    /// avec `.denied` sans rien afficher. Un bouton « Accorder » y est un
    /// bouton qui ne fait rien, et l'application paraît cassée sans dire
    /// pourquoi. Réduire tout ça à un booléen rendait cette distinction
    /// impossible à faire côté interface : `AudioRecorder.MicrophoneAccess`
    /// l'avait, celui-ci non.
    enum Authorisation {
        case granted
        /// Jamais demandé : le seul état où le dialogue s'affichera.
        case undetermined
        /// Refusé, révoqué ou restreint : plus aucun dialogue possible.
        case denied
    }

    static var authorisation: Authorisation {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    static var isAuthorised: Bool { authorisation == .granted }

    // MARK: - Transcription

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        // Le premier examiné, parce que c'est celui qu'aucun autre ne révèle :
        // sur un Mac dont la Dictée est éteinte, le recogniseur se déclare
        // disponible, accepte la tâche, et ne rend jamais rien. Ce qui
        // remontait alors, c'était « Transcription impossible » — vrai, et sans
        // le moindre indice sur ce qu'il fallait faire.
        guard !SystemDictation.isDisabled else {
            throw EngineError.dictationDisabled
        }
        guard let recognizer = Self.recognizer(for: language) else {
            throw EngineError.unavailable
        }
        guard recognizer.isAvailable else { throw EngineError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else {
            throw EngineError.offlineUnsupported(language)
        }
        guard await Self.requestAuthorisation() else { throw EngineError.notAuthorised }

        let audio = SFSpeechAudioBufferRecognitionRequest()
        // La ligne qui tient la promesse. Sans elle, l'audio partirait chez
        // Apple — ce que Caspr garantit ne jamais faire.
        audio.requiresOnDeviceRecognition = true
        audio.shouldReportPartialResults = false

        for buffer in Self.buffers(from: samples) {
            audio.append(buffer)
        }
        audio.endAudio()

        let text: String = try await withCheckedThrowingContinuation { continuation in
            // `resume` ne doit partir qu'une fois : le rappel est appelé à
            // chaque résultat, et une erreur peut suivre un résultat final.
            let done = Guard()
            recognizer.recognitionTask(with: audio) { result, error in
                if let error {
                    if done.claim() { continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                if done.claim() {
                    continuation.resume(
                        returning: result.bestTranscription.formattedString)
                }
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Outils

    /// Découpe les échantillons en tampons, au format que le moteur attend.
    ///
    /// `SFSpeechAudioBufferRecognitionRequest` accepte du PCM flottant à la
    /// fréquence d'origine : pas de conversion nécessaire, contrairement à
    /// l'analyseur de macOS 26 qui impose la sienne.
    private static func buffers(from samples: [Float]) -> [AVAudioPCMBuffer] {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioRecorder.targetSampleRate,
                                         channels: 1, interleaved: false)
        else { return [] }

        let chunk = 16_000                     // une seconde
        var out: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples[offset..<(offset + count)].withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: count)
            }
            out.append(buffer)
            offset += count
        }
        return out
    }

    /// Un verrou minuscule : le premier qui réclame gagne.
    private final class Guard: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}
