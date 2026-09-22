import SwiftUI

/// La bascule de langue principale, dans les Réglages.
///
/// ## Pourquoi la forme change avec le nombre de langues
///
/// Les pastilles sont le meilleur contrôle pour deux options : la bascule coûte
/// un clic et les deux choix restent lisibles côte à côte. À partir de trois,
/// elles débordent des 520 pt utiles ou s'écrasent — et un contrôle qui change
/// de taille selon son contenu fait sauter la hauteur de la carte à chaque
/// ajout de langue.
///
/// Au-delà de deux, on passe donc à un menu déroulant : hauteur constante,
/// aucun débordement possible, et c'est le contrôle que macOS emploie lui-même
/// pour ce genre de choix.
///
/// Le catalogue complet, lui, reste replié. Quelqu'un vient ici pour **changer
/// de langue**, pas pour reconfigurer sa liste : déplier 39 entrées par défaut
/// pousserait tout le reste de l'onglet hors de l'écran.
struct PrimaryLanguageSelector: View {
    @State private var prefs = Preferences.shared
    @State private var showsCatalog = false

    /// Le seuil au-delà duquel les pastilles ne tiennent plus.
    private static let pillLimit = 2

    var body: some View {
        Card {
            // « Langue active : » à gauche, le sélecteur à droite — la
            // `card-row` du prototype. Les pastilles étaient collées à gauche
            // sans rien pour les nommer : la ligne ne disait pas de quoi elle
            // parlait, et rien ne l'alignait sur les autres réglages de la
            // fenêtre, qui posent tous leur libellé à gauche.
            HStack(spacing: 12) {
                Text("Langue active :")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)

                if prefs.selectedLanguages.count <= Self.pillLimit {
                    PillPicker(options: prefs.activeLanguages.map { ($0.code, $0.badge) },
                               selection: $prefs.primaryLanguage)
                } else {
                    Picker("", selection: $prefs.primaryLanguage) {
                        ForEach(prefs.activeLanguages) { language in
                            Text(language.badge).tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            // La note d'abord, le bouton ensuite : elle explique l'état, il
            // propose l'action. Les intervertir ferait lire la conséquence
            // avant la cause.
            if !showsCatalog {
                // Ne dit plus « la première est celle avec laquelle Caspr
                // dicte » : c'est devenu faux le jour où la langue principale
                // a cessé de se déduire de l'ordre de la liste.
                Note(prefs.selectedLanguages.count > Self.pillLimit
                     ? "Vous avez \(prefs.selectedLanguages.count) langues actives configurées."
                     : "La langue principale pilote la reconnaissance vocale.")
            }

            Divider().opacity(0.25)

            catalogueToggle

            if showsCatalog {
                LanguagePicker()
            }
        }
        // Au tout premier affichage, la langue n'a peut-être jamais été
        // sondée : « inconnue » ne dit rien à personne.
        .onAppear { SpeechAssets.shared.probe([prefs.primaryLanguage]) }
    }

    /// Le bouton qui déplie le catalogue — **toute la ligne**, pas le chevron.
    ///
    /// C'était un `DisclosureGroup`, et c'était un piège : sous macOS, seul le
    /// petit triangle réagit au clic. On vise « Gérer / ajouter des langues… »,
    /// il ne se passe rien, et on en conclut que le bouton est cassé. Le
    /// prototype a la même faiblesse — son libellé est du texte à côté d'un
    /// bouton — mais l'avoir dans les deux ne la rend pas acceptable.
    ///
    /// Une seule cible, large de toute la carte : impossible de la manquer, et
    /// le survol montre où elle commence et où elle finit.
    private var catalogueToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { showsCatalog.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                Text(showsCatalog ? "Masquer le catalogue"
                                  : "Gérer / Ajouter des langues...")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(showsCatalog ? 90 : 0))
            }
            .foregroundStyle(Style.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // Sans ça, seuls les pixels du texte et de l'icône seraient
            // cliquables, et le vide entre les deux ne le serait pas.
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
        .accessibilityLabel(showsCatalog ? "Masquer le catalogue de langues"
                                         : "Gérer ou ajouter des langues")
        .accessibilityAddTraits(showsCatalog ? [.isSelected, .isButton] : .isButton)
    }

}

#Preview("Langue principale") {
    ScrollView {
        PrimaryLanguageSelector()
            .padding(Style.windowPadding)
    }
    .frame(width: Style.windowWidth, height: Style.windowHeight)
    .background(Color(hex: 0x141821))
}
