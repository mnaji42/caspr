import AppKit
import SwiftUI

/// Le vocabulaire visuel commun à la barre flottante et aux réglages.
///
/// Il existe parce que les deux surfaces se ressemblaient de loin sans jamais
/// se répondre : la barre avait son verre, sa teinte et ses pastilles, les
/// réglages affichaient des `Form` système gris. Deux dialectes pour une même
/// application. Les valeurs ci-dessous sont celles de `RecordingOverlay`, une
/// seule fois, pour qu'elles ne divergent pas.
enum Style {
    // MARK: Couleurs

    /// Le turquoise de Caspr.
    ///
    /// Une valeur fixe, et non `NSColor.systemTeal` : la teinte système varie
    /// d'une version de macOS à l'autre et se désature hors focus, ce qui
    /// faisait dériver l'identité de l'application au fil des mises à jour.
    /// Toutes les surfaces de Caspr sont sombres, donc rien n'oblige à suivre
    /// l'apparence claire du système.
    static let accent = Color(hex: 0x00E5CC)
    static let accentHover = Color(hex: 0x38EFD8)
    static let accentDim = accent.opacity(0.12)
    static let accentBorder = accent.opacity(0.35)
    static let accentGlow = accent.opacity(0.30)
    /// Le texte posé **sur** l'accent. Presque noir, verdâtre : le blanc sur
    /// turquoise vif tombe sous le seuil de contraste lisible.
    static let onAccent = Color(hex: 0x042F2E)

    /// L'orange de ce qui reste à faire : une autorisation pas encore
    /// accordée, un état système à corriger.
    static let pending = Color(hex: 0xFB923C)
    /// L'ambre des avertissements, dans les réglages. Distinct du précédent :
    /// « il reste une étape » et « attention » ne disent pas la même chose et
    /// ne doivent pas se confondre d'un coup d'œil.
    static let warning = Color(hex: 0xF59E0B)
    /// Le rouge du **texte** — `--danger`. Clair, pour rester lisible sur le
    /// fond sombre.
    static let danger = Color(hex: 0xF87171)

    /// Le rouge des **surfaces** : bouton plein, fond et bordure d'alerte.
    ///
    /// Le prototype emploie deux rouges et c'est délibéré : `#f87171` pour
    /// écrire, `#ef4444` pour remplir. Remplir avec celui du texte donnait un
    /// bouton rose, qui n'a pas la gravité d'une désinstallation.
    static let dangerSurface = Color(hex: 0xEF4444)

    static let textPrimary = Color(hex: 0xF8FAFC)
    static let textSecondary = Color(hex: 0x94A3B8)
    static let textTertiary = Color(hex: 0x64748B)

    // MARK: Surfaces

    static let cardFill = Color.white.opacity(0.035)
    static let cardHover = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.08)
    /// Le fond des encarts d'action à l'intérieur d'une carte.
    static let innerBoxFill = Color.black.opacity(0.28)

    // MARK: Géométrie

    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    /// Encarts d'action et zone d'essai, à l'intérieur d'une carte.
    static let innerRadius: CGFloat = 11
    /// Champs de saisie et barres de recherche.
    static let fieldRadius: CGFloat = 9

    // MARK: Fenêtres

    /// Largeur commune à l'accueil et aux réglages.
    ///
    /// Elle est **identique** dans les deux fenêtres, et c'est tout l'intérêt :
    /// les cartes de configuration sont les mêmes vues, instanciées aux deux
    /// endroits. Une largeur qui diffère de dix points suffit à faire passer un
    /// libellé sur deux lignes ici et une seule là, et la même carte paraît
    /// alors avoir été dessinée deux fois.
    static let windowWidth: CGFloat = 580
    static let windowHeight: CGFloat = 700
    static let windowPadding: CGFloat = 30
    /// Largeur utile des cartes — `windowWidth - 2 × windowPadding`.
    static var contentWidth: CGFloat { windowWidth - 2 * windowPadding }
}

