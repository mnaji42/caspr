import Foundation

/// Ce qu'on demande à la page en plus de l'essentiel (cf. `RelaisInstantane`).
///
/// Sur demande seulement : le texte de la zone et la réponse se lisent à
/// chaque tour d'une attente, quatre fois par seconde, et les alertes un tour
/// sur quatre — chacun a un coût dans une page qu'on attend de voir avancer.
public struct RelaisDemande: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Le texte de la zone de saisie.
    public static let texte = RelaisDemande(rawValue: 1)
    /// Où en est la réponse de ChatGPT depuis la marque.
    public static let reponse = RelaisDemande(rawValue: 2)
    /// Le premier échec apparu depuis la marque.
    public static let alertes = RelaisDemande(rawValue: 4)
}

/// Ce que la page montrait avant qu'on lui demande quelque chose (`marquer`
/// du pont) : ses échecs affichés, et combien de réponses de ChatGPT.
///
/// Gardée par Caspr et repassée à chaque relevé, et non par le pont, qui
/// renaît vierge à chaque document : un « Recharger » pendant l'attente
/// l'effaçait, et la réponse d'avant passait pour la nouvelle. Décodée
/// strictement, à l'inverse du relevé : une marque incomplète compterait
/// pour nouveau ce qui ne l'est pas ; mieux vaut n'en avoir aucune.
public struct RelaisMarque: Codable, Equatable, Sendable {
    public var reponses: Int
    public var echecs: [String]

    public init(reponses: Int, echecs: [String]) {
        self.reponses = reponses
        self.echecs = echecs
    }
}

/// Ce que la page dit d'elle-même en un seul aller-retour (`instantane` du
/// pont), relevé par rapport à la marque (`marquer`).
///
/// Chaque champ se décode s'il est présent, sinon prend sa valeur par
/// défaut — la règle de `RelaisSelecteurs`, pour la même raison : un pont
/// d'une autre version qui omet un champ ne doit pas rendre le relevé
/// entier illisible, ce qui se lirait comme un silence de la page.
public struct RelaisInstantane: Equatable, Sendable {
    /// L'adresse est celle d'une conversation (`/c/…`, `/g/<projet>/c/…`).
    public var conversation = false
    /// L'écran d'authentification, ou une invite de connexion.
    public var authentification = false
    /// La zone de saisie, visible.
    public var composeur = false
    public var micro = false
    public var stop = false
    /// La zone absente et l'arrêt présent : la page écoute.
    public var enregistrement = false
    /// Le texte de la zone ; `nil` quand elle est introuvable, ou pas demandé.
    public var texte: String?
    /// `nil` quand elle n'a pas été demandée, ou sans marque.
    public var reponse: Reponse?
    /// Le premier échec apparu depuis la marque ; `nil` aussi quand les
    /// alertes n'ont pas été demandées, ou sans marque.
    public var echec: Echec?

    public struct Reponse: Equatable, Sendable {
        /// Les réponses de ChatGPT apparues depuis la marque.
        public var nouvelles = 0
        /// ChatGPT écrit encore — jamais l'arrêt de la dictée.
        public var enCours = false
        /// La longueur de la dernière réponse nouvelle.
        public var longueur = 0
        /// Le bouton « copier » du tour suit la réponse nouvelle.
        public var copierPret = false
    }

    public struct Echec: Equatable, Sendable {
        public var texte = ""
        /// Un motif d'échec connu, et non une alerte quelconque.
        public var reconnue = false
    }
}

extension RelaisInstantane: Decodable {
    private enum CodingKeys: String, CodingKey {
        case conversation, authentification, composeur, micro, stop, enregistrement
        case texte, reponse, echec
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.lire(.conversation, false)
        authentification = try c.lire(.authentification, false)
        composeur = try c.lire(.composeur, false)
        micro = try c.lire(.micro, false)
        stop = try c.lire(.stop, false)
        enregistrement = try c.lire(.enregistrement, false)
        texte = try c.decodeIfPresent(String.self, forKey: .texte)
        reponse = try c.decodeIfPresent(Reponse.self, forKey: .reponse)
        echec = try c.decodeIfPresent(Echec.self, forKey: .echec)
    }
}

extension RelaisInstantane.Reponse: Decodable {
    private enum CodingKeys: String, CodingKey { case nouvelles, enCours, longueur, copierPret }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nouvelles = try c.lire(.nouvelles, 0)
        enCours = try c.lire(.enCours, false)
        longueur = try c.lire(.longueur, 0)
        copierPret = try c.lire(.copierPret, false)
    }
}

extension RelaisInstantane.Echec: Decodable {
    private enum CodingKeys: String, CodingKey { case texte, reconnue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        texte = try c.lire(.texte, "")
        reconnue = try c.lire(.reconnue, false)
    }
}

private extension KeyedDecodingContainer {
    func lire<T: Decodable>(_ cle: Key, _ defaut: T) throws -> T {
        try decodeIfPresent(T.self, forKey: cle) ?? defaut
    }
}
