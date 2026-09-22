import AVFoundation
import Foundation
import Speech
import CasprCore

/// Le moteur de reconnaissance de macOS, en transcription complète.
///
/// C'est le même que celui de l'aperçu en direct, utilisé autrement : là on
/// lui donne l'enregistrement entier d'un coup et on attend son texte
/// définitif, plutôt que de suivre ses résultats volatils.
///
/// Il vient avec le système : rien à télécharger, aucune licence à accepter,
/// et il fonctionne sur toute machine en macOS 26. C'est ce qui en fait le
/// moteur par défaut. Sa limite est connue et mesurée : il n'a **pas** de
/// conditionnement par vocabulaire exploitable — `contextualStrings` existe
/// mais reste sans effet sur nos enregistrements — donc il n'écrira jamais
/// `useEffect`. Et il n'a qu'un rendu, sans distinction nettoyé/mot-à-mot.
@available(macOS 26.0, *)
final class AppleSpeechEngine: SpeechEngine, @unchecked Sendable {
    enum EngineError: LocalizedError {
        case unavailable
        case localeUnsupported(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "La reconnaissance vocale de macOS est indisponible."
            case .localeUnsupported(let code):
                return "macOS ne reconnaît pas la langue « \(code) »."
            }
        }
    }

    /// Locale réellement retenue, renseignée après la première transcription.
    private var resolvedLocale: String?

    var displayName: String {
        get async { "\(EngineChoice.apple.fullLabel) · \(resolvedLocale ?? "—")" }
    }

    func isReady() async -> Bool {
        SpeechTranscriber.isAvailable
    }

    /// Télécharge le modèle de reconnaissance de cette langue, s'il manque.
    ///
    /// « Inclus dans macOS, rien à télécharger » était faux, et il a fallu une
    /// machine vierge pour s'en apercevoir : sur un Mac qui a déjà servi, les
    /// actifs de `SpeechTranscriber` sont là parce que la dictée du système
    /// les a fait descendre un jour. Sur un macOS 26 fraîchement installé, il
    /// n'y a rien, `isAvailable` répond faux, et Caspr annonçait « la
    /// reconnaissance vocale de macOS est indisponible » — une phrase qui
    /// décrit l'état sans nommer la cause ni ce qu'on peut y faire.
    ///
    /// `AssetInventory.reserve` ne suffit pas : elle réserve une place pour
    /// une langue, elle ne récupère pas le modèle. C'est
    /// `assetInstallationRequest(supporting:)` qui le fait, et elle rend `nil`
    /// quand il n'y a rien à installer — donc l'appel est gratuit une fois les
    /// actifs en place.
    static func installAssets(for transcriber: SpeechTranscriber) async throws {
        guard let request = try await AssetInventory
            .assetInstallationRequest(supporting: [transcriber]) else { return }
        NSLog("caspr: téléchargement du modèle de reconnaissance de macOS")
        try await request.downloadAndInstall()
        NSLog("caspr: modèle de reconnaissance de macOS installé")
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        // Pas de garde sur `isAvailable` ici : elle répond faux précisément
        // quand aucun modèle n'est installé, c'est-à-dire dans le cas que
        // `installAssets` est là pour régler. S'y fier interdirait la seule
        // action qui débloque la situation.
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: request.language)) else {
            throw EngineError.localeUnsupported(request.language)
        }
        resolvedLocale = locale.identifier

        // Sans résultats volatils ni `fastResults` : ici on ne cherche pas la
        // réactivité mais le meilleur texte que ce moteur sache produire.
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])
        // Réservation avant installation : l'inventaire ne répond pas sur une
        // langue non réservée. Cf. SpeechAssets.
        try await LivePreview.reserve(locale)
        try await Self.installAssets(for: transcriber)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else {
            throw EngineError.unavailable
        }

        let started = Date()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let gathered = Task { () -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)

        for buffer in Self.buffers(from: request.samples, to: format) {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        // ## Ce `try?` valait un bug muet, et il l'a produit
        //
        // La lecture des résultats échoue quand l'analyseur n'a pas de modèle
        // à faire tourner — le cas d'une machine en macOS 26 sans Apple
        // Intelligence. L'erreur était avalée, la chaîne vide rendue, et
        // `TranscriptionResult` s'annonçait comme un **succès**. Le contrôleur
        // n'avait donc rien d'autre à dire que « Rien n'a été entendu », ce qui
        // désigne le micro alors que la panne est dans le moteur. Mesuré sur la
        // VM : l'aperçu en direct affichait le texte pendant ce temps-là, ce qui
        // achevait de rendre le diagnostic impossible.
        //
        // Un moteur qui ne peut pas travailler doit le dire. Le silence est
        // réservé au vrai silence : un flux qui se termine sans résultat rend
        // une chaîne vide sans lever, et ce cas-là reste traité comme avant.
        let text = try await gathered.value
        let elapsed = Date().timeIntervalSince(started) * 1000

        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            // Le moteur système ne distingue pas les modes : on rend celui qui
            // a été demandé plutôt que d'inventer une valeur.
            mode: request.mode,
            windowSeconds: Double(request.samples.count) / AudioRecorder.targetSampleRate,
            truncated: false,
            // Pas de découpage mel/encodeur/décodeur observable ici : seul le
            // temps mur a un sens.
            latency: TranscriptionResult.Latency(melMs: 0, encoderMs: 0,
                                                 decoderMs: 0, wallMs: elapsed))
    }

    /// Découpe les échantillons en tampons au format de l'analyseur.
    ///
    /// Par morceaux plutôt qu'en un seul bloc : le moteur travaille en flux, et
    /// un tampon de dix minutes le ferait allouer d'un coup ce qu'il aurait pu
    /// consommer au fil de l'eau.
    private static func buffers(from samples: [Float],
                                to format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioRecorder.targetSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: format) else { return [] }

        let chunk = 16_000                     // une seconde
        var out: [AVAudioPCMBuffer] = []
        var offset = 0

        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let input = AVAudioPCMBuffer(pcmFormat: source,
                                               frameCapacity: AVAudioFrameCount(count)) else { break }
            input.frameLength = AVAudioFrameCount(count)
            samples[offset..<(offset + count)].withUnsafeBufferPointer { source in
                input.floatChannelData![0].update(from: source.baseAddress!, count: count)
            }

            let ratio = format.sampleRate / AudioRecorder.targetSampleRate
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(count) * ratio) + 1) else { break }

            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return input
            }
            if error == nil, converted.frameLength > 0 { out.append(converted) }
            offset += count
        }
        return out
    }
}