extension NSColor {
    /// L'accent de Caspr, pour le code AppKit — barre d'enregistrement,
    /// enregistreur de raccourci, vumètre.
    ///
    /// La même valeur que `Style.accent`, et non `systemTeal` : la teinte
    /// système varie d'une version de macOS à l'autre et se désature hors
    /// focus, si bien que les surfaces AppKit et SwiftUI de l'application
    /// avaient fini par ne plus s'accorder tout à fait.
    static let casprAccent = NSColor(srgbRed: 0x00 / 255.0, green: 0xE5 / 255.0,
                                      blue: 0xCC / 255.0, alpha: 1)

    /// Le fond de fenêtre de l'application — `--bg-window`, `#141821` à 85 %.
    ///
    /// Le même pour l'accueil, les réglages et la barre d'écoute : c'est ce
    /// que `WindowBackground` pose en SwiftUI, repris ici pour AppKit.
    static let casprWindow = NSColor(srgbRed: 0x14 / 255.0, green: 0x18 / 255.0,
                                      blue: 0x21 / 255.0, alpha: 0.85)

    /// L'ambre des avertissements, pour le code AppKit.
    static let casprWarning = NSColor(srgbRed: 0xF5 / 255.0, green: 0x9E / 255.0,
                                       blue: 0x0B / 255.0, alpha: 1)
}

/// Un dessin de la marque, chargé depuis `Resources/icons`.
///
/// Les SVG de Caspr voyagent dans le bundle plutôt que dans un catalogue
/// d'actifs : `install.sh` les copie tels quels, et ils servent aussi à
/// fabriquer l'`.icns`. Deux vues les chargeaient déjà chacune de leur côté,
/// avec le même `Bundle.main.url(forResource:withExtension:subdirectory:)`
/// recopié — d'où cette vue, qui porte aussi le repli.
///
/// Rend `nil` plutôt que de dessiner un rectangle vide : une icône absente est
/// une erreur d'empaquetage, et la fenêtre qui l'accueille sait se passer d'elle
/// mieux qu'elle ne saurait afficher un trou.
struct BrandIcon: View {
    let name: String
    var height: CGFloat

    init?(_ name: String, height: CGFloat) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg",
                                        subdirectory: "icons"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        self.name = name
        self.height = height
        self.image = image
    }

    private let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            // Le dessin porte sa propre identité : le lire à voix haute
            // « image » n'apprend rien, le nommer si.
            .accessibilityLabel("Caspr")
    }
}

extension Color {
    /// Couleur depuis un littéral hexadécimal — `Color(hex: 0x00E5CC)`.
    ///
    /// Un entier plutôt qu'une chaîne : la chaîne oblige à traiter le cas du
    /// format invalide, qui ne peut pas arriver dans du code compilé et qui se
    /// solde toujours par un `?? .clear` invisible à la relecture.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension NSWindow {
    /// Crée une fenêtre Caspr autour d'une vue SwiftUI.
    ///
    /// ## Pourquoi une fabrique, et pas trois appels à la suite
    ///
    /// Parce qu'une des étapes est facile à oublier et qu'elle casse tout.
    ///
    /// `NSHostingController` propage par défaut la taille *idéale* de sa vue
    /// SwiftUI vers la fenêtre — c'est `sizingOptions = .preferredContentSize`
    /// — et il le fait **après** l'appel qui fixe la taille. Une page dont le
    /// contenu dépasse produit donc une fenêtre plus haute que l'écran, dont le
    /// pied devient inatteignable : le bouton « Continuer » de l'accueil se
    /// retrouve sous le bord inférieur, sans aucun moyen de l'atteindre puisque
    /// la fenêtre n'est pas redimensionnable. Constaté, et parfaitement muet
    /// côté compilation.
    ///
    /// La fabrique neutralise donc ce comportement : c'est la **fenêtre** qui
    /// impose sa taille, et le contenu qui défile dedans.
    static func caspr<Content: View>(title: String,
                                      @ViewBuilder content: () -> Content) -> NSWindow {
        let hosting = NSHostingController(rootView: content())
        // Aucune remontée de taille : sans ça, tout ce qui suit est écrasé.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        // Le fond est peint par la vue : sans ça, macOS glisse son gris système
        // derrière et les surfaces de l'application ne se ressemblent plus.
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        // Les fenêtres de Caspr contiennent des boutons qui ouvrent les
        // Réglages Système. Sans ça, elles s'effacent au moment d'y aller, et
        // on revient devant rien — en croyant avoir fait fuir l'application.
        window.hidesOnDeactivate = false
        window.applyCasprGeometry()
        return window
    }

