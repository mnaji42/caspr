//  Les versions du moteur de macOS, et ce qu'elles savent faire.
//
//  Ce fichier est dans CasprCore, pas dans l'application : ce qu'une version
//  sait faire est une **règle pure**, du même genre que la comparaison de
//  versions ou le découpage d'un titre de fenêtre. Elle n'interroge ni le
//  micro ni le disque — elle se déduit du cas, et rien d'autre. Ce qui
//  interroge la machine — « cette version est-elle utilisable ici,
//  maintenant ? » — reste dans l'application, dans
//  `EngineChoice+Availability.swift`.

import Foundation

/// Les deux versions du moteur de macOS.
///
/// Volontairement une énumération fermée plutôt qu'une liste dynamique : une
/// version ne s'ajoute pas à l'exécution, elle demande une implémentation. Ce
/// qui varie à l'exécution, c'est sa *disponibilité* — modèle téléchargé ou
/// non, version de macOS, Dictée allumée.
///
/// Ce ne sont pas deux choix de même rang, ni même un choix : c'est le même
/// fournisseur et la même promesse, à une génération près, et Caspr prend
/// tout seul celle qui sait écrire la langue (cf. `automatic`). D'où
/// `versionLabel`, qui nomme la version à l'intérieur de « macOS ».
public enum EngineChoice: String, CaseIterable, Sendable, Codable {
    /// Le moteur de macOS 26 : `SpeechTranscriber`, taillé pour la
    /// transcription longue. Exige Apple Intelligence.
    case apple
    /// L'autre moteur de macOS : `SFSpeechRecognizer`, celui de la Dictée du
    /// système, disponible depuis macOS 10.15 et sur toute machine dont la
    /// dictée fonctionne — Mac Intel compris.
    case appleLegacy = "apple-legacy"

    /// La version, telle que les Réglages Système la nomment.
    ///
    /// Les deux noms sont ceux des Réglages Système, et c'est délibéré : quand
    /// une version manque, c'est là qu'il faut aller. « Apple Intelligence »
    /// est exactement ce qui conditionne les modèles de `SpeechTranscriber` ;
    /// « Dictée » est le panneau qui installe ceux de `SFSpeechRecognizer`.
    /// Un nom qui dit « récent » ou « classique » aurait laissé chercher.
    public var versionLabel: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .appleLegacy: "Dictée"
        }
    }

    /// « macOS · Dictée ».
    public var fullLabel: String { "macOS · \(versionLabel)" }

    /// Les versions, dans l'ordre de finesse attendue : c'est l'ordre dans
    /// lequel on les préfère quand les deux marchent.
    public static var systemEngines: [EngineChoice] { [.apple, .appleLegacy] }

    /// La version qui écrit, choisie sur ce que la machine a **montré**.
    ///
    /// Plus un réglage : ils étaient deux — la passe finale et l'aperçu — et
    /// ne désignaient deux choses que parce que la passe finale pouvait être
    /// CrisperWhisper. Il reste une règle.
    ///
    /// - Apple Intelligence dès qu'elle est **prête** : le système a répondu
    ///   qu'il propose la langue, **et** son modèle est sur le disque. Une
    ///   langue proposée ne suffit pas — sans le modèle, la transcription
    ///   commence par le télécharger, pendant « Transcription… », des minutes
    ///   durant, et échoue hors ligne. Sur une machine virtuelle en macOS 26,
    ///   elle se disait même disponible sans aucun modèle et rendait une
    ///   chaîne vide, pendant que la Dictée marchait.
    /// - Sinon la Dictée, si elle est prête : elle écrit tout de suite, sur
    ///   l'appareil, pendant que le modèle manque.
    /// - Sinon aucune ne l'est, et l'on prend celle qui a encore une chance :
    ///   Apple Intelligence si le système ne l'a pas refusée pour cette
    ///   langue — il reste à aller chercher son modèle —, la Dictée
    ///   autrement, qui dira pourquoi elle ne peut pas écrire plutôt qu'un
    ///   moteur absent.
    ///
    /// La Dictée n'est donc jamais proposée comme choix : elle écrit là où
    /// Apple Intelligence ne sait pas, et seulement là. Mesurée sur 129
    /// dictées, elle avale environ 44 % des mots.
    ///
    /// Les deux dernières questions ne se posent que si la première ne suffit
    /// pas : chacune crée des reconnaisseurs et relit les préférences du
    /// système, et Apple Intelligence est prête presque toujours.
    public static func automatic(appleReady: Bool, legacyReady: @autoclosure () -> Bool,
                                 appleNotRefused: @autoclosure () -> Bool) -> EngineChoice {
        if appleReady { return .apple }
        if legacyReady() { return .appleLegacy }
        return appleNotRefused() ? .apple : .appleLegacy
    }
}
