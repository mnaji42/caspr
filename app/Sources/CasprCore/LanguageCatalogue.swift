import Foundation

/// Le fichier `languages.json`, tel qu'il se lit.
///
/// Dans CasprCore, et non à côté de `Language`, pour une seule raison : un
/// champ que le décodeur exige et que le fichier n'a pas ne produit aucune
/// erreur visible. `Language` retombe alors sur un catalogue de secours à
/// deux langues, et l'on ne s'en aperçoit qu'en ouvrant le sélecteur. Ici, un
/// test décode le vrai fichier à chaque `swift test`.
///
/// Rien d'autre que les colonnes : ce qui dépend de la machine — les locales
/// d'Apple Intelligence et de la Dictée — se demande au système à
/// l'exécution, et n'a rien à faire dans un fichier figé.
public struct LanguageCatalogue: Decodable, Sendable {
    public struct Row: Decodable, Sendable, Equatable {
        /// Locale complète — `fr-FR`.
        public let code: String
        /// Nom dans sa propre langue — « Français », « 日本語 ».
        public let name: String
        public let region: String
        public let flag: String
        /// Le nom en français, qui sert à chercher.
        public let frenchName: String
        /// Ordre de grandeur du modèle Apple Intelligence, jamais un chiffre
        /// exact : Apple ne l'expose pas.
        public let estimatedModelMegabytes: Int64
        /// L'ordre d'affichage.
        public let rank: Int
    }

    /// Les langues, **dans l'ordre d'affichage**.
    public let languages: [Row]

    private enum CodingKeys: String, CodingKey { case languages }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        languages = try container.decode([Row].self, forKey: .languages)
            .sorted { $0.rank < $1.rank }
    }

    public static func decode(_ data: Data) throws -> LanguageCatalogue {
        try JSONDecoder().decode(LanguageCatalogue.self, from: data)
    }
}
