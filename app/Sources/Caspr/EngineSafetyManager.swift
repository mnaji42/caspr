import Foundation
import Observation
import CasprCore

/// Garantit qu'il y a toujours une version de macOS capable d'écrire.
///
/// ## Le problème qu'il résout
///
/// La version retenue peut ne pas savoir écrire ici, maintenant : Apple
/// Intelligence sans le modèle de la langue active, une langue qu'elle ne
/// couvre pas, la Dictée éteinte dans les Réglages Système. Sur une machine
/// virtuelle en macOS 26, Apple Intelligence était élue sans modèle et rendait
/// une chaîne vide, pendant que la Dictée fonctionnait très bien.
///
/// **Le repli** (`effectiveEngine`) rattrape ces cas au moment de dicter. Il
/// est **silencieux et temporaire** : il ne réécrit jamais la préférence.
/// Quelqu'un qui a choisi Apple Intelligence et dicte un jour dans une langue
/// qu'elle ne couvre pas doit la retrouver en revenant au français, pas
/// découvrir que l'application a décidé à sa place de rester sur la Dictée.
@MainActor
@Observable
final class EngineSafetyManager {
    static let shared = EngineSafetyManager()

    private init() {}

    /// Le moteur qui doit réellement écrire, à cet instant.
    ///
    /// Trois rangs, dans cet ordre : le choix de l'utilisateur s'il tient, le
    /// dernier moteur qu'on a vu fonctionner, puis n'importe quelle version de
    /// macOS utilisable ici. Le dernier repli rend le choix de l'utilisateur
    /// tel quel — quand plus rien ne marche, mieux vaut échouer sur le moteur
    /// demandé, avec son message, que sur un substitut qui rendra l'erreur
    /// incompréhensible.
    var effectiveEngine: EngineChoice {
        let prefs = Preferences.shared
        let language = prefs.primaryLanguage
        let wanted = prefs.engine

        // `isReady`, et non `isAvailable` : pour Apple Intelligence,
        // « disponible » est optimiste tant que le système n'a pas répondu
        // pour la langue — cf. `isReady`.
        if isReady(wanted, for: language) { return wanted }
        if isReady(prefs.lastValidEngine, for: language) {
            return prefs.lastValidEngine
        }
        // `first { isReady }` et non `first` : cette dernière ligne prenait le
        // premier moteur *disponible*, et `availableSystemEngines` range Apple
        // Intelligence en tête. Sur une machine qui n'en a aucun modèle, elle
        // élisait donc précisément le moteur incapable d'écrire — c'est le
        // chemin qui a produit « Rien n'a été entendu » sur la VM, pendant que
        // l'aperçu en direct, lui, tournait très bien sur la Dictée.
        return EngineChoice.availableSystemEngines(for: language)
            .first { isReady($0, for: language) } ?? wanted
    }

    /// Le moteur retenu est-il en train d'être suppléé ?
    ///
    /// Sert aux bandeaux d'information : dire que la dictée marche *quand même*
    /// vaut mieux que laisser croire qu'elle est cassée, mais taire la
    /// substitution ferait passer une transcription de moindre qualité pour un
    /// caprice du moteur choisi.
    var isFallingBack: Bool {
        effectiveEngine != Preferences.shared.engine
    }

    /// Ce moteur est-il prêt à écrire, ici et dans cette langue ?
    ///
    /// `isAvailable` mesure déjà le gros — version de macOS présente, Dictée
    /// allumée, langue proposée.
    func isReady(_ choice: EngineChoice, for language: String) -> Bool {
        guard choice.isAvailable(for: language) else { return false }
        // ## Apple Intelligence exige une réponse, pas une absence de refus
        //
        // `isAvailable` est **volontairement optimiste** : tant que le système
        // n'a rien dit pour cette langue, elle ne la déclare pas indisponible,
        // sans quoi les cartes annonceraient « non pris en charge » pendant la
        // fraction de seconde où la question est en vol.
        //
        // Cette optimisme-là est sans danger dans une vue et ruineuse ici :
        // router une dictée vers un moteur dont personne n'a jamais mesuré
        // qu'il sait travailler, c'est ce qui a fait rendre une chaîne vide.
        // D'où la coupure entre les deux prédicats — « on peut l'afficher » et
        // « on peut lui confier ce que quelqu'un vient de dire ».
        if choice == .apple { return Language.appleSupports(language) == true }
        return true
    }

    /// Constate qu'un moteur vient d'écrire pour de bon.
    ///
    /// Appelé après une insertion réussie, pas après une simple vérification de
    /// disponibilité : un moteur qui répond à `isAvailable` peut encore échouer
    /// à la première phrase, et le repli doit désigner quelque chose dont on a
    /// la preuve, pas quelque chose dont on a l'espoir.
    func confirmWorking(_ choice: EngineChoice) {
        guard Preferences.shared.lastValidEngine != choice else { return }
        Preferences.shared.lastValidEngine = choice
    }
}
