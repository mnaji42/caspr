import Foundation
import CasprCore

/// Choisit la version de macOS qui écrit, sur ce que la machine a montré.
///
/// ## Le problème qu'il résout
///
/// Une version peut se dire disponible et ne pas savoir écrire ici,
/// maintenant : Apple Intelligence sans le modèle de la langue active, une
/// langue qu'elle ne couvre pas, la Dictée éteinte dans les Réglages Système.
/// Sur une machine virtuelle en macOS 26, Apple Intelligence était élue sans
/// modèle et rendait une chaîne vide, pendant que la Dictée fonctionnait très
/// bien.
///
/// Il n'y a plus de réglage à suppléer : la voie macOS n'a pas de version à
/// choisir, elle prend celle qui sait écrire la langue
/// (`EngineChoice.automatic`). Ce qui reste ici, c'est la garantie : la
/// disponibilité se **mesure** — le système a répondu pour cette langue, le
/// modèle est sur le disque, le droit est accordé — et ne se déduit jamais
/// d'un numéro de version ni d'une absence de refus.
@MainActor
enum EngineSafetyManager {

    /// La version qui écrit, à cet instant, dans la langue principale.
    ///
    /// L'aperçu en direct la suit aussi : deux versions à la fois
    /// réclameraient deux autorisations et deux jeux de modèles pour un seul
    /// texte, et c'est le texte définitif qui compte.
    static var effectiveEngine: EngineChoice {
        engine(for: Preferences.shared.primaryLanguage)
    }

    static func engine(for language: String) -> EngineChoice {
        EngineChoice.automatic(
            appleReady: isReady(.apple, for: language),
            legacyReady: isReady(.appleLegacy, for: language),
            // Pas prête sans être refusée : le système n'a pas encore
            // répondu, ou le modèle reste à télécharger (cf. `isReady`).
            appleNotRefused: EngineChoice.apple.isAvailable(for: language))
    }

    /// Cette version est-elle prête à écrire, ici, maintenant et dans cette
    /// langue — sans rien télécharger ni rien demander ?
    ///
    /// `isAvailable` mesure déjà le gros — version de macOS présente, langue
    /// pas refusée. Il est **volontairement optimiste**, pour que les cartes
    /// n'annoncent pas « non pris en charge » pendant la fraction de seconde
    /// où la question est en vol. Cet optimisme est sans danger dans une vue,
    /// et ruineux ici : on n'envoie une dictée qu'à une version dont on a
    /// constaté qu'elle sait travailler.
    static func isReady(_ choice: EngineChoice, for language: String) -> Bool {
        guard choice.isAvailable(for: language) else { return false }
        switch choice {
        case .apple:
            // ## Une langue proposée, et son modèle sur le disque
            //
            // La première moitié ne suffisait pas. Sans le modèle,
            // `AppleSpeechEngine.transcribe` commence par l'installer : des
            // minutes sous « Transcription… », sans explication, et un échec
            // à chaque dictée hors ligne — « Réessayer » compris —, alors que
            // la Dictée, sur l'appareil, aurait écrit. `SpeechAssets` le
            // mesure déjà (`installedLocales`) : c'est cette mesure qui
            // décide. Un état encore inconnu ne vaut pas « prête » : le
            // sondage du lancement répond en une fraction de seconde.
            return Language.appleSupports(language) == true
                && SpeechAssets.shared.state(of: language) == .ready
        case .appleLegacy:
            // Ce que `LegacySpeechEngine.isReady` exige avant d'écrire : le
            // droit de reconnaissance vocale, et la Dictée allumée — éteinte,
            // le recogniseur accepte la tâche et ne rend jamais rien. Sans
            // eux, la préférer à Apple Intelligence ferait demander un droit
            // et un interrupteur à qui n'a qu'un modèle à télécharger.
            return LegacySpeechEngine.isAuthorised && !SystemDictation.isDisabled
        }
    }
}
