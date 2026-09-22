import Foundation
import Speech
import CasprCore

/// Ce que `EngineChoice` ne peut pas savoir tout seul.
///
/// La disponibilité n'est pas une propriété du moteur, c'est une propriété de
/// *cette machine à cet instant* : un modèle téléchargé ou non, une version de
/// macOS, la Dictée allumée. Elle interroge `Speech` et `LegacySpeechEngine`,
/// donc elle ne peut pas vivre dans CasprCore — et elle n'a pas à y vivre,
/// puisqu'elle n'est pas testable sans la machine.
extension EngineChoice {
    /// Ce moteur est-il utilisable ici, **maintenant** ?
    ///
    /// Mesuré, jamais déduit d'un numéro de version. Une machine virtuelle en
    /// macOS 26 dicte parfaitement avec `SFSpeechRecognizer` et n'a aucun
    /// modèle pour `SpeechTranscriber` : conclure de « macOS 26 » que le
    /// second fonctionne serait faux, et l'a été.
    func isAvailable(for language: String) -> Bool {
        switch self {
        case .apple:
            guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
                return false
            }
            // `SpeechTranscriber.isAvailable` ne dit que « ce moteur existe sur
            // cette machine » — il ne regarde pas la langue. Le rendre tel quel
            // faisait passer le polonais pour pris en charge, donc pas de repli
            // vers la Dictée et une proposition de téléchargement pour un
            // modèle qui n'existe pas. Tant que le système n'a pas répondu pour
            // cette langue, on ne la déclare pas indisponible : la réponse
            // arrive en quelques millisecondes et les vues se redessinent.
            return Language.appleSupports(language) != false
        case .appleLegacy:
            return LegacySpeechEngine.isAvailable(for: language)
        }
    }

    /// Les versions de macOS que cette machine sait faire tourner, ici et
    /// maintenant, dans cette langue.
    ///
    /// C'est la liste qui décide s'il y a un sélecteur à afficher : deux
    /// entrées, un sélecteur ; une seule, la version passe dans le titre et
    /// rien ne suggère un choix impossible ; aucune, la ligne reste mais
    /// n'est plus sélectionnable.
    static func availableSystemEngines(for language: String) -> [EngineChoice] {
        systemEngines.filter { $0.isAvailable(for: language) }
    }

    /// La version de macOS à retenir quand on choisit « macOS ».
    ///
    /// Celle déjà réglée si elle fonctionne — changer de langue ou rouvrir les
    /// réglages ne doit pas déplacer un choix explicite — sinon la plus fine
    /// disponible. `nil` quand aucune ne marche ici.
    static func systemEngine(preferring current: EngineChoice,
                             for language: String) -> EngineChoice? {
        if current.isAvailable(for: language) { return current }
        return availableSystemEngines(for: language).first
    }
}
