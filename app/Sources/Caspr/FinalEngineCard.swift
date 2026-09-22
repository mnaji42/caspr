import SwiftUI
import CasprCore

/// Le choix qui compte : qui écrit le texte définitif.
///
/// Il n'en reste qu'une ligne, macOS, qui héberge son propre panneau de
/// configuration. CrisperWhisper en avait une seconde ; elle est partie avec
/// la refonte de septembre 2026, **en même temps que la migration** qui
/// ramène ce réglage sur macOS à chaque lancement. Proposer encore la ligne
/// aurait laissé choisir un moteur, télécharger ses gigaoctets, puis tout
/// perdre au lancement suivant sans que rien ne le dise. La version de macOS
/// n'est pas un choix de même rang — c'est un détail interne à la famille —
/// d'où sa place **à l'intérieur** de la ligne, et non à côté.
///
/// ## Le commit transactionnel
///
/// Cliquer sur une ligne ne l'enregistre pas. C'était le cas, et ça cassait la
/// dictée en silence : cocher « CrisperWhisper » avant la fin du téléchargement
/// écrivait le choix dans les préférences, le contrôleur appelait un service
/// absent, et l'échec ne nommait pas sa cause.
///
/// Le clic ne fait donc que déplacer un **brouillon** (`draft`). L'écriture
/// dans `Preferences` n'a lieu que lorsque le moteur choisi est réellement
/// capable d'écrire — modèle installé, service debout. Tant que ce n'est pas le
/// cas, la dictée continue avec le moteur précédent, et le panneau ouvert
/// montre ce qu'il reste à faire.
struct FinalEngineCard: View, ValidatingComponent {
    @State private var prefs = Preferences.shared
    @State private var safety = EngineSafetyManager.shared
    /// Ce que l'utilisateur vient de désigner, prêt ou non.
    @State private var draft: Preferences.FinalEngineChoice?
    @State private var monitor = EngineStateMonitor.shared

    // MARK: - Validité

    /// Le brouillon n'entre pas en compte : c'est le moteur **enregistré** qui
    /// dictera si l'on ferme la fenêtre maintenant, et c'est donc lui qui
    /// décide si l'étape est franchissable.
    static func validate() -> ComponentValidationError? {
        switch Preferences.shared.finalEngine {
        case .apple: AppleEngineCard.validate()
        case .crisperWhisper: CrisperEngineCard.validate()
        }
    }

    /// Ce qui est affiché comme sélectionné : le brouillon, puis le réglage.
    private var shown: Preferences.FinalEngineChoice {
        draft ?? prefs.finalEngine
    }

    var body: some View {
        // Pas d'enveloppe : la carte de choix **est** le contenu de l'écran,
        // et l'emboîter dans une seconde ajouterait un cadre autour d'un cadre.
        VStack(alignment: .leading, spacing: 10) {
            choiceRow(.apple)

            if safety.isFallingBack {
                Note("**\(prefs.engine.fullLabel) n'est pas disponible pour "
                     + "l'instant.** Caspr dicte avec "
                     + "\(safety.effectiveEngine.fullLabel) en attendant, et "
                     + "reviendra tout seul à votre choix dès qu'il sera "
                     + "opérationnel — votre réglage n'a pas été modifié.",
                     warning: true)
            }
        }
        // Le brouillon devient le réglage dès que son moteur sait écrire. Vérifié
        // à chaque changement d'état plutôt qu'au clic : un téléchargement qui
        // se termine trente secondes plus tard doit commiter tout seul.
        .onChange(of: shown) { _, _ in commitIfReady() }
        .onChange(of: safety.isFallingBack) { _, _ in commitIfReady() }
        .task(id: shown) { commitIfReady() }
        // Et tant que le brouillon attend, on redemande.
        //
        // Les trois déclencheurs ci-dessus ne se produisent qu'au clic. Or ce
        // qu'on attend — un service qui finit de charger 3 Go — n'émet aucune
        // notification : ni fichier observé, ni objet observable. Le brouillon
        // ne s'enregistrait donc jamais tout seul. Conséquence visible : après
        // avoir démarré CrisperWhisper, changer d'onglet et revenir affichait
        // « macOS (Natif) » sélectionné, parce que la vue recréée repart du
        // réglage — resté sur macOS — et non du brouillon, perdu avec elle.
        //
        // La carte avait sa propre boucle pour ça. Elle observe désormais
        // `EngineStateMonitor`, qui regarde pour tout le monde : `isAnswering`
        // étant publié, un changement redessine cette vue, et `.onChange`
        // rejoue le commit. Une horloge de moins, et la même réaction.
        .onAppear { monitor.observe() }
        .onDisappear { monitor.release() }
        .onChange(of: monitor.isAnswering) { _, _ in commitIfReady() }
    }

    private func choose(_ choice: Preferences.FinalEngineChoice) {
        draft = choice
    }

    private func commitIfReady() {
        guard let draft, draft != prefs.finalEngine else { return }
        let target: EngineChoice = switch draft {
        case .crisperWhisper: .crisperWhisper
        case .apple: prefs.finalAppleTechnology
        }
        if safety.commit(target, for: prefs.primaryLanguage) {
            self.draft = nil
        }
    }

    // MARK: - La ligne

    @ViewBuilder
    private func choiceRow(_ choice: Preferences.FinalEngineChoice) -> some View {
        let selected = shown == choice
        let pending = draft == choice && prefs.finalEngine != choice

        ChoiceCard(title: title(for: choice),
                   subtitle: subtitle(for: choice),
                   selected: selected,
                   action: { choose(choice) }) {
            if pending {
                Note("Ce choix sera enregistré dès que le moteur sera prêt. "
                     + "En attendant, Caspr dicte toujours avec "
                     + "\(prefs.engine.fullLabel).")
            }
            switch choice {
            case .apple:
                AppleEngineCard(isSubCard: true, target: .final)
            // Jamais affichée : le cas ne survit dans l'énumération que
            // jusqu'à son retrait, dans un commit à lui.
            case .crisperWhisper:
                EmptyView()
            }
        }
    }

    /// Le titre et la description sont ceux du prototype : ils nomment ce
    /// que **change** le choix plutôt que la technologie.
    private func title(for choice: Preferences.FinalEngineChoice) -> String {
        switch choice {
        case .apple: "macOS (Natif)"
        case .crisperWhisper: "CrisperWhisper 2.0 (IA Multilingue & Code)"
        }
    }

    private func subtitle(for choice: Preferences.FinalEngineChoice) -> String {
        switch choice {
        case .apple:
            "Fourni par macOS : aucune licence, aucun compte, rien à installer, "
                + "et rien ne réside en mémoire entre deux dictées. **0 Mo de "
                + "RAM résidente**."
        case .crisperWhisper:
            "Deuxième passe intelligente par IA locale : comprend le "
                + "**Franglais sans changer de langue**, respecte le "
                + "**vocabulaire technique et le code** (`useEffect`, "
                + "variables) et nettoie les hésitations (*euh*)."
        }
    }
}

#Preview("Moteur final") {
    ScrollView {
        FinalEngineCard()
            .padding(Style.windowPadding)
    }
    .frame(width: Style.windowWidth, height: Style.windowHeight)
    .background(Color(hex: 0x141821))
}
