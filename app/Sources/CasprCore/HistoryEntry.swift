import Foundation

/// Une transcription gardée dans l'historique, telle qu'elle s'écrit dans les
/// préférences (`caspr.history`).
///
/// Ici plutôt qu'à côté de l'historique, pour la même raison que `Version` :
/// son format est une règle qui se casse sans bruit. Un décodage qui échoue
/// ne plante pas, il rend un historique vide — et la dictée suivante écrase
/// alors tout ce qui était stocké.
public struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let date: Date
    /// Ce que ChatGPT avait transcrit, quand un module l'a repris et que le
    /// texte inséré en diffère.
    ///
    /// La reprise est une seconde passe, et une seconde passe peut se tromper
    /// — résumer ce qu'il fallait garder, suivre de travers une consigne dite
    /// trop vite. Ce qu'on a dit mot pour mot ne devait pas disparaître parce
    /// qu'elle a abouti.
    ///
    /// Facultatif : une clé absente se lit `nil`, et une version qui ne
    /// connaît pas le champ l'ignore.
    public let brut: String?
    /// Le style de transcription, du temps où la dictée en avait deux
    /// (`intended`, `verbatim`). Plus rien ne le lit.
    ///
    /// Il reste écrit parce que les 0.14.x le déclarent **obligatoire** : une
    /// seule entrée qui en serait privée fait échouer le décodage du tableau
    /// entier, l'historique s'affiche vide, et la première dictée l'écrase.
    /// Quiconque revient à une 0.14 depuis une sauvegarde perdrait tout.
    /// La valeur lue est gardée telle quelle ; une entrée nouvelle porte
    /// `intended`, le défaut d'alors.
    let mode: String

    static let modeParDefaut = "intended"

    public init(text: String, brut: String? = nil) {
        self.init(id: UUID(), text: text, date: Date(), brut: brut, mode: Self.modeParDefaut)
    }

    init(id: UUID, text: String, date: Date, brut: String?, mode: String) {
        self.id = id
        self.text = text
        self.date = date
        self.brut = brut
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, date, brut, mode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        brut = try c.decodeIfPresent(String.self, forKey: .brut)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? Self.modeParDefaut
    }

    /// « à l'instant », « il y a 3 min » — repère plus utile qu'une heure
    /// absolue pour retrouver ce qu'on vient de dicter.
    public var relativeAge: String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<10: return "à l'instant"
        case ..<60: return "il y a \(seconds) s"
        case ..<3600: return "il y a \(seconds / 60) min"
        default: return "il y a \(seconds / 3600) h"
        }
    }

    public var preview: String { Self.apercu(de: text) }

    /// Une ligne de menu : le texte aplati, coupé à soixante caractères.
    public static func apercu(de texte: String) -> String {
        let flat = texte.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 60 ? flat : String(flat.prefix(58)) + "…"
    }
}
