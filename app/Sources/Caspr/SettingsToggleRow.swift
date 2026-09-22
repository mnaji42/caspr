import SwiftUI

/// La bascule d'une fonctionnalité entière : titre, explication, interrupteur.
///
/// Le composant universel de toutes les bascules de Caspr — aperçu en direct,
/// sons, historique, démarrage, mises à jour automatiques. Il existe
/// parce que ces réglages étaient écrits à la main à chaque endroit, avec des
/// tailles de police et des espacements qui avaient dérivé : le même
/// interrupteur paraissait plus important dans un onglet que dans un autre,
/// sans que rien ne le justifie.
///
/// ## Interrupteur, et pas case à cocher
///
/// La distinction n'est pas décorative, et `FeatureSwitch` la portait déjà :
/// une case à cocher se lit « ce détail est retenu », un interrupteur « cette
/// fonctionnalité est en marche ». Les confondre fait mettre en marche toute
/// une fonctionnalité en croyant cocher une préférence. Les sous-options gardent donc
/// `OptionCheck`.
struct SettingsToggleRow: View {
    let title: String
    /// La conséquence du réglage, en une phrase. Sous le titre, en petit.
    var description: String?
    /// Ce qu'il faut savoir en plus — vie privée, coût en mémoire, piège
    /// connu. Sous l'interrupteur, sur toute la largeur.
    var note: String?
    /// Rendu en ambre : sert aux notes qui avertissent, pas à celles qui
    /// expliquent.
    var noteIsWarning = false
    @Binding var isOn: Bool
    var disabled = false
    /// Enveloppé dans une `Card`, ou posé nu dans une carte existante.
    var isCard = true
    /// Relayée à la `Card` englobante quand il y en a une.
    var bottomMargin: CGFloat = 12

    var body: some View {
        // `isCard` décide du **cadre**, jamais du titre. Le passer à
        // `Card(title:)` le faisait remonter en capitales espacées au-dessus de
        // la carte, comme un libellé de section — si bien que « Lancer Caspr à
        // l'ouverture de session » criait plus fort que le titre de l'écran.
        // Dans le prototype, le titre est une ligne ordinaire *dans* la carte.
        if isCard {
            Card(bottomMargin: bottomMargin) { content }
        } else {
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let description {
                    Text(.init(description))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .toggleStyle(CasprSwitch())
                .labelsHidden()
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
        }
        // Le titre part quand même à VoiceOver quand la carte le porte :
        // l'interrupteur seul s'annoncerait « activé », sans dire de quoi.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)

        if let note {
            Note(note, warning: noteIsWarning)
        }
    }
}

#Preview("Bascules") {
    @Previewable @State var live = true
    @Previewable @State var sons = false
    @Previewable @State var verrou = true

    return VStack(alignment: .leading, spacing: 16) {
        SettingsToggleRow(
            title: "Afficher l'aperçu du texte en direct",
            description: "Montre sous la barre ce que macOS entend pendant que vous parlez.",
            note: "Indicatif : le moteur d'aperçu n'a pas votre vocabulaire "
                + "technique, donc le texte inséré peut différer.",
            isOn: $live)

        SettingsToggleRow(title: "Sons de début et de fin",
                          description: "Deux clics discrets, au démarrage et à l'arrêt.",
                          isOn: $sons, isCard: false)

        SettingsToggleRow(title: "Conserver l'historique",
                          description: "Les dernières transcriptions, pour les réinsérer.",
                          note: "Réglage verrouillé pendant une dictée en cours.",
                          noteIsWarning: true,
                          isOn: $verrou, disabled: true)
    }
    .padding(Style.windowPadding)
    .frame(width: Style.windowWidth)
    .background(Color(hex: 0x141821))
}
