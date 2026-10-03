import AppKit
import SwiftUI

/// Comment on lance une dictée, et les deux droits que ça demande.
///
/// La même vue dans l'accueil et dans les Réglages — c'est tout l'intérêt du
/// composant. Ses deux paramètres ne règlent que ce qui n'a de sens qu'à un
/// endroit : la zone d'essai à l'accueil, quand on n'a encore jamais vu Caspr
/// écrire ; le raccourci « Changer de voie » dans les Réglages, parce que
/// l'accueil ne présente pas encore les deux voies.
///
/// ## Ce qui se replie, et ce qui ne doit jamais se replier
///
/// Le prototype réduit chaque autorisation accordée à une ligne `✓`, et c'est
/// juste : une fois le droit obtenu, l'encart explicatif n'est plus qu'un pavé
/// qui pousse le reste vers le bas.
///
/// Mais il replie **tous** les cas de la même façon, et deux d'entre eux ne
/// sont pas des « pas encore accordé » :
///
/// - **Micro refusé.** macOS ne représente plus jamais son dialogue une fois le
///   refus enregistré. Un bouton « Accorder » qui n'ouvre rien laisse cliquer
///   dans le vide ; il faut envoyer aux Réglages Système.
/// - **Accessibilité accordée à une autre signature.** Caspr apparaît coché
///   dans les Réglages Système et l'application ne le voit pas — parce que
///   macOS attache le droit à une signature, pas à un chemin. Décocher puis
///   recocher n'y change rien. C'est une heure perdue par qui ne le sait pas,
///   et ça se produit à **chaque mise à jour** d'une application signée ad hoc.
///
/// Ces deux cas gardent donc leur explication complète et leur échappatoire.
/// Le repli en `✓` vaut pour ce qui est acquis, pas pour ce qui est coincé.
struct TriggerCard: View, ValidatingComponent {
    /// Affiche la zone d'essai. Vrai dans l'accueil, faux dans les Réglages.
    var showTrialSandbox = true
    /// Affiche le raccourci « Changer de voie ». Faux dans l'accueil.
    var showVoieShortcut = false
    /// La voie retenue peut-elle dicter ? Transmis à la zone d'essai, qui ne
    /// juge que des droits ; c'est l'accueil, qui observe la voie, qui le sait.
    var voiePrete = true

    @State private var prefs = Preferences.shared
    @State private var monitor = PermissionsMonitor.shared

    // MARK: - Validité

    /// Micro **et** accessibilité : sans les deux, la dictée ne peut ni
    /// entendre ni écrire.
    ///
    /// La reconnaissance vocale n'en fait pas partie — elle dépend du moteur
    /// retenu et appartient à `AppleEngineCard`. L'exiger ici bloquerait
    /// quelqu'un qui dictera avec Apple Intelligence sur un droit dont il n'a
    /// pas l'usage.
    static func validate() -> ComponentValidationError? {
        let monitor = PermissionsMonitor.shared
        if monitor.micAccess != .granted { return .microphonePermissionRequired }
        if !monitor.accessibilityGranted { return .accessibilityPermissionRequired }
        return nil
    }

    private var permissionsComplete: Bool { Self.isValid }

    var body: some View {
        Card {
            Row(label: "Dicter avec :") {
                PillPicker(options: [(Preferences.TriggerKind.option, "Touche Option"),
                                     (Preferences.TriggerKind.shortcut, "Raccourci clavier")],
                           selection: $prefs.triggerKind)
            }

            if prefs.triggerKind == .option {
                optionMode
            } else {
                shortcutMode
            }

            if showVoieShortcut {
                Divider().opacity(0.25)
                voieShortcut
            }

            permissions

            if showTrialSandbox {
                Divider().opacity(0.25)
                TrialSandbox(isLocked: !permissionsComplete,
                             voiePrete: voiePrete,
                             triggerLabel: triggerLabel)
            }
        }
        // L'horloge des autorisations ne tourne que pendant qu'une vue la
        // regarde : Caspr vit en permanence en arrière-plan, et un timer à
        // 1 Hz qui ne s'arrête jamais est une dépense sans contrepartie.
        .onAppear { monitor.observe() }
        .onDisappear { monitor.release() }
    }

    /// Le déclencheur réellement actif — un seul l'est à la fois.
    private var triggerLabel: String {
        prefs.triggerKind == .option
            ? prefs.triggerSide.label
            : prefs.dictateShortcut.label
    }

    // MARK: - Les deux modes

