import AppKit
import SwiftUI
import CasprCore

/// L'accueil du premier lancement.
///
/// Caspr ne peut pas se contenter d'apparaître dans la barre de menus. Il lui
/// faut le micro et l'accessibilité, puis, selon la voie, un modèle de macOS
/// qui se télécharge ou une page ChatGPT connectée et calibrée — des
/// conditions qu'une app sans fenêtre n'a aucun moyen d'expliquer une fois
/// lancée et invisible. Sans accueil, le premier lancement se solde par une
/// icône muette et une dictée qui ne fait rien.
///
/// ## Cinq étapes, et aucune n'est une page vide
///
/// Une version précédente en comptait six, dont quatre ne portaient qu'un titre
/// et deux phrases ; celle d'après en comptait cinq mais réimplémentait les
/// questions que les Réglages posaient déjà, si bien que les deux avaient
/// divergé. L'écran du moteur de la passe finale est parti quand la version de
/// macOS a cessé d'être un choix ; celui de la voie est venu quand ChatGPT est
/// devenu la moitié du produit. Celle-ci n'écrit **aucun** réglage de son
/// côté : chaque étape instancie les mêmes vues que les Réglages, et sa seule
/// responsabilité est l'ordre dans lequel on les rencontre.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    /// N'ouvre que si l'accueil n'a jamais été mené à terme.
    func showIfNeeded() {
        guard !Preferences.shared.onboarded else { return }
        show()
    }

    func show() {
        if let window {
            window.showCentered()
            return
        }

        // `weak var` capturé plus bas : la vue met à jour le titre de la
        // fenêtre qui la contient, ce que SwiftUI ne sait pas faire seul.
        var host: NSWindow?
        let window = NSWindow.caspr(title: Step.resumed.windowTitle(Preferences.shared.voie)) {
            OnboardingView(onFinish: { [weak self] in self?.close() },
                           onOpenSettings: { [weak self] in
                               self?.close()
                               self?.openSettings?()
                           },
                           onTitleChange: { title in host?.title = title },
                           onCalibrationEnded: { [weak self] in self?.comeBack() })
        }
        host = window
        self.window = window

        window.showCentered()
    }

    /// Ouvre les Réglages, posé par le delegate : l'accueil ne connaît pas la
    /// fenêtre des Réglages et n'a aucune raison de la connaître.
    var openSettings: (() -> Void)?

    private func close() {
        window?.close()
        window = nil
    }

    /// Ramène l'accueil devant, là où il était.
    ///
    /// Une calibration de la page ChatGPT se termine en cachant Caspr tout
    /// entier, pour rendre la main à l'application d'où l'on venait — et
    /// l'accueil disparaissait avec elle, au milieu du parcours, comme s'il
    /// était fini. Sans `center()` : on le retrouve où on l'avait laissé.
    private func comeBack() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Les étapes

