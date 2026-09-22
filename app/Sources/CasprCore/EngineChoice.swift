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
/// Ce ne sont pas deux choix de même rang : c'est le même fournisseur, la même
/// promesse et le même réglage, à une génération près. D'où `versionLabel`,
/// qui nomme la version à l'intérieur de « macOS ».
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

    /// Cette version distingue-t-elle texte nettoyé et mot à mot ?
    ///
    /// Non, ni l'une ni l'autre : elles n'ont pas de prompt. Le mode survit
    /// encore dans les réglages, et s'en va avec eux ; d'ici là, la question
    /// garde sa réponse écrite ici plutôt qu'un `false` recopié chez chaque
    /// appelant.
    public var hasModes: Bool {
        switch self {
        case .apple, .appleLegacy: false
        }
    }

    /// Ce que change le choix de version, sous le sélecteur.
    ///
    /// Court exprès : il n'apparaît que sous la carte de macOS, qui dit déjà
    /// ce que le moteur est.
    public var versionExplanation: String {
        switch self {
        case .apple:
            "Le moteur apparu avec macOS 26. Plus fin sur les passages longs, "
                + "et son modèle se télécharge par langue — il demande Apple "
                + "Intelligence."
        case .appleLegacy:
            "Le moteur de la Dictée de macOS, présent sur toute machine où la "
                + "dictée du système fonctionne, Mac Intel compris. Rien à "
                + "télécharger : il se sert des modèles que la Dictée a déjà "
                + "installés, et il couvre plus de langues que l'autre."
        }
    }
}