    /// Applique la géométrie commune : 580 × 700, non redimensionnable.
    ///
    /// La hauteur est **écrêtée à l'écran**. Les documents de conception la
    /// notaient `min(700pt, 92vh)`, ce qui est du raisonnement web : il n'y a
    /// pas de `vh` en AppKit, et une fenêtre non redimensionnable plus haute
    /// que la zone utile devient une fenêtre dont on ne peut plus atteindre le
    /// bas — ni le bouton qui s'y trouve. `visibleFrame` retire déjà la barre
    /// de menus et le Dock ; la marge couvre l'ombre et la barre de titre.
    ///
    /// Écrêter plutôt qu'autoriser le redimensionnement : la largeur, elle, ne
    /// doit jamais bouger, sinon les cartes partagées entre l'accueil et les
    /// réglages ne se ressemblent plus.
    func applyCasprGeometry() {
        let available = (screen ?? NSScreen.main)?.visibleFrame.height
            ?? Style.windowHeight
        let height = min(Style.windowHeight, available - 40)
        setContentSize(NSSize(width: Style.windowWidth, height: height))
        // Sans ça, la fenêtre reste étirable par les bords même dépourvue du
        // bouton d'agrandissement.
        styleMask.remove(.resizable)
    }

    /// Affiche la fenêtre, centrée, en activant l'application.
    ///
    /// Le centrage a lieu **après** `makeKeyAndOrderFront`, et c'est nécessaire :
    /// centrer une fenêtre qui n'est pas encore à l'écran ne tient pas — macOS
    /// la repositionne au moment de l'afficher, et les Réglages sortaient à
    /// cheval sur le bord droit, avec leur moitié droite hors de l'écran.
    ///
    /// Caspr n'a pas de Dock : sans `activate`, la fenêtre apparaîtrait derrière
    /// tout le reste, ce qui pour une application d'arrière-plan revient à ne pas
    /// s'ouvrir du tout.
    func showCentered() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        center()
    }
}

/// Le verre du fond, identique à celui de la barre.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Le fond des fenêtres de configuration.
///
/// Le verre seul ne suffisait pas, et c'était visible : `hudWindow` en
/// `behindWindow` laisse passer assez du bureau pour que le papier peint
/// traverse les cartes, que les contrastes changent selon ce qu'il y a
/// derrière, et qu'un texte secondaire devienne illisible sur une photo claire.
/// La barre flottante peut se le permettre — elle est petite et éphémère ; une
/// fenêtre qu'on lit pendant plusieurs minutes, non.
///
/// D'où la couche à 85 % par-dessus, à la valeur du prototype
/// (`rgba(20, 24, 33, 0.85)`) : il reste un bel effet de verre glasmorphisme
/// caractéristique de macOS, tout en maintenant un contraste élevé sur fond blanc.
struct WindowBackground: View {
    var body: some View {
        ZStack {
            GlassBackground()
            Color(hex: 0x141821).opacity(0.85)
        }
    }
}

/// La barre de titre : la place des feux tricolores, et ce qu'on met à droite.
///
/// La fenêtre est en `fullSizeContentView`, donc le contenu passerait sous les
/// feux sans cette réserve de 48 pt. Le titre lui-même reste celui de macOS —
/// le redessiner donnerait deux titres à trois pixels d'écart.
struct WindowChrome<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Spacer()
            trailing
        }
        .frame(height: 48)
        .padding(.horizontal, Style.windowPadding)
    }
}