private enum Step: Int, CaseIterable {
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
    @MainActor static var resumed: Step {
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

// MARK: - Fenêtre

private struct OnboardingView: View {
    let onFinish: () -> Void
    let onOpenSettings: () -> Void
    /// Le titre à afficher dans la barre de fenêtre. Remonté plutôt que posé
    /// ici : c'est `NSWindow` qui le porte, et le redessiner en SwiftUI
    /// donnerait deux titres à trois pixels d'écart.
    let onTitleChange: (String) -> Void
    /// Une calibration de la page ChatGPT vient de rendre la main.
    let onCalibrationEnded: () -> Void

    @State private var prefs = Preferences.shared
    /// Observé pour le pied de page : la fin d'une calibration, ou une session
    /// que la page découvre perdue, change ce que l'écran du premier essai
    /// exige sous la voie ChatGPT — et rien d'autre ne redessinerait le
    /// bouton « Continuer ».
    @ObservedObject private var relais = Relais.partage
    @State private var step: Step
    /// Coché d'avance pendant l'accueil.
    ///
    /// Caspr est une application d'arrière-plan : elle ne sert que si elle
    /// est là quand on appuie sur la touche. La laisser décochée demandait de
    /// la relancer à la main après chaque redémarrage, et l'oubli se
    /// manifestait par une touche qui ne fait rien — le symptôme le plus
    /// difficile à relier à sa cause. Décochable d'un clic, juste dessous.
    @State private var launchAtLogin = LoginItem.isEnabled || !Preferences.shared.onboarded

    init(onFinish: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
         onTitleChange: @escaping (String) -> Void,
         onCalibrationEnded: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onOpenSettings = onOpenSettings
        self.onTitleChange = onTitleChange
        self.onCalibrationEnded = onCalibrationEnded
        // Reprend là où on s'était arrêté. Rouvrir sur la page de bienvenue
        // quelqu'un qui était à l'étape des autorisations lui ferait relire ce
        // qu'il vient de lire, et douter d'avoir progressé.
        _step = State(initialValue: Step.resumed)
    }

    /// Le logo, ici et nulle part ailleurs. C'est le seul écran où l'on fait
    /// connaissance ; le répéter dans chaque fenêtre le viderait de son sens.
    ///
    /// La version empilée — le fantôme au-dessus du nom — et non l'icône de
    /// l'application : celle-ci vit dans le Dock et dans la fenêtre
    /// d'installation, où il faut la reconnaître ; ici on présente le produit.
    static var logo: AnyView? {
        BrandIcon("caspr-ghost", height: 64).map { AnyView($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let header = step.header(prefs.voie) {
                        if step == .welcome, let logo = Self.logo {
                            HStack(alignment: .top, spacing: 16) {
                                logo
                                PageHeader(title: header.title,
                                           subtitle: header.subtitle,
                                           scale: .screen)
                            }
                        } else {
                            PageHeader(title: header.title,
                                       subtitle: header.subtitle,
                                       scale: step == .completion ? .summary : .screen)
                        }
                    }
                    content
                }
                // `.content-area { padding: 26px 30px 24px }`
                .padding(.horizontal, Style.windowPadding)
                .padding(.top, 26)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Sans ancre explicite, le premier champ de saisie de la page
            // prend le focus au lancement et macOS fait défiler pour le
            // révéler : à l'écran des langues, le titre se retrouvait coupé en
            // haut avant qu'on ait touché à quoi que ce soit.
            .defaultScrollAnchor(.top)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Le compteur appartient à la barre de titre, aligné sur les pastilles
        // — c'est là que le prototype le place, dans `.titlebar`. En le posant
        // dans le flux, il s'ajoutait *sous* la barre de titre : SwiftUI
        // décale déjà le contenu de la hauteur du titre, si bien qu'une bande
        // vide de 48 pt séparait la pastille du titre de l'écran. En calque,
        // et affranchi de cette marge, il retrouve la ligne des pastilles.
        .overlay(alignment: .topTrailing) {
            StepCounter(current: step.rawValue + 1, total: Step.allCases.count)
                // Centré dans les 28 pt de la barre de titre : la pastille en
                // fait 20, il reste 4 de part et d'autre.
                .padding(.top, 4)
                .padding(.trailing, Style.windowPadding)
                .ignoresSafeArea(edges: .top)
        }
        .background(WindowBackground().ignoresSafeArea())
        .onAppear { onTitleChange(step.windowTitle(prefs.voie)) }
        // Enregistrée en continu : quitter l'application au milieu d'une étape
        // ne doit pas coûter les précédentes.
        .onChange(of: step) { _, now in
            prefs.onboardingScreen = now.name
            onTitleChange(now.windowTitle(prefs.voie))
        }
        // La voie peut changer sous l'accueil — depuis le menu de la barre —,
        // et le titre de l'écran du premier essai la nomme.
        .onChange(of: prefs.voie) { _, voie in
            onTitleChange(step.windowTitle(voie))
        }
        // Choisir ChatGPT lance la calibration par-dessus l'accueil, et elle
        // cache Caspr en finissant : l'accueil revient, pour qu'on voie où en
        // est la voie et qu'on poursuive le parcours.
        .onChange(of: relais.occupation) { avant, maintenant in
            guard avant == .calibration, maintenant == .libre else { return }
            onCalibrationEnded()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .voie: voieStep
        case .preferences: preferencesStep
        case .liveEngine: liveEngineStep
        case .completion: completionStep
        }
    }

    // MARK: 1 — Bienvenue

    /// La promesse de confidentialité est dite **par voie**.
    ///
    /// L'accueil annonçait « vos paroles ne quittent jamais votre Mac ». C'est
    /// vrai de la voie macOS, et faux dès qu'on choisit ChatGPT : la voix y
    /// passe par le compte de l'utilisateur. Une promesse qui ne vaut que
    /// pour la moitié du produit, posée avant même qu'on ait choisi, est une
    /// promesse fausse.
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Le principe en trois points", followsHeader: true)

            Card {
                principle(1, "Écrivez au son de votre voix",
                          "Appuyez sur une touche, parlez naturellement dans "
                          + "n'importe quelle application, relâchez. Le texte "
                          + "s'insère à votre curseur.")
                Divider().opacity(0.25)
                principle(2, "Deux façons de dicter",
                          "**macOS**, hors ligne et sans compte : vos paroles "
                          + "restent sur votre Mac. **ChatGPT**, par votre "
                          + "propre compte : votre voix passe par ChatGPT, dans "
                          + "une page que Caspr ouvre pour vous.")
                Divider().opacity(0.25)
                principle(3, "Aucun serveur Caspr",
                          "Ni compte Caspr, ni télémétrie. Caspr ne fait que "
                          + "relier votre voix à votre curseur ; sa seule "
                          + "requête à lui est la vérification des mises à "
                          + "jour, si vous l'activez.")
            }
            .padding(.bottom, 12)

            SectionLabel("Ce que nous allons configurer")

            Card(highlighted: true) {
                Text(.init("Ce court parcours vous aide à **choisir votre façon "
                           + "de dicter**, **choisir vos langues**, **activer "
                           + "les deux accès système requis** et **faire un "
                           + "premier essai vocal**."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xCCFBF1))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func principle(_ number: Int, _ title: String,
                           _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            NumberBadge(number: number)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(.init(detail))
                    .font(.system(size: 12))
                    .foregroundStyle(Style.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 2 — La voie

    /// Tôt, parce que tout ce qui suit en dépend : les autorisations, ce qui
    /// se télécharge ou se connecte, et même l'écran du premier essai.
    ///
    /// Les deux lignes des Réglages, sans les réglages de la voie retenue :
    /// macOS se règle d'après la langue, choisie à l'écran suivant. Choisir
    /// ChatGPT lance tout de suite la connexion puis la calibration, comme
    /// dans les Réglages (cf. `CarteVoie.choisir`) ; l'écran du premier essai
    /// montre où elles en sont, et de quoi les reprendre.
    private var voieStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Qui écoute votre voix", followsHeader: true)
            CarteVoie(avecReglages: false)
        }
    }

    // MARK: 3 — Préférences

    private var preferencesStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Langues de dictée (Au moins 1 langue requise)", followsHeader: true)
            Card { LanguagePicker() }
        }
    }

    // MARK: 4 — Moteur, déclencheur et essai

    /// La voie **avant** le déclencheur.
    ///
    /// L'inverse paraissait plus logique — on configure la touche, puis ce
    /// qu'elle déclenche — mais c'est la voie qui décide de ce qui reste à
    /// faire : sous la Dictée, la reconnaissance vocale s'ajoute aux deux
    /// autorisations ; sous ChatGPT, une connexion et une calibration. Les
    /// poser d'abord évite de voir une exigence apparaître après coup dans une
    /// carte qu'on croyait finie.
    ///
    /// Sous ChatGPT, rien sur macOS : c'est la page qui écoute, et exiger un
    /// modèle d'Apple Intelligence qu'elle n'utilisera jamais bloquerait qui
    /// n'a que ChatGPT (cf. `SetupRecoveryGuard`).
    private var liveEngineStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch prefs.voie {
            case .apple:
                SectionLabel("Moteur de reconnaissance", followsHeader: true)
                AppleEngineCard()
                    .padding(.bottom, 12)
            case .chatgpt:
                SectionLabel("Votre compte ChatGPT", followsHeader: true)
                RelaisSession()
                    .padding(.bottom, 12)
            }

            SectionLabel("Déclencheur & Zone de test")
            TriggerCard(showTrialSandbox: true)
        }
    }

