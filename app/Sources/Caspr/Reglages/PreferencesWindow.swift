import AppKit
import SwiftUI
import CasprCore

/// Fenêtre de réglages.
///
/// Caspr est une app d'arrière-plan sans Dock : ouvrir une fenêtre demande de
/// l'activer explicitement, sinon elle apparaît derrière tout le reste.
@MainActor
final class PreferencesWindowController {
    private var window: NSWindow?
    /// L'onglet affiché, tenu hors de la vue pour qu'on puisse y mener une
    /// fenêtre déjà ouverte — le menu et le raccourci de la voie y envoient
    /// quand ChatGPT n'est pas prêt.
    private let navigation = PreferencesNavigation()

    /// L'historique appartient au contrôleur de dictée : on le passe plutôt
    /// que d'en faire un singleton de plus, pour qu'il n'existe qu'un seul
    /// propriétaire de ces données.
    ///
    /// Sans onglet, la fenêtre s'ouvre là où on l'avait laissée.
    func show(history: TranscriptionHistory, on tab: PreferencesView.Tab? = nil) {
        if let tab { navigation.tab = tab }
        if let window {
            window.showCentered()
            return
        }

        let navigation = navigation
        let window = NSWindow.caspr(title: "Réglages de Caspr") {
            PreferencesView(history: history, navigation: navigation)
        }
        self.window = window

        window.showCentered()
    }
}

// MARK: - Fenêtre

@MainActor
@Observable
final class PreferencesNavigation {
    var tab: PreferencesView.Tab = .general
}

struct PreferencesView: View {
    let history: TranscriptionHistory
    @Bindable var navigation: PreferencesNavigation

    private var tab: Tab { navigation.tab }

    /// Quatre onglets, dans l'ordre où l'on se pose les questions : *ce qui
    /// vaut pour toute l'application*, *comment on déclenche*, *par où ça
    /// transcrit*, puis ce qui a été dicté.
    ///
    /// Il y en avait six. Les deux autres ne servaient que l'ancien moteur
    /// local — l'un le réglait, l'autre le comparait aux moteurs de macOS — et
    /// sont partis avec lui : la migration du lancement efface leurs réglages.
    enum Tab: String, CaseIterable {
        case general, recording, voie, history

        /// Le symbole de l'onglet.
        ///
        /// **Des SF Symbols, pas des émoji.** Le prototype en utilise, et c'est
        /// naturel dans un navigateur ; sur macOS ils détonnent : rendus en
        /// couleur pleine, à une graisse qui ne suit pas celle du texte, et
        /// différents d'une version du système à l'autre. Un symbole vectoriel
        /// prend la couleur de l'onglet — turquoise quand il est actif, gris
        /// sinon — et s'aligne sur la ligne de base du libellé.
        ///
        /// Le choix suit ce que la page *fait*, pas son titre :
        /// - La Voie est un aiguillage entre deux chemins — macOS ou ChatGPT —,
        ///   pas un moteur qu'on règle : d'où les deux flèches opposées.
        /// - `🕒` disait l'heure ; l'Historique dit ce qui est *passé* — d'où
        ///   la flèche qui revient en arrière.
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .recording: "mic"
            case .voie: "arrow.left.arrow.right"
            case .history: "clock.arrow.circlepath"
            }
        }

        /// « Dictée » plutôt qu'« Enregistrement », et c'est le seul écart de
        /// libellé avec le prototype.
        ///
        /// Mesuré : à 11,5 pt, les six libellés du prototype demandent environ
        /// 532 pt pour 516 disponibles dans la fenêtre. Ça déborde de peu, mais
        /// ça déborde — et `Enregistrement` est à lui seul l'excédent.
        /// `Dictée` couvre exactement la même chose : le déclencheur, l'aperçu
        /// en direct et les sons.
        var label: String {
            switch self {
            case .general: "Général"
            case .recording: "Dictée"
            case .voie: "Voie"
            case .history: "Historique"
            }
        }

        /// L'en-tête de l'onglet — titre à 18 pt, puis ce qu'on y règle.
        var header: (title: String, subtitle: String) {
            switch self {
            case .general:
                ("Réglages Généraux",
                 "Langue de travail, destination du texte transcrit et "
                    + "intégration système.")
            case .recording:
                ("Dictée & Barre flottante",
                 "Comment vous appelez Caspr, ce que la barre affiche pendant "
                    + "que vous parlez, et les sons qui l'accompagnent.")
            case .voie:
                ("Voie de Dictée",
                 "Qui transcrit ce que vous dites : macOS, sur ce Mac et sans "
                    + "compte, ou ChatGPT, par votre propre compte.")
            case .history:
                ("Historique des Dictées",
                 "Retrouvez et copiez vos dernières transcriptions locales en "
                    + "un clic.")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: tab.header.title,
                               subtitle: tab.header.subtitle,
                               scale: .tab)
                    switch tab {
                    case .general: GeneralTab()
                    case .recording: RecordingTab()
                    case .voie: CarteVoie()
                    case .history: HistoryTab(history: history)
                    }
                }
                // `.content-area { padding: 26px 30px 24px 30px }`. Les 30 pt
                // latéraux donnent les 520 pt de largeur utile sur lesquels
                // toutes les cartes du prototype ont été dessinées ; la barre
                // d'onglets, elle, a sa propre marge et n'est pas concernée.
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.top)
        }
        .background(WindowBackground().ignoresSafeArea())
        .tint(Style.accent)
    }

    /// La barre segmentée du prototype : un rail sombre à coins arrondis, des
    /// boutons de largeur égale, l'actif en turquoise bordé.
    ///
    /// Elle réserve les 48 pt de la barre de titre au-dessus d'elle : la
    /// fenêtre est en `fullSizeContentView`, donc sans cette marge les onglets
    /// passeraient sous les feux tricolores.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { item in
                let active = item == tab
                // Un vrai bouton, pas un `Text` avec `onTapGesture` : celui-ci
                // n'existe ni pour le clavier ni pour VoiceOver, qui annonçait
                // « texte » sur ce qui est la navigation principale de la
                // fenêtre. Un bouton se tabule, se déclenche à l'Espace et
                // s'annonce comme sélectionné.
                Button {
                    navigation.tab = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11.5, weight: .medium))
                            .imageScale(.medium)
                        Text(item.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(active ? Style.accent : Style.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? Style.accent.opacity(0.12) : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 7,
                                                      style: .continuous)
                                .strokeBorder(active ? Style.accentBorder : .clear,
                                              lineWidth: 1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)))
        // Serré : le rail borde la fenêtre au lieu de flotter au milieu d'une
        // bande. `.top` ne réserve que la barre de titre, sans marge ajoutée —
        // l'écart au-dessus faisait lire les onglets comme un bloc détaché,
        // alors qu'ils appartiennent au chrome de la fenêtre.
        // Pas de marge haute ajoutée : la fenêtre est en `fullSizeContentView`,
        // mais SwiftUI réserve quand même l'encart de sécurité de la barre de
        // titre. Les 40 pt que j'ajoutais s'empilaient dessus et creusaient un
        // vide de la hauteur d'une carte au-dessus des onglets.
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(
            Color(hex: 0x0F172A).opacity(0.65)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                })
    }
}
