import Foundation

/// Ce qui manque à un composant de configuration pour être opérationnel.
///
/// Un type d'erreur, et non un simple booléen : l'accueil doit pouvoir dire
/// *pourquoi* « Continuer » est grisé. Un bouton inactif sans explication est la
/// façon la plus sûre de faire abandonner quelqu'un à l'étape 3.
enum ComponentValidationError: Equatable, LocalizedError {
    case noLanguageSelected
    /// Les locales dont le modèle Apple Intelligence n'est pas installé.
    case missingLanguageModels([String])
    case microphonePermissionRequired
    case accessibilityPermissionRequired
    case speechRecognitionPermissionRequired
    /// La Dictée de macOS est éteinte dans les Réglages Système. Ce n'est pas
    /// une autorisation — cf. `SystemDictation` — mais ça empêche autant.
    case systemDictationDisabled
    /// Aucune version du moteur de macOS ne fonctionne ici, avec la raison
    /// mesurée — pas déduite d'un numéro de version.
    case noSystemEngine(String)
    case notesFileMissing

    var errorDescription: String? {
        switch self {
        case .noLanguageSelected:
            "Choisissez au moins une langue de dictée."
        case .missingLanguageModels(let codes):
            {
                let names = codes.map { Language.named($0).displayName }
                return names.count == 1
                    ? "Le modèle de \(names[0]) n'est pas encore installé."
                    : "Modèles non installés : \(names.joined(separator: ", "))."
            }()
        case .microphonePermissionRequired:
            "Caspr a besoin du micro pour entendre votre voix."
        case .accessibilityPermissionRequired:
            "L'accessibilité est nécessaire pour écrire le texte à votre curseur."
        case .speechRecognitionPermissionRequired:
            "Le moteur de la Dictée de macOS demande la reconnaissance vocale."
        case .systemDictationDisabled:
            "La Dictée de macOS est désactivée : activez-la dans Réglages "
                + "Système › Clavier › Dictée."
        case .noSystemEngine(let reason):
            reason
        case .notesFileMissing:
            "Choisissez le fichier dans lequel écrire."
        }
    }
}

/// Comment un composant rend sa validité — et pourquoi pas par un `@Binding`.
///
/// Les documents de conception décrivaient `@Binding var isValid: Bool` et
/// `@Binding var validationError: ComponentValidationError?` en **sortie**, le
/// composant écrivant dedans depuis son propre corps. C'est la transposition
/// littérale d'un `useEffect` React, et SwiftUI ne s'en accommode pas : écrire
/// dans un binding pendant l'évaluation d'une vue déclenche « Modifying state
/// during view update, this will cause undefined behavior », et au mieux un
/// tour de rendu supplémentaire à chaque frappe.
///
/// Le problème de fond est que la validité n'est pas un état : c'est une
/// **conclusion** tirée d'états qui vivent déjà ailleurs — `PermissionsMonitor`,
/// `SpeechAssets`, `Preferences`. La stocker une seconde fois
/// crée exactement l'occasion de divergence que ce projet a déjà payée en
/// recopiant des réglages dans `DictationController`.
///
/// D'où cette convention : chaque composant expose une **fonction pure**
/// `validate()` que le parent appelle aussi. Les deux lisent les mêmes sources
/// observables, donc ils ne peuvent pas être en désaccord, et il n'y a rien à
/// synchroniser.
protocol ValidatingComponent {
    /// Ce qui manque, ou `nil` si tout est en place.
    ///
    /// Doit rester **sans effet de bord** : elle est appelée à chaque rendu,
    /// par le composant et par son parent.
    @MainActor static func validate() -> ComponentValidationError?
}

extension ValidatingComponent {
    @MainActor static var isValid: Bool { validate() == nil }
}