    // MARK: 5 — Tout est prêt

    private var completionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            recap

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Bon à savoir pour votre quotidien")
                VStack(spacing: 0) {
                    tip("menubar.arrow.up.rectangle", "Barre des menus & Raccourci rapide",
                        "Caspr reste toujours accessible dans la barre des "
                        + "menus en haut.\n**💡 Astuce :** Maintenir votre "
                        + "touche de dictée (**⌥ Option**) pendant **1 "
                        + "seconde** ouvre directement les Réglages.")
                    Divider().opacity(0.25)
                    tip("arrow.left.arrow.right", "Passer de macOS à ChatGPT",
                        "« Écrire avec ChatGPT », dans le menu de la barre, "
                        + "change de voie pour la dictée suivante. Un raccourci "
                        + "peut faire de même : il se choisit dans Réglages › "
                        + "Dictée.")
                    Divider().opacity(0.25)
                    tip("checkmark.shield", "Filet de sécurité : vous ne perdez jamais rien",
                        "Même si aucune application n'a le focus ou si votre "
                        + "curseur n'était pas actif, votre dictée est "
                        + "immédiatement enregistrée dans l'**Historique "
                        + "local** du menu pour que vous puissiez la copier à "
                        + "tout moment.")
                    Divider().opacity(0.25)
                    tip("text.cursor", "Au curseur ou dans un fichier de notes",
                        "Par défaut, Caspr écrit là où clignote votre "
                        + "curseur. Vous pouvez aussi lui désigner un fichier "
                        + "de notes (ex : `journal.md`) dans les Réglages pour "
                        + "y archiver automatiquement vos idées.")
                }
                .background(
                    RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                        .overlay(RoundedRectangle(cornerRadius: Style.cardRadius,
                                                  style: .continuous)
                            .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)))
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Démarrage du système")
                SettingsToggleRow(
                    title: "Lancer Caspr à l'ouverture de session",
                    description: "Disponible immédiatement dans la barre des "
                        + "menus dès le démarrage de votre Mac.",
                    isOn: $launchAtLogin)
            }

            VStack(spacing: 8) {
                Divider().opacity(0.4)
                Button("⚙️  Personnaliser dans les Réglages…") {
                    apply()
                    onOpenSettings()
                }
                .buttonStyle(CasprSecondaryButtonStyle())
                Text("Vous pourrez toujours réouvrir les réglages ou "
                     + "l'onboarding depuis l'icône de la barre des menus.")
                    .font(.system(size: 11))
                    .foregroundStyle(Style.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }

    private var recap: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RÉCAPITULATIF DE VOTRE CONFIGURATION")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.55)
                .foregroundStyle(Style.accent)

            VStack(alignment: .leading, spacing: 5) {
                summary("Langue active :", prefs.primary.badge)
                summary("Déclencheur :", prefs.triggerKind == .option
                        ? "Touche \(prefs.triggerSide.label) (Maintenir pour parler)"
                        : "Raccourci clavier (\(prefs.dictateShortcut.label))")
                summary("Voie :", voieSummary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                .fill(Style.accent.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: Style.cardRadius,
                                          style: .continuous)
                    .strokeBorder(Style.accentBorder, lineWidth: 1)))
    }

    /// Ce qui écrira, et non ce qui est coché.
    ///
    /// Le récapitulatif est la dernière chose lue avant « Terminer » : il doit
    /// annoncer ce qui va se passer. Lu sur la préférence, il promettait Apple
    /// Intelligence même quand le modèle de la langue n'est pas téléchargé et
    /// que la Dictée classique prendra le relais. Et il dit où va la voix :
    /// c'est la différence entre les deux voies qui compte le plus.
    private var voieSummary: String {
        switch prefs.voie {
        case .apple:
            let version = EngineSafetyManager.effectiveEngine.versionLabel
            return "macOS · \(version) (hors ligne, rien ne sort du Mac)"
        case .chatgpt:
            return "ChatGPT (votre compte, dans la page de Caspr)"
        }
    }

    private func summary(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Style.textTertiary)
                .frame(width: 125, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Le prototype ouvre chaque astuce par un emoji. Ils ont le défaut des
    /// emoji de la barre d'onglets : rendu variable selon la police système,
    /// aucune valeur d'accessibilité, et une correspondance approximative —
    /// une punaise de carte pour désigner la barre des menus. Un symbole SF
    /// s'aligne sur le texte, suit le poids et nomme vraiment la chose.
    private func tip(_ symbol: String, _ title: String,
                     _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Style.accent)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(.init(detail))
                .font(.system(size: 11))
                .foregroundStyle(Style.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Pied

    /// Ce qui manque pour passer à l'étape suivante, ou `nil`.
    ///
    /// Chaque étape délègue à ses propres composants : ce sont eux qui savent
    /// ce qui leur manque, et ils le savent d'une seule façon, partagée avec
    /// les Réglages.
    private var blocker: ComponentValidationError? {
        switch step {
        case .welcome: nil
        // Rien n'empêche de choisir : ce que la voie exige se règle à l'écran
        // du premier essai, où l'on voit pourquoi « Continuer » attend.
        case .voie: nil
        case .preferences: LanguagePicker.validate()
        // Le déclencheur **et** ce qu'exige la voie : c'est l'étape qui rend
        // Caspr utilisable, et la dernière qu'exige la garde d'accès — qui en
        // juge avec les mêmes composants.
        case .liveEngine:
            TriggerCard.validate() ?? {
                switch prefs.voie {
                case .apple: AppleEngineCard.validate()
                case .chatgpt: RelaisSession.validate()
                }
            }()
        case .completion: nil
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let blocker, step != .welcome {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                    // Dit ce qui manque, au lieu de griser sans expliquer. Un
                    // bouton inactif muet est la façon la plus sûre de faire
                    // abandonner quelqu'un à l'étape des autorisations.
                    Text(blocker.errorDescription ?? "")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Style.warning)
                .padding(.horizontal, Style.windowPadding)
                .padding(.bottom, 8)
            }

            Divider().opacity(0.5)

            HStack(spacing: 12) {
                Button("←  Retour") {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                }
                .buttonStyle(CasprSecondaryButtonStyle())
                // La flèche est un ornement : lue telle quelle, VoiceOver
                // annonçait « flèche vers la gauche, Retour ».
                .accessibilityLabel("Retour")
                // Masqué, pas retiré : le retirer décalerait les points de
                // navigation d'un écran à l'autre.
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)

                Spacer()
                HStack(spacing: 7) {
                    ForEach(Step.allCases, id: \.self) { each in
                        Circle()
                            .fill(each == step ? Style.accent
                                               : Color.white.opacity(0.2))
                            .frame(width: 6, height: 6)
                            .scaleEffect(each == step ? 1.3 : 1)
                    }
                }
                Spacer()

                Button(step.actionLabel) {
                    if step == .completion {
                        apply()
                        onFinish()
                    } else {
                        step = Step(rawValue: step.rawValue + 1) ?? .completion
                    }
                }
                .buttonStyle(CasprPrimaryButtonStyle())
                .accessibilityLabel(step.spokenActionLabel)
                .disabled(blocker != nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Style.windowPadding)
            .frame(height: 60)
            .background(Color.black.opacity(0.2))
        }
    }

    /// Applique ce que l'accueil a différé, et clôt la configuration.
    ///
    /// Le démarrage automatique est le seul réglage que l'accueil n'écrit pas
    /// en direct : cocher une case n'est pas encore une décision, finir
    /// l'accueil en est une. Tout le reste a été enregistré par les composants
    /// au fil de l'eau.
    private func apply() {
        LoginItem.set(launchAtLogin)
        prefs.onboarded = true
    }
}

