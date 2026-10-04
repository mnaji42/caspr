import Foundation

/// Une étape du parcours manuel de la calibration : le repère qu'on fait
/// montrer, et ce qu'on dit pour cela.
///
/// En données, parcourues par une seule boucle : les six étapes étaient six
/// blocs recopiés, chacun avec sa sortie, et un oubli y suffisait — le
/// parcours manuel ne gardait pas « copier » sous la dernière réponse comme
/// l'automatique, et rien dans sa forme ne le laissait voir.
public struct RelaisEtape: Equatable, Sendable {
    /// Ce qu'il faut faire à la page avant de demander le clic.
    public enum Preparation: Equatable, Sendable {
        /// Le bouton d'envoi n'existe qu'une fois la zone remplie : le
        /// message d'essai y est écrit, et vérifié. `sinon` : la consigne
        /// quand il n'a pas pu l'être.
        case messageDEssai(sinon: String)
    }

    /// Nommée dans le titre de l'étape par son `libelle`, le même que dans le
    /// rapport de l'automatique et les erreurs.
    public let cible: RelaisCible
    public let consigne: String
    public var preparation: Preparation?
    /// Renoncer à cette étape, ou la manquer, garde ce qui a été appris
    /// avant elle, et le parcours se termine comme s'il avait abouti.
    public var facultative = false

    /// Dans l'ordre où les boutons existent : l'arrêt n'existe que pendant
    /// l'écoute, l'envoi qu'une fois la zone remplie, la réponse, « copier » et
    /// « Lire à haute voix » qu'une fois ChatGPT revenu. L'automatique en
    /// éprouve cinq (cf. `RelaisPreuves.parcours`) ; la dernière, facultative,
    /// ne sert qu'aux modules qui font parler.
    ///
    /// ## Pourquoi la réponse y figure désormais
    ///
    /// Elle n'y était pas, et c'était le seul repère que rien ne permettait de
    /// réapprendre. Or « copier » n'est accepté que s'il est celui de la
    /// dernière réponse, cherchée par ce repère-là : un calibrage périmé le
    /// faisait refuser indéfiniment, et recalibrer n'y changeait rien puisque
    /// l'étape n'existait pas.
    ///
    /// Le module repose par ailleurs sur un seul pari écrit en dur,
    /// `[data-message-author-role="assistant"]`, alors que tout le reste est
    /// appris — c'est le principe de conception de `RelaisSelecteurs`. Mesuré
    /// le 4 octobre 2026 : ChatGPT ne l'écrit plus, la page n'offrait donc
    /// « aucune réponse » et la calibration ne pouvait plus aboutir. Cette
    /// étape rend le pari réparable sans attendre une version.
    public static let parcoursManuel: [RelaisEtape] = [
        RelaisEtape(cible: .micro, consigne: """
            Cliquez le bouton micro dans la page. L'enregistrement va démarrer, \
            c'est normal : il faut qu'il tourne pour que le bouton d'arrêt existe.
            """),
        RelaisEtape(cible: .stop, consigne: "Cliquez maintenant le bouton d'arrêt — le carré, pas la flèche bleue d'envoi."),
        RelaisEtape(cible: .composeur, consigne: "Cliquez la zone de texte, celle où le texte transcrit vient d'apparaître."),
        RelaisEtape(cible: .envoi, consigne: """
            Un message d'essai vient d'être écrit dans la page. Cliquez le bouton \
            d'envoi — la flèche bleue, à droite de la zone de texte.

            Il partira réellement dans votre conversation : c'est nécessaire pour \
            qu'une réponse existe et qu'on puisse désigner ses boutons ensuite.
            """, preparation: .messageDEssai(sinon: """
            Le message d'essai n'a pas pu être écrit tout seul.

            Tapez n'importe quoi dans la zone de texte — un « bonjour » suffit — puis \
            cliquez le bouton d'envoi, la flèche bleue à droite. Il n'apparaît qu'une \
            fois la zone remplie, et le message doit partir pour qu'une réponse \
            existe.
            """)),
        RelaisEtape(cible: .reponse, consigne: """
            Attendez que ChatGPT ait fini de répondre, puis cliquez **dans le \
            texte de sa réponse** — n'importe où dedans.

            Caspr apprend ainsi à reconnaître ses réponses, pour ne jamais les \
            confondre avec vos propres messages.
            """),
        RelaisEtape(cible: .copier, consigne: """
            Cliquez maintenant l'icône \
            « copier » sous **sa** réponse — deux carrés superposés.

            Sous la réponse, pas sous votre propre message : la page en porte une par \
            message, et Caspr retient au passage le bloc qui l'entoure pour ne jamais \
            confondre les deux.
            """),
        RelaisEtape(cible: .lecture, consigne: """
            Cliquez « Lire à haute voix » sous la même réponse — le petit \
            haut-parleur.

            S'il n'apparaît pas directement, ouvrez d'abord le menu « … » : Caspr \
            retient le chemin complet et le refera pour vous. Deux clics, donc, si \
            votre interface les demande.

            Cette capacité sert aux modules qui doivent parler — une traduction \
            qu'on fait entendre à quelqu'un, par exemple. Elle est facultative : \
            abandonnez maintenant si elle ne vous sert pas, le reste est déjà appris.
            """, facultative: true),
    ]
}
