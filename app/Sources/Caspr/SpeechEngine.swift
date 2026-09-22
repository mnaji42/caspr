import Foundation

/// Style de transcription.
///
/// Aucune version de macOS ne le distingue (`EngineChoice.hasModes`) : le
/// réglage survit à l'ancien moteur local qui le portait, et s'en va avec le
/// reste des modes.
enum TranscriptionMode: String, Sendable, CaseIterable {
    /// Ce qui était voulu — texte nettoyé, nombres en chiffres. Défaut.
    case intended
    /// Ce qui a été dit — hésitations, répétitions, faux départs conservés.
    case verbatim
    var label: String {
        switch self {
        case .intended: "Texte nettoyé"
        case .verbatim: "Mot à mot"
        }
    }
}

/// De quoi retrouver, des mois plus tard, avec quoi une dictée a été
/// transcrite.
struct EngineIdentity: Sendable, Equatable {
    /// Famille du moteur : `apple`, `apple-legacy`.
    var engine: String
    /// Modèle précis quand il y en a un. Pour un moteur système sans version
    /// publique, la locale fait l'affaire.
    var model: String?
}

struct TranscriptionRequest: Sendable {
    /// PCM mono 16 kHz, normalisé dans [-1, 1].
    var samples: [Float]
    var mode: TranscriptionMode = .intended
    var language: String = "fr"
    /// Termes à privilégier au décodage. `nil` laisse le moteur appliquer son
    /// lexique par défaut ; un tableau vide le désactive.
    var lexicon: [String]?
}

struct TranscriptionResult: Sendable {
    var text: String
    var mode: TranscriptionMode
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

    /// Identité stable, pour l'archivage : quel moteur, quel modèle.
    ///
    /// Sans elle, une ligne de corpus ne dit pas *qui* a produit le texte, et
    /// dès qu'on peut changer de moteur la comparaison ne veut plus rien dire.
    /// Le libellé d'affichage ne suffit pas : il est fait pour être lu, pas
    /// pour être groupé.
    var identity: EngineIdentity { get async }

    /// Le moteur est-il prêt à transcrire ?
    func isReady() async -> Bool

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}