    /// Le mode « touche Option ».
    ///
    /// ## Il n'y a plus de choix du côté
    ///
    /// Le Swift proposait « droite / gauche ». Le prototype a retiré ce choix,
    /// et il a raison : la touche est celle de droite, point. Le côté gauche
    /// sert couramment à autre chose — c'est le modificateur des raccourcis
    /// qu'on tape à une main — et l'offrir invitait à s'installer un
    /// déclencheur qui se déclenche tout seul.
    ///
    /// La conséquence est que le texte peut enfin être affirmatif : « située à
    /// droite de la barre d'espace » plutôt qu'une phrase qui doit couvrir les
    /// deux cas. Le réglage reste dans le modèle — le tap clavier a besoin d'un
    /// côté — mais il n'est plus une question posée à l'utilisateur.
    @ViewBuilder
    private var optionMode: some View {
        Text(.init("Utilise la touche **Option (⌥)** située à droite de la "
                   + "barre d'espace."))
            .font(.system(size: 11.5))
            .foregroundStyle(Style.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 4) {
            gesture("1er appui :", "Ouvre la barre flottante et commence l'enregistrement")
            gesture("2e appui :", "Termine l'écoute et insère le texte au curseur")
            gesture("Échap (⎋)", "pendant l'enregistrement : Annule la dictée sans rien écrire")
        }
        Note("La touche reste utilisable normalement : rien ne se déclenche si "
             + "une autre touche est pressée entre-temps. **Maintenir Option "
             + "une seconde** ouvre les Réglages.")
    }

    private func gesture(_ key: String, _ effect: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.tertiary)
            Text(.init("**\(key)** \(effect)"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var shortcutMode: some View {
        Row(label: "Raccourci :") {
            ShortcutRecorder(shortcut: $prefs.dictateShortcut)
                .frame(width: 150, height: 26)
                .help("Cliquez pour changer le raccourci")
        }
        if same(prefs.dictateShortcut, .history) {
            // macOS ne donne une combinaison qu'au premier arrivé : l'une des
            // deux fonctions cesserait de répondre, sans rien pour le dire.
            Note("\(prefs.dictateShortcut.label) ouvre déjà l'historique : "
                 + "choisissez-en un autre.", warning: true)
        }
        Note("Cliquez puis tapez la combinaison voulue. macOS refuse les "
             + "raccourcis sans Contrôle ni Commande. La touche Option ne "
             + "déclenche plus rien. Vous déclenchez l'écoute avec votre "
             + "raccourci, et Caspr insère le texte directement à votre "
             + "curseur grâce à l'Accessibilité.")
    }

    // MARK: - Changer de voie

    /// Un second raccourci, facultatif, qui fait passer de macOS à ChatGPT et
    /// retour.
    ///
    /// Carbon, comme celui de la dictée : il ne demande aucune autorisation,
    /// et il marche quel que soit le déclencheur retenu — la touche Option
    /// seule ne sait porter qu'un geste.
    @ViewBuilder
    private var voieShortcut: some View {
        Row(label: "Changer de voie :") {
            HStack(spacing: 8) {
                if prefs.voieShortcut != nil {
                    Button("Retirer") { prefs.voieShortcut = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                ShortcutRecorder(optional: $prefs.voieShortcut,
                                 id: HotkeyMonitor.Shortcut.voieID)
                    .frame(width: 150, height: 26)
                    .help("Cliquez pour choisir un raccourci")
            }
        }
        if let conflit = voieShortcutConflict {
            Note(conflit, warning: true)
        } else {
            Note("Passe de macOS à ChatGPT et retour, sans ouvrir de menu. "
                 + "Aucun par défaut : un raccourci global prend la combinaison "
                 + "à toutes les applications. Le menu de la barre porte la même "
                 + "bascule.")
        }
    }

    /// Une combinaison déjà prise par Caspr lui-même.
    ///
    /// macOS n'en enregistre qu'une par combinaison, et c'est la première
    /// arrivée qui la garde : la dictée, enregistrée avant, la garde — la
    /// bascule ne répondrait jamais, sans rien pour le dire.
    private var voieShortcutConflict: String? {
        guard let voie = prefs.voieShortcut else { return nil }
        if prefs.triggerKind == .shortcut, same(voie, prefs.dictateShortcut) {
            return "\(voie.label) déclenche déjà la dictée : choisissez-en un autre."
        }
        if same(voie, .history) {
            return "\(voie.label) ouvre déjà l'historique : choisissez-en un autre."
        }
        return nil
    }

    private func same(_ a: HotkeyMonitor.Shortcut, _ b: HotkeyMonitor.Shortcut) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    // MARK: - Autorisations

    /// L'encart d'action pour ce qui manque, les lignes `✓` pour ce qui est
    /// acquis. Rien du tout quand les deux sont accordés et qu'il n'y a donc
    /// plus de décision à prendre.
    @ViewBuilder
    private var permissions: some View {
        if !permissionsComplete {
            VStack(alignment: .leading, spacing: 10) {
                if monitor.micAccess != .granted { microphone }
                if monitor.micAccess != .granted, !monitor.accessibilityGranted {
                    Divider().opacity(0.25)
                }
                if !monitor.accessibilityGranted { accessibility }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Style.innerRadius, style: .continuous)
                    .fill(Style.innerBoxFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Style.innerRadius,
                                         style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)))
        }

        VStack(alignment: .leading, spacing: 3) {
            if monitor.micAccess == .granted {
                GrantedLine("Accès Microphone accordé")
            }
            if monitor.accessibilityGranted {
                GrantedLine("Accès Accessibilité accordé")
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 8) {
            PermissionNeed(
                title: "Accès Microphone",
                detail: "Requis pour écouter votre voix lorsque vous pressez "
                    + "la touche.",
                // Refusé : le bouton d'action serait un bouton qui ne fait
                // rien, puisque macOS ne représente plus le dialogue.
                action: monitor.micAccess == .undetermined ? "Accorder" : nil) {
                Task { await monitor.requestMicrophone() }
            }

            if monitor.micAccess == .denied {
                Note("macOS ne représente plus son dialogue une fois le refus "
                     + "enregistré : il faut réactiver Caspr à la main.",
                     warning: true)
                ButtonRow {
                    Button("Ouvrir Réglages Système › Micro") {
                        Permissions.openMicrophoneSettings()
                    }
                }
            }
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 8) {
            PermissionNeed(
                title: "Accès Accessibilité",
                detail: "Requis pour écouter la touche Option seule et insérer "
                    + "le texte à votre curseur.",
                action: "Accorder") {
                NSApp.activate(ignoringOtherApps: true)
                Permissions.requestAccessibility()
            }
            Note("macOS ne laisse aucune application s'accorder ce droit "
                 + "elle-même. Caspr reste ouvert pendant ce temps et se met "
                 + "à jour tout seul dès que c'est fait.")
            StuckAccessibilityNote()
        }
    }
}

// MARK: - Pièces

/// Une autorisation manquante : ce que c'est, à quoi elle sert, et le bouton.
private struct PermissionNeed: View {
    let title: String
    let detail: String
    /// `nil` retire le bouton : il y a des impasses où il n'ouvrirait rien, et
    /// un bouton qui ne fait rien est pire que pas de bouton.
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .strokeBorder(Style.warning, lineWidth: 1.5)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.borderedProminent)
                    .tint(Style.accent)
                    .controlSize(.small)
            }
        }
    }
}

