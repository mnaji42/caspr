import Foundation

/// Les éléments de la page ChatGPT que le relais apprend à désigner.
public enum RelaisCible: String, CaseIterable, Codable, Sendable {
    case micro, stop, composeur, envoi, reponse, copier, lecture

    public var libelle: String {
        switch self {
        case .micro:     "le bouton micro"
        case .stop:      "le bouton d'arrêt"
        case .composeur: "la zone de texte"
        case .envoi:     "le bouton d'envoi"
        case .reponse:   "la réponse de ChatGPT"
        case .copier:    "« copier » sous la réponse"
        case .lecture:   "« Lire à haute voix »"
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
/// En les apprenant, la panne devient réparable par l'utilisateur sans
/// attendre une version : « Calibrer automatiquement », et c'est reparti.
///
/// Un sélecteur vide signifie « pas encore appris » : le pont JavaScript
/// retombe alors sur ses heuristiques (cf. `RelaisScripts`).
public struct RelaisSelecteurs: Codable, Equatable {
    public var micro = ""
    public var stop = ""
    public var composeur = ""
    /// Les deux suivants ne servent qu'aux modules qui renvoient le texte à
    /// ChatGPT. Ils sont calibrés à part, la première fois qu'on en a besoin :
    /// imposer cinq clics à qui ne veut que transcrire serait payer d'avance
    /// pour une fonctionnalité qu'on n'utilisera peut-être jamais.
    public var envoi = ""
    public var reponse = ""
    /// Le bouton « copier » sous la réponse.
    ///
    /// C'est le chemin d'extraction à privilégier, et pour deux raisons qui
    /// n'en font qu'une. Il rend le texte **entier** et proprement formaté, là
    /// où lire le DOM dépend du nœud qu'on a désigné — cliquer sur un
    /// paragraphe de la réponse donnait ce seul paragraphe. Et il n'existe
    /// qu'une fois la réponse terminée : sa présence est donc le signal de fin
    /// que l'on devinait jusque-là à coups de chronomètre.
    public var copier = ""
    /// Le bloc qui porte le bouton « copier » de la réponse.
    ///
    /// Capturé au même clic que le bouton. La page contient un bouton
    /// « copier » par message, celui de l'utilisateur compris : le désigner
    /// seul revenait à chercher lequel des deux, et toutes les façons de
    /// deviner — remonter l'arbre, prendre le dernier, exiger la visibilité —
    /// se sont trompées tour à tour. La paire ne devine rien.
    public var copierParent = ""

    /// Le bouton « Lire à haute voix » de ChatGPT, et le bloc qui le porte.
    ///
    /// Retenus ensemble, comme pour « copier » et pour la même raison : la page
    /// pose une barre d'actions sous chaque message, et seul le couple dit de
    /// laquelle il s'agit.
    public var lecture = ""
    public var lectureParent = ""
    /// Le bouton qui ouvre le menu où « Lire à haute voix » se cache.
    ///
    /// Vide quand le bouton est directement visible sous la réponse — ChatGPT
    /// fait les deux selon les cas, et l'on ne demande pas à l'utilisateur de
    /// savoir lequel est le sien.
    public var lectureMenu = ""
    public var lectureMenuParent = ""

    public subscript(cible: RelaisCible) -> String {
        get { self[keyPath: Self.champ(cible)] }
        set { self[keyPath: Self.champ(cible)] = newValue }
    }

    private static func champ(_ cible: RelaisCible) -> WritableKeyPath<Self, String> {
        switch cible {
        case .micro: \.micro
        case .stop: \.stop
        case .composeur: \.composeur
        case .envoi: \.envoi
        case .reponse: \.reponse
        case .copier: \.copier
        case .lecture: \.lecture
        }
    }

    /// Vrai quand l'utilisateur a calibré au moins le micro et l'arrêt — les
    /// deux que les heuristiques ont le plus de mal à deviner.
    public var estCalibre: Bool { !micro.isEmpty && !stop.isEmpty }

    /// Un repère qui décrit une **forme** plutôt qu'une adresse.
    ///
    /// `div:nth-of-type(3) > div:nth-of-type(2) > div > div > div > div` ne
    /// porte ni identifiant, ni `data-testid`, ni libellé : il répond partout
    /// où cette forme se retrouve dans la page, et nulle part si elle bouge
    /// d'un cran. Les calibrations produisaient ça sans le vérifier — cf.
    /// `chaineAncree`, qui ne le fait plus.
    ///
    /// Le critère est volontairement grossier — aucun crochet, aucun dièse —
    /// parce qu'il ne sert qu'à **prévenir**, jamais à bloquer : un faux
    /// positif coûte une recalibration inutile, un faux négatif laisse l'état
    /// d'avant. Rien d'irréversible dans un sens comme dans l'autre.
    static func estFragile(_ repere: String) -> Bool {
        !repere.isEmpty && !repere.contains("[") && !repere.contains("#")
    }

    /// Les cibles dont le repère ne désigne plus une adresse **et** qu'une
    /// calibration peut réapprendre.
    ///
    /// Elles viennent des calibrations faites avant que les chaînes de position
    /// soient ancrées et éprouvées. Rien ne les distingue à l'œil d'un
    /// calibrage valide : la dictée attend simplement sans fin une zone de
    /// saisie qu'elle ne retrouve pas.
    ///
    /// ## Pourquoi le parcours filtre la liste
    ///
    /// L'avertissement dit « recalibrez ». Il ne doit donc nommer que ce qu'une
    /// recalibration répare. `reponse` n'est dans aucun parcours — ni manuel ni
    /// automatique : il n'y a pas de clic qui l'apprenne. Signalé, il faisait
    /// réclamer indéfiniment un geste sans effet, et l'avertissement restait
    /// affiché à qui venait justement de tout recalibrer.
    ///
    /// Le taire n'est pas le cacher : ce repère-là n'est plus consulté que par
    /// les pages qui ne nomment pas leurs tours, `derniereReponse` préférant
    /// ce que ChatGPT écrit lui-même. Un reste périmé y est sans effet.
    public var fragiles: [RelaisCible] {
        let apprenables = Set(RelaisEtape.parcoursManuel.map(\.cible))
        return RelaisCible.allCases
            .filter { apprenables.contains($0) && Self.estFragile(self[$0]) }
    }

    /// Sait-on faire lire la réponse à haute voix ?
    public var saitLire: Bool { !lecture.isEmpty }

    // MARK: - Décodage tolérant aux champs qui n'existaient pas encore
    //
    // Le décodage synthétisé par Swift échoue sur une clé absente : il
    // n'utilise **pas** les valeurs par défaut des propriétés. Ajouter `envoi`
    // et `reponse` a donc rendu illisibles les calibrages déjà enregistrés, et
    // tous les utilisateurs ont perdu le leur en installant la mise à jour —
    // avec, en cascade, la voie ChatGPT qui refusait de démarrer et un écran de
    // réglages annonçant « configuration inachevée » à qui venait de la
    // terminer.
    //
    // `decodeIfPresent` rend chaque champ facultatif. Tout champ ajouté plus
    // tard doit suivre la même règle, sans exception : la sanction n'est pas
    // une erreur visible mais un réglage effacé.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        micro = try c.decodeIfPresent(String.self, forKey: .micro) ?? ""
        stop = try c.decodeIfPresent(String.self, forKey: .stop) ?? ""
        composeur = try c.decodeIfPresent(String.self, forKey: .composeur) ?? ""
        envoi = try c.decodeIfPresent(String.self, forKey: .envoi) ?? ""
        reponse = try c.decodeIfPresent(String.self, forKey: .reponse) ?? ""
        copier = try c.decodeIfPresent(String.self, forKey: .copier) ?? ""
        copierParent = try c.decodeIfPresent(String.self, forKey: .copierParent) ?? ""
        lecture = try c.decodeIfPresent(String.self, forKey: .lecture) ?? ""
        lectureParent = try c.decodeIfPresent(String.self, forKey: .lectureParent) ?? ""
        lectureMenu = try c.decodeIfPresent(String.self, forKey: .lectureMenu) ?? ""
        lectureMenuParent = try c.decodeIfPresent(String.self, forKey: .lectureMenuParent) ?? ""
    }

    public init() {}
}
