import Foundation

/// Où en est une dictée ChatGPT, de l'appui à la livraison.
///
/// Une seule valeur, écrite à un seul endroit (`VoieChatGPT.entrer`), au lieu
/// des drapeaux qui la disaient par morceaux — « message parti », « réponse
/// obtenue », « lecture interrompue », une attente à part pour la barre — et
/// qu'il fallait tenir d'accord à chaque correctif. Les gestes se décident sur
/// elle (cf. `RelaisCycle.decider`), la barre la montre.
public enum RelaisPhase: String, CaseIterable, Sendable {
    /// L'appui est reçu ; la page se prépare, ou se met à écouter.
    case demarrage
    case ecoute
    /// L'arrêt est cliqué ; ChatGPT rend la transcription.
    case transcription
    case envoi
    case reponse
    /// Il ne reste qu'à attendre la lecture à haute voix : le message de
    /// « Discuter » est parti, ou la réponse d'un module qui écrit est en main.
    case lecture
    /// Le retour à l'application où l'on parlait, puis l'écriture.
    case livraison

    /// Ce que la barre affiche pendant la phase ; `nil` quand elle montre
    /// autre chose — l'écoute, ou rien pendant la livraison.
    public var libelle: String? {
        switch self {
        case .demarrage: "ChatGPT se prépare…"
        case .transcription: "ChatGPT transcrit…"
        case .envoi: "Envoi à ChatGPT…"
        case .reponse: "ChatGPT répond…"
        case .lecture: "Lecture à haute voix…"
        case .ecoute, .livraison: nil
        }
    }

    /// Comment en sortir, dit dans la barre avec le chrono : aucune de ces
    /// attentes n'a de fin (cf. RELAIS.md, sixième règle), et une barre qui ne
    /// dit pas sa sortie se lit comme un gel.
    public var sortie: String? {
        switch self {
        case .demarrage, .transcription, .envoi, .reponse:
            "touche de dictée pour abandonner, × pour tout annuler"
        // Rien n'est plus à abandonner : la touche ne fait que cesser
        // d'attendre la voix.
        case .lecture: "touche de dictée pour ne plus attendre"
        case .ecoute, .livraison: nil
        }
    }
}

/// Ce que valent les deux gestes de l'utilisateur à chaque phase, et ce que
/// devient la dictée quand la page prouve un échec.
///
/// Une table, pure et testée, au lieu de conditions réparties entre le
/// contrôleur et le relais. Aucune ligne ne vient de l'horloge : le temps
/// passé ne met fin à rien (cf. RELAIS.md, sixième règle).
public enum RelaisCycle {
    public enum Geste: String, Sendable {
        /// La touche de dictée : un geste délibéré, propre à Caspr.
        case touche
        /// La croix de la barre — et Échap pendant l'écoute, seul moment où il
        /// est tenu hors d'une discussion affichée : mesuré, un Échap global
        /// pendant l'attente a annulé deux réorganisations qu'on ne voulait
        /// pas annuler.
        case croix
    }

    public enum Decision: String, Sendable {
        /// Rien n'a encore été dit : défaire l'appui.
        case annulerLeDemarrage
        /// Cesser d'écouter, et laisser ChatGPT transcrire.
        case arreter
        /// Renoncer à ChatGPT, en livrant le meilleur texte déjà en main.
        case replier
        /// Tout arrêter sans rien insérer ; ce qui est en main va au menu.
        case annuler
        /// Ne plus attendre la voix : le texte s'insère, ou la discussion
        /// s'ouvre.
        case cesserDAttendre
    }

    public static func decider(_ geste: Geste, en phase: RelaisPhase) -> Decision {
        switch (phase, geste) {
        case (.demarrage, _): .annulerLeDemarrage
        case (.ecoute, .touche): .arreter
        case (.transcription, .touche), (.envoi, .touche), (.reponse, .touche): .replier
        case (.lecture, .touche): .cesserDAttendre
        // Pendant la livraison, l'application visée revient devant : la
        // touche ne peut plus que tout défaire — rien n'est activé ni écrit.
        case (_, .croix), (.livraison, .touche): .annuler
        }
    }

    /// Ce que devient la dictée quand la page prouve un échec : vrai quand
    /// ChatGPT ne rendra plus rien de ce qui a été dit, et qu'on livre à sa
    /// place ce qu'on a (cf. `RelaisRepli`).
    ///
    /// Un refus, une session fermée, une page morte, ou sans pont — chargée
    /// sans le script de Caspr, que rien n'y installera : elle ne rendra pas
    /// davantage le texte qu'une page morte. Pas les autres erreurs : un arrêt
    /// introuvable laisse une page qui a peut-être encore le texte — elle
    /// s'ouvre pour qu'on l'y prenne, et le son reste au menu.
    ///
    /// Au démarrage, rien n'a encore été dit : la dictée échoue. Pendant
    /// l'envoi ou la réponse, le brut est lu, et c'est lui qui s'insère —
    /// par la seconde passe, qui le rend quand elle échoue. En lecture, la
    /// réponse est en main, seule la voix manque : la dictée continue, avec
    /// un avertissement. En livraison, la page n'y est plus pour rien : un
    /// échec d'insertion a son propre chemin (cf. `Livraison.EchecDInsertion`).
    public static func replie(apres erreur: RelaisErreur, en phase: RelaisPhase) -> Bool {
        switch phase {
        case .ecoute, .transcription, .envoi, .reponse:
            switch erreur {
            case .refusParChatGPT, .pasConnecte, .pageInterrompue, .pontAbsent: true
            default: false
            }
        case .demarrage, .lecture, .livraison: false
        }
    }
}
