import AppKit

/// Empêche de se servir de Caspr tant qu'il ne peut pas encore dicter.
///
/// ## Le problème
///
/// L'accueil pouvait se fermer à n'importe quelle étape, et il ne rouvrait
/// jamais : le drapeau `onboarded` n'est posé qu'au bouton « Terminer ». Rester
/// bloqué au milieu de l'étape des autorisations laissait donc une icône dans
/// la barre de menus, une touche de dictée qui ne faisait rien, et aucune
/// explication nulle part — l'accueil était précisément l'écran qui portait
/// l'explication, et on venait de le fermer.
///
/// ## Ce qui compte comme « socle minimal »
///
/// Ce qu'exige **la voie retenue**, et pas une chose de plus.
///
/// - **macOS** : une langue retenue, le micro et l'accessibilité accordés, et
///   une version de macOS capable d'écrire dans cette langue.
/// - **ChatGPT** : le micro et l'accessibilité, et une page connectée et
///   calibrée pour dicter. Rien sur macOS — c'est la page qui écoute, et exiger un modèle
///   Apple Intelligence qu'elle n'utilisera jamais rendait Caspr
///   inutilisable pour qui n'a que ChatGPT.
///
/// La destination et le reste ont des valeurs par défaut qui fonctionnent :
/// quitter l'accueil avant la fin n'empêche rien, et bloquer dessus serait une
/// exigence sans contrepartie.
///
/// ## Ce que la garde n'intercepte pas
///
/// **Le clic sur l'icône de la barre de menus.** Les documents demandaient de
/// le détourner aussi. Ce serait retirer le seul chemin vers « Quitter » :
/// quelqu'un qui refuse l'accessibilité en connaissance de cause se
/// retrouverait avec une fenêtre qui revient à chaque tentative de fermer
/// l'application. Le menu s'ouvre donc toujours, réduit à ce qui a du sens
/// tant que la configuration n'est pas finie.
///
/// **Et rien du tout une fois l'accueil terminé.** Perdre l'accessibilité six
/// mois plus tard — ce qui arrive à chaque mise à jour d'une copie signée ad
/// hoc — ne doit pas faire surgir l'accueil par-dessus le travail en cours. Le
/// menu porte déjà l'avertissement, et `TriggerCard` le bouton qui répare.
@MainActor
enum SetupRecoveryGuard {

    /// Caspr dispose-t-il du strict nécessaire pour dicter ?
    static var isMinimumViableSetupCompleted: Bool {
        let prefs = Preferences.shared
        // Le raccourci et ses autorisations valent pour les deux voies : le
        // micro de la page ChatGPT passe par celui de Caspr, et l'insertion
        // par l'accessibilité.
        guard TriggerCard.isValid else { return false }
        switch prefs.voie {
        case .apple:
            guard !prefs.selectedLanguages.isEmpty else { return false }
            // Le moteur de macOS, mesuré : sans lui, l'aperçu comme l'écriture
            // n'ont rien pour travailler.
            return AppleEngineCard.isValid
        case .chatgpt:
            // Connecté et calibré. La connexion est la dernière mesure de la
            // page — prise à chacun de ses chargements, au lancement comme
            // après chaque dictée, et à chaque ouverture de sa fenêtre —, pas
            // une mesure prise ici : l'interroger n'est pas synchrone, et une
            // garde l'est. La prendre à l'appui, ce serait décider à l'appui,
            // ce que le relais s'interdit ; et `demarrer` la reprend de toute
            // façon, et devant une session perdue ouvre la fenêtre où l'on se
            // reconnecte — un meilleur recours que de rouvrir l'accueil.
            return Relais.partage.saitDicter
        }
    }

    /// L'accueil doit-il reprendre la main ?
    ///
    /// Uniquement tant qu'il n'a jamais été mené à terme. Une fois `onboarded`
    /// posé, l'utilisateur a vu les explications et sait où les retrouver.
    static var shouldIntercept: Bool {
        !Preferences.shared.onboarded && !isMinimumViableSetupCompleted
    }

    /// Intercepte une action qui suppose une configuration terminée.
    ///
    /// Rend `true` quand l'action a été détournée, pour que l'appelant
    /// s'arrête là.
    @discardableResult
    static func intercept(_ reason: Reason,
                          reopening onboarding: OnboardingWindowController) -> Bool {
        guard shouldIntercept else { return false }
        Log.info("configuration incomplète — accueil rouvert (\(reason.rawValue))")
        onboarding.show()
        return true
    }

    enum Reason: String {
        case dictation
        case settings
        case launch
    }
}
