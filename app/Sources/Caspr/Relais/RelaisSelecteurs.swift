import Foundation

/// Les trois éléments de la page ChatGPT dont le relais a besoin.
enum RelaisCible: String, CaseIterable, Codable {
    case micro, stop, composeur, envoi, reponse, copier

    var libelle: String {
        switch self {
        case .micro:     "le bouton micro"
        case .stop:      "le bouton d'arrêt (le carré, pas la flèche bleue)"
        case .composeur: "la zone de texte"
        case .envoi:     "le bouton d'envoi (la flèche bleue)"
        case .reponse:   "la réponse de ChatGPT"
        case .copier:    "le bouton copier sous la réponse"
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
    /// Le bouton « copier » sous la réponse.
    ///
    /// C'est le chemin d'extraction à privilégier, et pour deux raisons qui
    /// n'en font qu'une. Il rend le texte **entier** et proprement formaté, là
    /// où lire le DOM dépend du nœud qu'on a désigné — cliquer sur un
    /// paragraphe de la réponse donnait ce seul paragraphe. Et il n'existe
    /// qu'une fois la réponse terminée : sa présence est donc le signal de fin
    /// que l'on devinait jusque-là à coups de chronomètre.
    var copier = ""
    /// Le bloc qui porte le bouton « copier » de la réponse.
    ///
    /// Capturé au même clic que le bouton. La page contient un bouton
    /// « copier » par message, celui de l'utilisateur compris : le désigner
    /// seul revenait à chercher lequel des deux, et toutes les façons de
    /// deviner — remonter l'arbre, prendre le dernier, exiger la visibilité —
    /// se sont trompées tour à tour. La paire ne devine rien.
    var copierParent = ""

    subscript(cible: RelaisCible) -> String {
        get {
            switch cible {
            case .micro: micro
            case .stop: stop
            case .composeur: composeur
            case .envoi: envoi
            case .reponse: reponse
            case .copier: copier
            }
        }
        set {
            switch cible {
            case .micro: micro = newValue
            case .stop: stop = newValue
            case .composeur: composeur = newValue
            case .envoi: envoi = newValue
            case .reponse: reponse = newValue
            case .copier: copier = newValue
            }
        }
    }

    /// Vrai quand l'utilisateur a calibré au moins le micro et l'arrêt — les
    /// deux que les heuristiques ont le plus de mal à deviner.
    var estCalibre: Bool { !micro.isEmpty && !stop.isEmpty }

    /// Vrai quand l'aller-retour avec ChatGPT est possible.
    /// L'un ou l'autre suffit : le bouton « copier » est le chemin d'aujourd'hui,
    /// le repère de la réponse celui des configurations d'avant. Exiger le
    /// premier ferait disparaître le mode chez qui l'a calibré hier.
    var saitDialoguer: Bool {
        estCalibre && !envoi.isEmpty && (!copier.isEmpty || !reponse.isEmpty)
    }

    /// Sait-on récupérer la réponse par le bouton de ChatGPT ?
    var saitCopier: Bool { !copier.isEmpty }

    // MARK: - Décodage tolérant aux champs qui n'existaient pas encore
    //
    // Le décodage synthétisé par Swift échoue sur une clé absente : il
    // n'utilise **pas** les valeurs par défaut des propriétés. Ajouter `envoi`
    // et `reponse` a donc rendu illisibles les calibrages déjà enregistrés, et
    // tous les utilisateurs ont perdu le leur en installant la mise à jour —
    // avec, en cascade, le mode relais qui refuse de démarrer et un écran de
    // réglages annonçant « configuration inachevée » à qui venait de la
    // terminer.
    //
    // `decodeIfPresent` rend chaque champ facultatif. Tout champ ajouté plus
    // tard doit suivre la même règle, sans exception : la sanction n'est pas
    // une erreur visible mais un réglage effacé.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        micro = try c.decodeIfPresent(String.self, forKey: .micro) ?? ""
        stop = try c.decodeIfPresent(String.self, forKey: .stop) ?? ""
        composeur = try c.decodeIfPresent(String.self, forKey: .composeur) ?? ""
        envoi = try c.decodeIfPresent(String.self, forKey: .envoi) ?? ""
        reponse = try c.decodeIfPresent(String.self, forKey: .reponse) ?? ""
        copier = try c.decodeIfPresent(String.self, forKey: .copier) ?? ""
        copierParent = try c.decodeIfPresent(String.self, forKey: .copierParent) ?? ""
    }

    init() {}

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
