import Foundation

/// Ce qu'on montre de la page ChatGPT pendant qu'elle travaille.
///
/// Trois niveaux, parce que trois usages. Rien, pour qui veut juste dicter et
/// à qui la mécanique est indifférente. La barre, pour voir que ça écoute et
/// que ça transcrit. La page entière, pour comprendre ce qui se passe quand
/// quelque chose cloche — c'est le seul mode qui rende un défaut
/// diagnosticable sans lire un journal.
///
/// Quelle que soit la taille, la fenêtre ne prend **jamais** le clavier
/// pendant une dictée : c'est la fenêtre de la barre qu'on agrandit, pas celle
/// des réglages. Une fenêtre capable de devenir clé ferait écrire la dictée
/// dans la page au lieu de l'éditeur.
public enum RelaisAffichage: String, CaseIterable, Codable {
    case rien, barre, page

    /// Un mot par pastille : le composant tient sur une ligne de réglages, à
    /// côté de son libellé, et trois phrases n'y entreraient pas.
    public var libelleCourt: String {
        switch self {
        case .rien: "Rien"
        case .barre: "Barre"
        case .page: "Page"
        }
    }
}