/// Une autorisation acquise, en une ligne qui ne prend plus de place.
struct GrantedLine: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Style.accent).frame(width: 15, height: 15)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Style.onAccent)
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Style.accent)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), accordé")
    }
}

/// Le piège de l'autorisation attachée à une signature.
///
/// Caspr apparaît coché dans les Réglages Système, et `AXIsProcessTrusted()`
/// répond faux. Ce n'est ni un bug ni un oubli : macOS indexe le droit
/// d'accessibilité sur la **signature** du binaire. Une application signée ad
/// hoc change de signature à chaque compilation, donc **à chaque mise à jour**
/// — et l'entrée cochée pilote un enregistrement périmé que décocher/recocher
/// ne répare pas.
///
/// Cette vue est séparée parce que le cas se produit aussi hors de l'accueil,
/// et qu'elle a coûté assez de temps pour mériter d'être nommée à l'écran
/// plutôt que redécouverte.
struct StuckAccessibilityNote: View {
    /// Une réinitialisation par ouverture de fenêtre : recliquer sans être
    /// passé par les Réglages Système effacerait ce qu'on vient d'accorder.
    @State private var justReset = false

    var body: some View {
        Divider().opacity(0.25)
        Note("**Caspr apparaît déjà coché dans les Réglages Système ?** "
             + "L'autorisation a été accordée à une version signée autrement, "
             + "et macOS ne la reconnaît plus. Décocher puis recocher n'y fera "
             + "rien : la case pilote une entrée périmée.")
        ButtonRow {
            Button(justReset ? "Autorisation effacée — recochez la case"
                             : "Réinitialiser l'autorisation") {
                Permissions.resetAccessibility()
                PermissionsMonitor.shared.refresh()
                justReset = true
            }
            .disabled(justReset)
            Button("Ouvrir les Réglages Système") {
                Permissions.openAccessibilitySettings()
            }
        }
    }
}

#Preview("Déclencheur") {
    ScrollView {
        TriggerCard()
            .padding(Style.windowPadding)
    }
    .frame(width: Style.windowWidth, height: Style.windowHeight)
    .background(Color(hex: 0x141821))
}
