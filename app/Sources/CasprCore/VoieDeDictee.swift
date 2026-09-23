//  Qui écoute le micro : la seule décision de Caspr, écrite une seule fois.
//
//  Elle l'était trois fois — la version de macOS retenue, l'interrupteur du
//  relais, et un drapeau du contrôleur de dictée qui existait parce que
//  l'interrupteur pouvait changer en pleine phrase. Rien n'obligeait les deux
//  premiers à rester d'accord. Et l'exclusion réelle, **mesurée** — crête
//  0,072 avant tout usage du relais, 0,000 après — n'était portée par aucun
//  type : un `guard` et une quinzaine de `if` la tenaient.
//
//  Un enum à deux cas en fait la forme du type. Chaque endroit qui se pose la
//  question le fait par un `switch` sans `default`, et le compilateur les
//  retrouve tous le jour où la réponse change.

import Foundation

/// Par où passe une dictée.
public enum VoieDeDictee: String, Codable, CaseIterable, Sendable {
    /// macOS : hors ligne, sans compte. Caspr ouvre son micro, et la version de
    /// la reconnaissance — Apple Intelligence ou la Dictée — se choisit toute
    /// seule selon ce que la machine sait faire dans la langue.
    case apple
    /// ChatGPT : la page que Caspr héberge écoute et transcrit. Caspr n'ouvre
    /// **jamais** son propre micro sur cette voie — deux captures ne
    /// cohabitent pas, et c'est la sienne qui n'entend plus que du silence.
    case chatgpt

    /// La clé sous laquelle la voie est rangée.
    public static let cle = "caspr.voie"

    /// L'interrupteur du relais, qui tenait la décision jusqu'ici.
    ///
    /// Plus rien ne l'écrit ni ne le lit, sauf `migrer`. Il reste sur le
    /// disque : une version antérieure relancée après celle-ci y retrouve le
    /// dernier état qu'elle connaissait, et les clés `relais.*` ne s'effacent
    /// jamais.
    public static let cleHeritee = "relais.actif"

    /// Pose la voie d'une installation qui n'en a pas encore, d'après
    /// l'interrupteur du relais.
    ///
    /// Une voie déjà rangée n'est jamais réécrite : c'est un choix, et
    /// l'interrupteur, figé depuis, ne sait plus rien de plus récent. Sans
    /// interrupteur non plus, la voie est macOS — ce que faisait Caspr pour qui
    /// n'avait jamais allumé le relais.
    ///
    /// - Returns: la voie posée, ou `nil` s'il n'y avait rien à faire.
    @discardableResult
    public static func migrer(_ defaults: UserDefaults) -> VoieDeDictee? {
        guard defaults.object(forKey: cle) == nil else { return nil }
        let voie: VoieDeDictee = defaults.bool(forKey: cleHeritee) ? .chatgpt : .apple
        defaults.set(voie.rawValue, forKey: cle)
        return voie
    }

    /// La voie rangée, ou macOS quand il n'y en a pas — ou qu'elle ne se
    /// relit pas.
    public static func relue(_ defaults: UserDefaults) -> VoieDeDictee {
        defaults.string(forKey: cle).flatMap(VoieDeDictee.init(rawValue:)) ?? .apple
    }
}