/// L'en-tête d'un écran : titre et phrase d'introduction.
///
/// Reprend `.page-header` du prototype — 24 pt gras avec un crénage serré, un
/// sous-titre de 13 pt, et 20 pt sous l'ensemble.
struct PageHeader: View {
    /// Un en-tête d'onboarding et un en-tête d'onglet n'ont pas le même poids.
    ///
    /// L'écran d'onboarding n'a que ça à dire : son titre peut occuper la
    /// place. L'onglet de réglages, lui, coiffe six sections dans une fenêtre
    /// de 580 pt — un titre à 24 pt y écraserait les libellés de section qu'il
    /// est censé introduire. Les six onglets du prototype surchargent tous
    /// `h1` à 18 pt et la marge basse à 14 pt ; c'est cette échelle-là.
    enum Scale {
        /// Une étape d'accueil, qui n'a que ça à dire.
        case screen
        /// Un onglet de réglages, qui coiffe des sections.
        case tab
        /// L'écran final de l'accueil. Il ne présente rien : il constate. Le
        /// prototype le resserre à l'extrême — titre à 18 pt, deux points
        /// sous le titre, deux points sous l'ensemble — pour que le
        /// récapitulatif commence presque tout de suite.
        case summary

        var titleSize: CGFloat { self == .screen ? 24 : 18 }

        var titleGap: CGFloat { self == .summary ? 2 : 6 }

        var bottomMargin: CGFloat {
            switch self {
            case .screen: 20
            case .tab: 14
            case .summary: 2
            }
        }

        /// `letter-spacing: -0.03em`, donc proportionnel au corps.
        var kerning: CGFloat { titleSize * -0.03 }
    }

    let title: String
    var subtitle: String?
    var scale: Scale = .screen
    /// Posé à droite, sur la même ligne que le titre et son introduction.
    ///
    /// Une image sous l'en-tête coupait la page en deux et repoussait le
    /// contenu ; à côté, elle occupe la respiration que le texte laisse à sa
    /// droite sans rien déplacer.
    var accessory: AnyView?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: scale.titleGap) {
            Text(title)
                .font(.system(size: scale.titleSize, weight: .bold))
                .kerning(scale.kerning)
                .foregroundStyle(.white)
            if let subtitle {
                Text(.init(subtitle))
                    .font(.system(size: 13))
                    .foregroundStyle(Style.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let accessory { accessory }
        }
        .padding(.bottom, scale.bottomMargin)
    }
}

/// Le titre d'une section, au-dessus d'une carte — `.section-label`.
struct SectionLabel: View {
    let text: String
    /// Le premier libellé d'une page vient juste sous l'en-tête, qui pose déjà
    /// sa propre marge basse. Les deux s'additionnent — les conteneurs sont des
    /// piles, pas du flux CSS, donc rien ne fusionne — et la première section
    /// se retrouve plus détachée que les suivantes alors qu'elle l'est moins.
    /// Le prototype corrige le cas à la main (`marginTop: 0` sur l'onglet
    /// Dictée) mais l'oublie sur Général ; ce drapeau rend la correction
    /// nommée, donc applicable partout de la même façon.
    var followsHeader = false

    init(_ text: String, followsHeader: Bool = false) {
        self.text = text
        self.followsHeader = followsHeader
    }

    var body: some View {
        // Les marges du prototype (`margin-top: 16px; margin-bottom: 8px`) sont
        // portées ici plutôt qu'aux sites d'appel : c'est le seul moyen qu'elles
        // soient les mêmes partout, et j'avais déjà commencé à les recopier à la
        // main avec des valeurs qui divergeaient d'un écran à l'autre.
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .kerning(0.84)
            .foregroundStyle(Style.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, followsHeader ? 0 : 16)
            .padding(.bottom, 8)
    }
}

/// Le compteur d'étapes de l'accueil — « 2 / 5 ».
struct StepCounter: View {
    let current: Int
    let total: Int

