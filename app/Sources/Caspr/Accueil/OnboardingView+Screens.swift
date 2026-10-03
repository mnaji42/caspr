import SwiftUI

// Les cinq écrans de l'accueil, dans l'ordre où on les rencontre. Le cadre
// qui les porte — l'en-tête, le compteur, le pied et ce qui bloque
// « Continuer » — est dans OnboardingView.swift.
extension OnboardingView {
    // MARK: 1 — Bienvenue

    /// La promesse de confidentialité est dite **par voie**.
    ///
    /// L'accueil annonçait « vos paroles ne quittent jamais votre Mac ». C'est
    /// vrai de la voie macOS, et faux dès qu'on choisit ChatGPT : la voix y
    /// passe par le compte de l'utilisateur. Une promesse qui ne vaut que
    /// pour la moitié du produit, posée avant même qu'on ait choisi, est une
    /// promesse fausse.
    var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Le principe en trois points", followsHeader: true)

            Card {
                // Deux appuis, et non « maintenir pour parler » : tenue une
                // seconde, la touche Option ouvre les Réglages et renonce à
                // la dictée (cf. `ModifierKeyMonitor.onHold`).
                principle(1, "Écrivez au son de votre voix",
                          "Appuyez une fois sur votre touche de dictée, parlez "
                          + "naturellement dans n'importe quelle application, "
                          + "puis appuyez de nouveau : le texte s'insère à "
                          + "votre curseur.")
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
    var voieStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Qui écoute votre voix", followsHeader: true)
            CarteVoie(avecReglages: false)
        }
    }

    // MARK: 3 — Préférences

    var preferencesStep: some View {
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
    var liveEngineStep: some View {
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

    var completionStep: some View {
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
                        ? "Touche \(prefs.triggerSide.label) (un appui pour parler, un autre pour finir)"
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
}
