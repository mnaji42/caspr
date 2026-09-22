import AppKit

/// Le glyphe de la barre de menus : le fantôme de Caspr, et son état.
///
/// Il utilisait `mic`, `mic.fill` et `mic.badge.plus` — c'est-à-dire très
/// exactement les symboles de la dictée d'Apple. Deux problèmes. Dans une
/// barre de menus, l'utilisateur ne distinguait pas Caspr d'un élément du
/// système ; et une application qui réclame le micro *et* le droit de piloter
/// le clavier a tout intérêt à s'annoncer comme elle-même.
///
/// Le motif est donc celui de la marque, le même que l'icône de
/// l'application : on reconnaît Caspr dans la barre avant de lire son état.
///
/// Des SVG chargés depuis `Resources/icons`, et non un tracé Core Graphics : ce
/// sont les dessins de la marque, ils vivent au même endroit que ceux du Dock
/// et de l'accueil, et les faire évoluer ne demande pas de recompiler. Les
/// variantes `menu-` sont les mêmes dessins retaillés pour 18 points et percés
/// là où il faut — cf. `image(_:)`, qui explique pourquoi.
enum MenuBarIcon {
    /// 18 pt de haut, la hauteur utile de la barre de menus.
    private static let size = NSSize(width: 18, height: 18)

    /// Ce que l'icône dit, et rien d'autre.
    ///
    /// La grammaire vient des dessins : **le fantôme ne change jamais**, une
    /// bulle apparaît en bas à droite, et c'est son contenu qui porte l'état —
    /// cinq barres pour l'écoute, trois points pour le traitement, deux lignes
    /// de texte pour une discussion ChatGPT qui attend la suite. L'œil
    /// reconnaît l'application d'abord, son état ensuite.
    /// La forme dit *quoi*, la couleur dit *si c'est grave* — cyan pour ce qui
    /// est normal ou souhaitable, rouge pour ce qui demande une intervention.
    enum State {
        case idle, listening, processing, error, update, discussion

        var fileName: String {
            switch self {
            case .idle: "menu-caspr-ghost"
            case .listening: "menu-caspr-ghost-listening"
            case .processing: "menu-caspr-ghost-processing"
            case .error: "menu-caspr-ghost-error"
            case .update: "menu-caspr-ghost-update"
            case .discussion: "menu-caspr-ghost-discussion"
            }
        }
    }

    static func image(_ state: State) -> NSImage? {
        guard let url = Bundle.main.url(forResource: state.fileName,
                                        withExtension: "svg",
                                        subdirectory: "icons"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.size = size
        // Les variantes `menu-` : un seul tracé, yeux, bouche et intérieur de
        // bulle en **trous**. macOS ne regarde que l'alpha d'un gabarit, si
        // bien qu'une forme opaque sombre y devient de la même couleur que le
        // reste : les dessins d'origine s'aplatissaient en une silhouette
        // muette, où les cinq états se ressemblaient tous.
        //
        // **Gabarit**, y compris pour les états colorés : la barre de menus est
        // claire en thème clair, et un fantôme blanc y serait invisible. macOS
        // reteint alors le dessin dans la couleur du texte, ce qui garde la
        // silhouette lisible partout — c'est elle qui identifie l'application,
        // et la forme de la bulle suffit à distinguer les trois états sans la
        // couleur. Le cyan reste dans les fenêtres, où le fond est maîtrisé.
        image.isTemplate = true
        return image
    }
}
