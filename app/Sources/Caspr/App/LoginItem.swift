import Foundation
import ServiceManagement

/// Le démarrage de Caspr à l'ouverture de session.
///
/// Une app de barre de menus dont toute la promesse est « tapez cette touche
/// n'importe quand » ne peut pas dépendre du fait qu'on ait pensé à la lancer.
/// Quand elle ne tourne pas, la touche ne fait rien — et rien n'indique que
/// c'est parce que l'application est fermée plutôt que cassée. C'est la
/// conclusion à laquelle on arrive en premier, et elle est fausse.
///
/// L'état n'est **pas** stocké dans les préférences, et c'est délibéré.
/// macOS expose ce réglage dans Réglages Système › Général › Ouverture, où
/// l'utilisateur peut le désactiver sans passer par nous. Une copie locale
/// deviendrait alors fausse, et l'interrupteur des Réglages afficherait
/// l'inverse de la réalité. `SMAppService` est la seule source de vérité.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Vrai si macOS attend une validation de l'utilisateur — il a désactivé
    /// l'entrée à la main, et une réinscription ne suffira pas à la rallumer.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// - Returns: l'état effectivement obtenu, qui peut différer de celui
    ///   demandé. L'appelant doit s'y fier plutôt qu'à son intention : une
    ///   inscription refusée laisserait sinon un interrupteur allumé sur une
    ///   application qui ne démarrera pas.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // Inscrire une entrée déjà inscrite lève une erreur, alors que
                // l'intention est satisfaite : on ne la traite pas comme un
                // échec.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("caspr: ouverture de session — %@", error.localizedDescription)
        }
        return isEnabled
    }
}
