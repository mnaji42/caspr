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
/// entier illisible, ce qui se lirait comme un silence de la page. Tenue
/// par le type (`ParDefaut`), et non par un décodeur écrit à la main pour
/// chaque structure : un champ ajouté s'y déclare en une ligne.
public struct RelaisInstantane: Equatable, Sendable, Decodable {
    /// L'adresse est celle d'une conversation (`/c/…`, `/g/<projet>/c/…`).
    @ParDefaut public var conversation = false
    /// L'écran d'authentification, ou une invite de connexion.
    @ParDefaut public var authentification = false
    /// La zone de saisie, visible.
    @ParDefaut public var composeur = false
    @ParDefaut public var micro = false
    @ParDefaut public var stop = false
    /// La zone absente et l'arrêt présent : la page écoute.
    @ParDefaut public var enregistrement = false
    /// Le texte de la zone ; `nil` quand elle est introuvable, ou pas demandé.
    public var texte: String?
    /// `nil` quand elle n'a pas été demandée, ou sans marque.
    public var reponse: Reponse?
    /// Le premier échec apparu depuis la marque ; `nil` aussi quand les
    /// alertes n'ont pas été demandées, ou sans marque.
    public var echec: Echec?

    public struct Reponse: Equatable, Sendable, Decodable {
        /// Les réponses de ChatGPT apparues depuis la marque.
        @ParDefaut public var nouvelles = 0
        /// ChatGPT écrit encore — jamais l'arrêt de la dictée.
        @ParDefaut public var enCours = false
        /// La longueur de la dernière réponse nouvelle.
        @ParDefaut public var longueur = 0
        /// Le bouton « copier » du tour suit la réponse nouvelle.
        @ParDefaut public var copierPret = false
    }

    public struct Echec: Equatable, Sendable, Decodable {
        @ParDefaut public var texte = ""
        /// Un motif d'échec connu, et non une alerte quelconque.
        @ParDefaut public var reconnue = false
    }
}

/// Un champ qui, absent ou nul, se décode à sa valeur par défaut — `false`,
/// `0`, `""` — au lieu de faire échouer toute la structure.
///
/// Le décodage synthétisé de Swift lève sur une clé absente : il ignore les
/// valeurs par défaut des propriétés. Ce type le corrige pour la clé qui
/// le porte, par `decodeIfPresent`, et laisse Swift écrire le reste.
@propertyWrapper
public struct ParDefaut<Valeur: Decodable & Equatable & Sendable & ValeurParDefaut>: Decodable, Equatable, Sendable {
    public var wrappedValue: Valeur
    public init(wrappedValue: Valeur) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws { wrappedValue = try decoder.singleValueContainer().decode(Valeur.self) }
}

public protocol ValeurParDefaut { static var parDefaut: Self { get } }
extension Bool: ValeurParDefaut { public static var parDefaut: Bool { false } }
extension Int: ValeurParDefaut { public static var parDefaut: Int { 0 } }
extension String: ValeurParDefaut { public static var parDefaut: String { "" } }

// Choisie par le décodage synthétisé, plus précise que `decode<T>` : c'est
// elle qui rend un champ `ParDefaut` facultatif. Publique, pour qu'un type
// de l'application qui en porte un ne retombe pas, sans rien dire, sur la
// version qui lève.
extension KeyedDecodingContainer {
    public func decode<V>(_ type: ParDefaut<V>.Type, forKey cle: Key) throws -> ParDefaut<V> {
        try decodeIfPresent(type, forKey: cle) ?? ParDefaut(wrappedValue: .parDefaut)
    }
}
