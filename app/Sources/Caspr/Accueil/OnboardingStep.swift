import CasprCore

/// Les écrans de l'accueil. L'ordre des cas est celui du parcours :
/// « Continuer » et « Retour » passent au rang voisin.
enum OnboardingStep: Int, CaseIterable {
    case welcome, voie, preferences, liveEngine, completion

    /// L'étape sur laquelle rouvrir.
    ///
    /// Lue à deux endroits — la vue, pour savoir quoi afficher, et la fenêtre,
    /// pour son titre. Les deux la déduisaient séparément, et la fenêtre s'en
    /// remettait à un rappel qui arrivait trop tard : `onAppear` se déclenche
    /// pendant la construction de la fenêtre, avant que la variable qui la
    /// désigne soit affectée, si bien que la mise à jour du titre partait dans
    /// le vide. La barre annonçait « Bienvenue dans Caspr » au-dessus de
    /// « Vos Préférences » jusqu'au premier changement d'étape.
    ///
    /// L'écran du moteur final n'existe plus : qui s'y était arrêté avait
    /// franchi tout ce qui le précède, et reprend à la fin plutôt qu'à la
    /// bienvenue.
    ///
    /// Un accueil mené à terme se revoit depuis le début : « Terminer » ne
    /// remet pas l'étape à zéro, et « Revoir l'accueil… » rouvrait sur
    /// « Tout est prêt ! », à quatre « Retour » de la bienvenue. Tester le
    /// drapeau ici couvre aussi les installations où « completion » est
    /// déjà rangé.
    @MainActor static var resumed: OnboardingStep {
        if Preferences.shared.onboarded { return .welcome }
        let stored = Preferences.shared.onboardingScreen
        if stored == "finalEngine" { return .completion }
        return allCases.first { $0.name == stored } ?? .welcome
    }

    /// Le nom sous lequel l'étape est enregistrée.
    ///
    /// Un nom et non un numéro : l'index rangé dans l'ancienne clé
    /// `caspr.onboarding.step` changeait de sens dès qu'on retirait un écran,
    /// et rouvrait l'accueil sur la page d'après sans rien dire. Un nom qui
    /// disparaît ne désigne plus rien, et l'on repart du début. Ces noms sont
    /// ceux sous lesquels `LegacyCleanup` traduit l'ancien index : les
    /// changer, c'est perdre l'étape de qui était en cours de route. L'écran
    /// de la voie, venu après, n'a pas d'index à traduire.
    var name: String {
        switch self {
        case .welcome: "welcome"
        case .voie: "voie"
        case .preferences: "preferences"
        case .liveEngine: "liveEngine"
        case .completion: "completion"
        }
    }

    /// Le titre de la fenêtre, qui **suit l'étape**.
    ///
    /// Repris tel quel de `HeaderNav.jsx` : la barre de titre annonce où l'on
    /// est, elle ne répète pas « Bienvenue » sur tous les écrans.
    func windowTitle(_ voie: VoieDeDictee) -> String {
        switch self {
        case .welcome: "Bienvenue dans Caspr"
        case .voie: "Votre Façon de Dicter"
        case .preferences: "Vos Préférences"
        case .liveEngine:
            switch voie {
            case .apple: "Moteur & Premier Essai"
            case .chatgpt: "ChatGPT & Premier Essai"
            }
        case .completion: "Tout est prêt !"
        }
    }

    /// L'en-tête de la page. `nil` pour la fin, qui porte le sien —
    /// `CompletionView` dans le prototype.
    ///
    /// L'écran du premier essai dépend de la voie : c'est lui qui la règle,
    /// et chacune y demande autre chose.
    func header(_ voie: VoieDeDictee) -> (title: String, subtitle: String)? {
        switch self {
        case .welcome:
            ("Bienvenue dans Caspr",
             "La dictée vocale instantanée pour macOS : vous parlez, le texte "
                + "s'écrit là où se trouve votre curseur.")
        case .voie:
            ("Votre Façon de Dicter",
             "Deux voies, qui ne partagent ni le micro ni ce qu'elles envoient. "
                + "Vous pourrez changer à tout moment.")
        case .preferences:
            ("Vos Préférences",
             "Configurez vos langues de travail pour que Caspr s'adapte à "
                + "vous.")
        case .liveEngine:
            switch voie {
            case .apple:
                ("Moteur & Premier Essai",
                 "Le moteur de macOS écrit votre dictée et en montre l'aperçu "
                    + "en direct sous la barre flottante.")
            case .chatgpt:
                ("ChatGPT & Premier Essai",
                 "La page ChatGPT écoute et transcrit à la place du micro de "
                    + "Caspr. Elle doit être connectée à votre compte, et "
                    + "calibrée.")
            }
        case .completion:
            ("Tout est prêt !",
             "Caspr est configuré et prêt à transcrire votre voix en toute "
                + "fluidité.")
        }
    }

    /// L'intitulé du bouton principal — `FooterNav.jsx`.
    var actionLabel: String {
        switch self {
        case .welcome: "Commencer la configuration  →"
        case .completion: "Terminer"
        default: "Continuer  →"
        }
    }

    /// Le même libellé, sans la flèche. Elle indique la direction à l'œil et
    /// n'ajoute rien à l'oreille : lue, elle donnait « Continuer, flèche vers
    /// la droite ».
    var spokenActionLabel: String {
        actionLabel.replacingOccurrences(of: "→", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