    var body: some View {
        Text("\(current) / \(total)")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Style.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Style.accentDim)
                    .overlay(Capsule().strokeBorder(Style.accentBorder, lineWidth: 1)))
            .accessibilityLabel("Étape \(current) sur \(total)")
    }
}

/// Le bouton principal : pilule turquoise, texte sombre.
///
/// `.borderedProminent` teinté ne donne pas ça — il garde le rayon système et
/// une graisse de texte plus légère, si bien que l'action principale de
/// l'accueil se lisait comme un bouton secondaire. Le contraste vient du texte
/// **sombre** sur le turquoise : du blanc dessus passe sous le seuil lisible.
struct CasprPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Style.onAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            // Désactivé, le bouton reste **le même bouton**, simplement
            // estompé — `.btn:disabled { opacity: 0.35 }`. Le repeindre en
            // gris posait du texte sombre sur un fond sombre : « + Ajouter »
            // devenait illisible au lieu de se lire comme indisponible.
            .background(Capsule().fill(Style.accent))
            .shadow(color: isEnabled ? Style.accentGlow : .clear,
                    radius: configuration.isPressed ? 4 : 10, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Un bouton qui occupe une ligne entière et se révèle au survol.
///
/// Pour les actions qui déplient une section : le survol dessine la surface
/// réellement cliquable, ce qui répond avant le clic à la question « est-ce que
/// ça se clique, et jusqu'où ». Un libellé nu ne le dit pas, et on finit par
/// viser l'icône en espérant.
struct HoverHighlightButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.10
                                              : (hovering ? 0.06 : 0))))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Bouton secondaire : même pilule, sans le remplissage.
struct CasprSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Style.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.13 : 0.08))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08),
                                                    lineWidth: 1)))
    }
}

/// Une pastille numérotée — « 1 », « 2 », « 3 ».
///
/// Carré arrondi bordé plutôt que disque plein : le disque plein se confond
/// avec les puces d'autorisation accordée (`GrantedLine`), qui disent tout
/// autre chose.
struct NumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Style.accent)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Style.accentDim)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Style.accentBorder, lineWidth: 1)))
    }
}

/// Un bloc de réglages : titre en capitales espacées, contenu sur une carte.
///
/// Remplace `Section` dans un `Form` groupé, dont le rendu système jure avec le
/// reste de l'application.
struct Card<Content: View>: View {
    /// Teintée turquoise, pour la carte qui porte le message essentiel d'un
    /// écran. Une seule par écran : deux accents concurrents et plus rien ne
    /// ressort.
    var highlighted = false
    /// `.card { margin-bottom: 12px }`. Réglable parce que le prototype la
    /// surcharge quand deux blocs doivent se lire comme un seul — la bascule
    /// de l'aperçu en direct et la carte du moteur qu'elle commande, par
    /// exemple, se resserrent à 10 pt une fois l'aperçu activé.
    var bottomMargin: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        // **Pas de titre.** Le paramètre existait, et il produisait des titres
        // en double : la page posait « DÉMARRAGE & SYSTÈME », la carte
        // répondait « DÉMARRAGE » juste en dessous. Le retirer rend la faute
        // impossible plutôt qu'à surveiller — c'est la page parente qui nomme
        // ses sections avec `SectionLabel`, puis appelle le composant qui porte
        // la logique.
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                    .fill(highlighted ? Style.accent.opacity(0.05) : Style.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Style.cardRadius,
                                         style: .continuous)
                            .strokeBorder(highlighted ? Style.accentBorder
                                                      : Style.cardStroke,
                                          lineWidth: 1))
            )
            // `.card { margin-bottom: 12px }`. Portée par la carte plutôt que
            // par l'espacement du conteneur : `SectionLabel` a ses propres
            // marges, et un `spacing` de pile s'y ajouterait au lieu de s'y
            // substituer. Les conteneurs du prototype sont des flex, où les
            // marges verticales ne fusionnent pas — c'est donc bien 12 pt sous
            // chaque carte, quel que soit ce qui suit.
            .padding(.bottom, bottomMargin)
    }
}