// MARK: - Pièces

/// Une langue, l'état de son modèle, et de quoi le récupérer.
///
/// Conservée pour les Réglages Système et les diagnostics : `AppleEngineCard`
/// porte désormais le cas courant, mais cette ligne reste la façon la plus
/// compacte de montrer l'état d'**une** langue précise.
struct SpeechModelRow: View {
    let language: String
    let label: String

    @State private var assets = SpeechAssets.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch assets.state(of: language) {
            case .unknown, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(label) — vérification…").font(.system(size: 12))
                }

            case .missing:
                StatusRow(ok: false, label: label, detail: "à télécharger",
                          warningOnly: true)
                ButtonRow {
                    Button("Télécharger \(label)") {
                        Task { await assets.install(language) }
                    }
                }

            // Indéterminé, faute de pouvoir mesurer sans casser ce qu'on
            // mesure. Cf. SpeechAssets : lire l'avancement faisait échouer le
            // téléchargement.
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(label) — téléchargement en cours…")
                        .font(.system(size: 12))
                }

            case .ready:
                StatusRow(ok: true, label: label, detail: "installé")

            case .unsupported(let why):
                StatusRow(ok: false, label: label, detail: "indisponible",
                          warningOnly: true)
                Note(why + "\n\nVous pouvez continuer.", warning: true)

            case .failed(let message):
                StatusRow(ok: false, label: label, detail: "échec",
                          warningOnly: true)
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Style.warning)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ButtonRow {
                    Button("Réessayer") { Task { await assets.install(language) } }
                }
            }
        }
        .task { await assets.check(language) }
    }
}
