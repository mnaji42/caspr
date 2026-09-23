import Foundation
import CasprCore

extension RelaisPage {
    enum Erreur: LocalizedError {
        case introuvable(RelaisCible)
        case pasConnecte
        case pasDeReponse
        case consigneNonPosee
        case refusParChatGPT(String)
        /// WebKit a fermé la page pendant la dictée ; elle a été rechargée.
        case pageInterrompue
        /// Personne n'a cliqué pendant qu'un guetteur de calibration attendait.
        case calibrationSansClic(RelaisCible)
        /// La voie est macOS : la page n'existe pas, et rien hors d'une dictée
        /// ChatGPT déjà commencée ne la reconstruit (cf. `Relais.pageActive`).
        case relaisEteint

        /// Ce que la barre affiche, quand la raison générique mentirait.
        ///
        /// « Réessayer dans le menu » ne veut rien dire pour le relais, qui ne
        /// garde pas d'audio. Pour ces cas-là, la raison elle-même est ce
        /// qu'on a besoin de lire — surtout le texte d'un refus, qui dit
        /// d'emblée si c'est un quota et non une panne.
        var raisonCourte: String? {
            switch self {
            case .refusParChatGPT(let message):
                let court = message.count > 90 ? String(message.prefix(89)) + "…" : message
                return "ChatGPT : \(court)"
            // Montrée pendant une attente, la page d'authentification est un
            // échec prouvé : ChatGPT ne rendra rien à une session fermée.
            case .pasConnecte: return "ChatGPT : session déconnectée"
            case .pageInterrompue: return "La page ChatGPT s'est fermée — dictée perdue"
            case .relaisEteint: return "ChatGPT n'est plus la voie de dictée"
            default: return nil
            }
        }

        /// La transcription peut-elle être encore dans la page ?
        ///
        /// Non quand la page est morte : celle qu'on ouvrirait pour l'y
        /// chercher est une page neuve et vide, et promettre le contraire
        /// envoyait fouiller une fenêtre où rien ne subsistait.
        var laissePeutEtreLeTexte: Bool {
            switch self {
            case .pageInterrompue, .relaisEteint: false
            default: true
            }
        }

        var errorDescription: String? {
            switch self {
            case .introuvable(let c):
                "Impossible de trouver \(c.libelle) dans la page. Calibrer à nouveau ?"
            case .pasConnecte:
                "Pas connecté à ChatGPT. Ouvrez la fenêtre du relais et connectez-vous."
            case .pasDeReponse:
                "ChatGPT n'a pas répondu. La transcription brute est dans l'historique."
            case .consigneNonPosee:
                "La consigne de reformulation n'a pas pu être ajoutée au texte."
            case .refusParChatGPT(let message):
                "ChatGPT a affiché une erreur : « \(message) »"
            case .pageInterrompue:
                "WebKit a fermé la page ChatGPT pendant la dictée. Elle a été rechargée, "
                + "mais ce qui avait été dit est perdu."
            // Seul repère facultatif, et le dernier des deux parcours : ce qui
            // a été appris avant lui est gardé.
            case .calibrationSansClic(.lecture):
                "Aucun clic sur « Lire à haute voix » en trois minutes : ce repère, "
                + "facultatif, n'a pas été appris. Le reste est gardé."
            case .calibrationSansClic(let c):
                "Aucun clic sur \(c.libelle) en trois minutes : la calibration est "
                + "abandonnée. Relancez-la quand vous serez prêt."
            case .relaisEteint:
                "La dictée passe désormais par macOS : la page ChatGPT est "
                + "fermée."
            }
        }
    }
}