/// Note explicative sous un réglage. Le projet en met beaucoup, parce qu'un
/// réglage dont on ignore la conséquence ne sera jamais touché.
struct Note: View {
    let text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        // `.note` : 11,5 px, interligne 1,45. `lineSpacing` compte l'espace
        // **ajouté** entre les lignes, pas la hauteur totale — d'où 3 pt et non
        // 5, l'interligne par défaut valant déjà ~1,2.
        Text(.init(text))
            .font(.system(size: 11.5))
            .lineSpacing(3)
            .foregroundStyle(warning ? Style.warning : Style.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sélecteur en pastilles.
///
/// Les mesures viennent de `PillSelector`, celui de la barre flottante, et
/// doivent le rester : c'est le même contrôle, sur deux surfaces. Il avait
/// dérivé — rayons, hauteurs et graisses différents — et la version des
/// réglages paraissait bâclée à côté de l'autre alors qu'elle prétendait être
/// la même chose.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var disabled = false

    /// Identiques à PillSelector : conteneur de 32, marge de 4, segment de 24.
    private static var height: CGFloat { 32 }
    private static var inset: CGFloat { 4 }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let active = option.value == selection
                // De vrais boutons, comme la barre d'onglets. Un `Text` avec un
                // `onTapGesture` n'existe ni pour le clavier ni pour VoiceOver
                // — et ce composant porte le choix de la langue, celui de la
                // destination et celui de la version du moteur : trois
                // réglages qu'on ne pouvait atteindre qu'à la souris.
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Style.accent : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: Self.height - 2 * Self.inset)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(active ? Style.accent.opacity(0.20) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(Self.inset)
        .frame(height: Self.height)
        .background(
            Capsule().fill(Color.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1)))
        .opacity(disabled ? 0.4 : 1)
    }
}

/// Ligne « libellé à gauche, contrôle à droite ».
struct Row<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // `.card-row` : `gap: 14px`, libellé à 12,5 px / 500.
        HStack(spacing: 14) {
            Text(label).font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// Boutons secondaires alignés, taille et style uniformes.
struct ButtonRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}


/// L'interrupteur du projet, dessiné plutôt qu'emprunté au système.
///
/// `Toggle(.switch)` se désature quand la fenêtre n'est plus au premier plan.
/// Sur le gris clair d'une fenêtre système, un interrupteur actif reste
/// reconnaissable ainsi : la piste est pleine, même terne. Sur le verre sombre
/// de Caspr, cette piste grise se confond avec le fond et **un réglage activé
/// se lit comme désactivé** — au point de faire douter qu'il ait été pris en
/// compte.
///
/// On le dessine donc soi-même : l'état affiché ne dépend plus de la fenêtre
/// qui a le focus, seulement de la valeur.
struct CasprSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Capsule()
            .fill(on ? Style.accent : Color.white.opacity(0.14))
            .overlay(
                Capsule().strokeBorder(
                    on ? Color.clear : Color.white.opacity(0.10), lineWidth: 1))
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    // Le bouton reste blanc dans les deux états : c'est la
                    // piste qui porte l'information, comme sur macOS.
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: on)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
    }
}

/// La case à cocher du prototype : carré arrondi de 16 pt qui se remplit
/// d'accent avec une coche sombre.
struct CheckBox: View {
    let checked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(checked ? Style.accent : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(checked ? Style.accent : Style.textTertiary,
                                  lineWidth: 1.5))
                .frame(width: 16, height: 16)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Style.onAccent)
            }
        }
        .padding(.top, 1)
    }
}

/// Case à cocher pour une option à l'intérieur d'une fonctionnalité.
struct OptionCheck: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckBox(checked: isOn)
            Text(.init(title))
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Style.textPrimary : Style.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

/// Dispose des éléments de largeurs inégales sur plusieurs lignes.
///
/// Des pastilles de langues ou de capacités tiennent en quelques lignes ; les
/// empiler en colonne donnerait une page entière, et une grille à colonnes
/// fixes gâcherait la place sur « FR » pour l'économiser sur « Récupérer la
/// réponse ».
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
