import Foundation

/// Ce que Caspr a appris à faire de la page ChatGPT.
///
/// Une capacité n'est jamais choisie : elle est **acquise**, en montrant à
/// Caspr un élément de la page. Ce que l'on choisit, c'est un module, et ce
/// qu'il exige se déduit de ce qu'il fait (cf. `RelaisModule.capacitesRequises`).
public enum RelaisCapacite: String, CaseIterable, Codable {
    /// Ouvrir le micro, l'arrêter, lire et écrire la zone de saisie.
    ///
    /// **Le socle.** Tout module s'en sert, aucun ne peut s'en passer : c'est
    /// la dictée elle-même. Elle n'apparaît donc pas comme un choix, et rien
    /// ne permet de la décocher — l'afficher parmi les options laisserait
    /// croire qu'on peut dicter sans micro.
    case dicter
    /// Envoyer le message dans la conversation.
    case envoyer
    /// Rapatrier la réponse par le bouton « copier » de ChatGPT.
    case recuperer
    /// Faire lire la réponse à haute voix.
    case direAHauteVoix

    public var libelle: String {
        switch self {
        case .dicter: "Dicter"
        case .envoyer: "Envoyer"
        case .recuperer: "Récupérer la réponse"
        case .direAHauteVoix: "Faire lire à haute voix"
        }
    }

    /// Comment on l'obtient, dit à qui ne l'a pas encore.
    public var commentAcquerir: String {
        switch self {
        case .dicter:
            "Montrer le micro, l'arrêt et la zone de texte."
        case .envoyer:
            "Montrer le bouton d'envoi."
        case .recuperer:
            "Montrer le bouton « copier » sous une réponse."
        case .direAHauteVoix:
            "Montrer le bouton « Lire à haute voix » sous une réponse."
        }
    }

    public func estAcquise(_ s: RelaisSelecteurs) -> Bool {
        switch self {
        case .dicter: s.estCalibre
        case .envoyer: !s.envoi.isEmpty
        // Le repère de la réponse compte aussi : la page sait encore lire par
        // lui (cf. `RelaisDictee.recuperer`), et exiger le bouton copier
        // retirait ses modules à qui avait calibré avant lui.
        case .recuperer: !s.copier.isEmpty || !s.reponse.isEmpty
        case .direAHauteVoix: s.saitLire
        }
    }
}
