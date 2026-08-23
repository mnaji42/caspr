import Foundation

/// Ce que Caspr a appris à faire de la page ChatGPT.
///
/// Une capacité n'est jamais choisie : elle est **acquise**, par calibration ou
/// par autorisation système. Ce que l'on choisit, ce sont des actions et une
/// sortie — et chacune déclare les capacités dont elle a besoin. La liste des
/// capacités manquantes d'un module s'en déduit, au lieu d'être écrite à la
/// main quelque part.
///
/// C'est la distinction qui manquait à la première version : les capacités y
/// étaient calculées depuis des drapeaux du module, si bien qu'ajouter une
/// action obligeait à retoucher le calcul. Ici, une action nouvelle déclare ce
/// qu'elle exige et tout le reste suit.
enum RelaisCapacite: String, CaseIterable, Codable {
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
    /// Joindre une capture de l'écran au message.
    case capturerEcran

    var libelle: String {
        switch self {
        case .dicter: "Dicter"
        case .envoyer: "Envoyer"
        case .recuperer: "Récupérer la réponse"
        case .direAHauteVoix: "Faire lire à haute voix"
        case .capturerEcran: "Joindre l'écran"
        }
    }

    /// Comment on l'obtient, dit à qui ne l'a pas encore.
    var commentAcquerir: String {
        switch self {
        case .dicter:
            "Montrer le micro, l'arrêt et la zone de texte."
        case .envoyer:
            "Montrer le bouton d'envoi."
        case .recuperer:
            "Montrer le bouton « copier » sous une réponse."
        case .direAHauteVoix:
            "Montrer le bouton « Lire à haute voix » sous une réponse."
        case .capturerEcran:
            "Autoriser l'enregistrement de l'écran dans les Réglages Système."
        }
    }

    /// Le socle est exigé de tous et ne se propose pas.
    var estSocle: Bool { self == .dicter }

    func estAcquise(_ s: RelaisSelecteurs) -> Bool {
        switch self {
        case .dicter: s.estCalibre
        case .envoyer: !s.envoi.isEmpty
        case .recuperer: s.saitCopier
        // Les deux dernières ne sont pas encore construites. Rendre `false`
        // n'est pas un oubli : c'est ce qui empêche un module qui les
        // réclamerait d'apparaître sur la barre avant qu'elles existent.
        case .direAHauteVoix: s.saitLire
        case .capturerEcran: false
        }
    }
}

/// Une étape que le module peut demander, entre l'écoute et la sortie.
///
/// L'ordre du chemin ne lui appartient pas : il est fixé par l'ordre de
/// déclaration ci-dessous, et un module ne fait que dire quelles étapes le
/// concernent. Le laisser réordonner permettrait d'écrire « récupérer la
/// réponse » avant « envoyer » — une configuration qu'il faudrait valider au
/// lieu de la rendre impossible.
/// Une action est **grossière**, et emploie souvent plusieurs capacités.
///
/// « Demander une réponse » ne se réduit pas à cliquer le bouton d'envoi : elle
/// lit la transcription, l'encadre si le module le prévoit, envoie, puis
/// attend. Découper cela en autant d'actions donnerait une liste que personne
/// ne voudrait cocher, et dont la plupart des combinaisons n'auraient aucun
/// sens. On en veut peu, et qu'elles disent quelque chose.
enum RelaisAction: String, CaseIterable, Codable {
    /// Joindre une capture de l'écran, avant d'envoyer.
    case joindreEcran
    /// Encadrer la transcription, l'envoyer, et attendre la réponse.
    ///
    /// L'encadrement en fait partie plutôt que d'être une action à lui seul :
    /// un texte ajouté sans être envoyé ne servirait à rien. Vouloir ou non en
    /// ajouter est un réglage de cette action — les deux champs vides
    /// signifient « envoie la transcription telle quelle », ce dont
    /// « Discuter » a précisément besoin.
    case demanderUneReponse
    /// Faire lire la réponse à haute voix.
    case direLaReponse

    var libelle: String {
        switch self {
        case .joindreEcran: "Joindre l'écran"
        case .demanderUneReponse: "Envoyer à ChatGPT"
        case .direLaReponse: "Faire lire la réponse"
        }
    }

    var capacitesRequises: [RelaisCapacite] {
        switch self {
        case .joindreEcran: [.capturerEcran]
        case .demanderUneReponse: [.envoyer]
        case .direLaReponse: [.direAHauteVoix]
        }
    }
}

extension RelaisSortie {
    /// La sortie exige elle aussi des capacités — ce ne sont pas les seules
    /// actions qui en emploient.
    ///
    /// Écrire quelque part suppose d'avoir rapatrié la réponse ; n'écrire nulle
    /// part n'exige rien de plus que le socle.
    var capacitesRequises: [RelaisCapacite] {
        demandeLaReponse ? [.recuperer] : []
    }
}
