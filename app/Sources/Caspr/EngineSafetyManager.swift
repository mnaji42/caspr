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
/// disponibilité se **mesure** — le système a répondu pour cette langue — et
/// ne se déduit jamais d'un numéro de version ni d'une absence de refus.
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
            // Disponible sans être prête : le système n'a pas encore dit s'il
            // propose la langue (cf. `isReady`).
            appleUnanswered: EngineChoice.apple.isAvailable(for: language))
    }

    /// Cette version est-elle prête à écrire, ici et dans cette langue ?
    ///
    /// `isAvailable` mesure déjà le gros — version de macOS présente, Dictée
    /// allumée, langue proposée.
    static func isReady(_ choice: EngineChoice, for language: String) -> Bool {
        guard choice.isAvailable(for: language) else { return false }
        switch choice {
        case .apple:
            // ## Apple Intelligence exige une réponse, pas une absence de refus
            //
            // `isAvailable` est **volontairement optimiste** : tant que le
            // système n'a rien dit pour cette langue, elle ne la déclare pas
            // indisponible, sans quoi les cartes annonceraient « non pris en
            // charge » pendant la fraction de seconde où la question est en vol.
            //
            // Cet optimisme-là est sans danger dans une vue et ruineux ici :
            // router une dictée vers un moteur dont personne n'a jamais mesuré
            // qu'il sait travailler, c'est ce qui a fait rendre une chaîne vide.
            return Language.appleSupports(language) == true
        case .appleLegacy:
            return true
        }
    }
}
