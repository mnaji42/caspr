import Foundation

/// Les trois éléments de la page ChatGPT dont le relais a besoin.
enum RelaisCible: String, CaseIterable, Codable {
    case micro, stop, composeur, envoi, reponse

    var libelle: String {
        switch self {
        case .micro:     "le bouton micro"
        case .stop:      "le bouton d'arrêt (le carré, pas la flèche bleue)"
        case .composeur: "la zone de texte"
        case .envoi:     "le bouton d'envoi (la flèche bleue)"
        case .reponse:   "la réponse de ChatGPT"
        }
    }
}

/// Sélecteurs CSS appris en regardant l'utilisateur cliquer.
///
/// Rien n'est écrit en dur, et c'est le point de conception principal de cette
/// application. Le DOM de ChatGPT n'expose aucun identifiant contractuel : les
/// classes sont générées, la structure bouge à chaque déploiement. Un sélecteur
/// codé en dur marcherait jusqu'au mardi où il ne marcherait plus, sans
/// message, et il faudrait recompiler pour réparer.
///
/// En les apprenant, la panne devient réparable par l'utilisateur en dix
/// secondes : « Calibrer » dans le menu, trois clics, c'est reparti.
///
/// Un sélecteur vide signifie « pas encore appris » : le pont JavaScript
/// retombe alors sur ses heuristiques (cf. `pont.js` dans `RelaisPage`).
struct RelaisSelecteurs: Codable, Equatable {
    var micro = ""
    var stop = ""
    var composeur = ""
    /// Les deux suivants ne servent qu'aux modes qui renvoient le texte à
    /// ChatGPT. Ils sont calibrés à part, la première fois qu'on en a besoin :
    /// imposer cinq clics à qui ne veut que transcrire serait payer d'avance
    /// pour une fonctionnalité qu'on n'utilisera peut-être jamais.
    var envoi = ""
    var reponse = ""

    subscript(cible: RelaisCible) -> String {
        get {
            switch cible {
            case .micro: micro
            case .stop: stop
            case .composeur: composeur
            case .envoi: envoi
            case .reponse: reponse
            }
        }
        set {
            switch cible {
            case .micro: micro = newValue
            case .stop: stop = newValue
            case .composeur: composeur = newValue
            case .envoi: envoi = newValue
            case .reponse: reponse = newValue
            }
        }
    }

    /// Vrai quand l'utilisateur a calibré au moins le micro et l'arrêt — les
    /// deux que les heuristiques ont le plus de mal à deviner.
    var estCalibre: Bool { !micro.isEmpty && !stop.isEmpty }

    /// Vrai quand l'aller-retour avec ChatGPT est possible.
    var saitDialoguer: Bool { estCalibre && !envoi.isEmpty && !reponse.isEmpty }

    // MARK: - Persistance

    private static let cle = "relais.selecteurs"

    static func charger() -> RelaisSelecteurs {
        guard let data = UserDefaults.standard.data(forKey: cle),
              let s = try? JSONDecoder().decode(RelaisSelecteurs.self, from: data)
        else { return RelaisSelecteurs() }
        return s
    }

    func enregistrer() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.cle)
    }
}
