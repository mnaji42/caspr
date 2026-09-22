import Foundation

struct TranscriptionRequest: Sendable {
    /// PCM mono 16 kHz, normalisé dans [-1, 1].
    var samples: [Float]
    var language: String = "fr"
}

struct TranscriptionResult: Sendable {
    var text: String
    /// Fenêtre d'encodage retenue, en secondes — utile au diagnostic.
    var windowSeconds: Double
    /// Vrai si l'audio dépassait la limite de 30 s du modèle et a été coupé.
    var truncated: Bool
    var latency: Latency

    struct Latency: Sendable {
        var melMs: Double
        var encoderMs: Double
        var decoderMs: Double
        var wallMs: Double
    }
}

/// Frontière entre l'application et l'inférence.
///
/// Tout ce qui est spécifique à un runtime — PyTorch, Core ML, whisper.cpp —
/// vit derrière ce protocole. Changer de moteur ne doit rien changer en amont.
protocol SpeechEngine: Sendable {
    /// Nom lisible du moteur actif, pour l'affichage et les diagnostics.
    var displayName: String { get async }

    /// Le moteur est-il prêt à transcrire ?
    func isReady() async -> Bool

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}
