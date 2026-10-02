import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void
    let onOpenSettings: () -> Void
    /// Le titre à afficher dans la barre de fenêtre. Remonté plutôt que posé
    /// ici : c'est `NSWindow` qui le porte, et le redessiner en SwiftUI
    /// donnerait deux titres à trois pixels d'écart.
    let onTitleChange: (String) -> Void
    /// Une calibration de la page ChatGPT vient de rendre la main.
    let onCalibrationEnded: () -> Void

    @State var prefs = Preferences.shared
    /// Observé pour le pied de page : la fin d'une calibration, ou une session
    /// que la page découvre perdue, change ce que l'écran du premier essai
    /// exige sous la voie ChatGPT — et rien d'autre ne redessinerait le
    /// bouton « Continuer ».
    @ObservedObject private var relais = Relais.partage
    @ObservedObject private var magasin = RelaisMagasin.partage
    @State private var step: OnboardingStep
    /// Coché d'avance pendant l'accueil.
    ///
    /// Caspr est une application d'arrière-plan : elle ne sert que si elle
    /// est là quand on appuie sur la touche. La laisser décochée demandait de
    /// la relancer à la main après chaque redémarrage, et l'oubli se
    /// manifestait par une touche qui ne fait rien — le symptôme le plus
    /// difficile à relier à sa cause. Décochable d'un clic, juste dessous.
    @State var launchAtLogin = LoginItem.isEnabled || !Preferences.shared.onboarded

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
        _step = State(initialValue: OnboardingStep.resumed)
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
            StepCounter(current: step.rawValue + 1, total: OnboardingStep.allCases.count)
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
                    step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
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
                    ForEach(OnboardingStep.allCases, id: \.self) { each in
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
                        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .completion
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
    func apply() {
        LoginItem.set(launchAtLogin)
        prefs.onboarded = true
    }
}
