import Testing
@testable import CasprCore

/// Le parcours manuel, en données : l'ordre est celui où les boutons
/// existent, et seule la dernière étape peut manquer sans défaire le reste.
@Suite("Parcours manuel de la calibration")
struct RelaisEtapeTests {
    private let etapes = RelaisEtape.parcoursManuel

    /// L'arrêt n'existe que pendant l'écoute, l'envoi qu'une fois la zone
    /// remplie, « copier » et la lecture qu'une fois la réponse venue.
    @Test("Les étapes suivent l'ordre où les boutons existent")
    func ordre() {
        #expect(etapes.map(\.cible)
                == [.micro, .stop, .composeur, .envoi, .reponse, .copier, .lecture])
    }

    /// La réponse se montre juste avant « copier », parce que c'est d'elle que
    /// dépend son acceptation : le bouton n'est retenu que s'il est celui de la
    /// **dernière** réponse, cherchée par ce repère-là.
    @Test("La réponse précède « copier », dont elle conditionne l'acceptation")
    func laReponsePrecedeCopier() throws {
        let cibles = etapes.map(\.cible)
        let reponse = try #require(cibles.firstIndex(of: .reponse))
        let copier = try #require(cibles.firstIndex(of: .copier))
        #expect(reponse < copier)
    }

    /// La main apprend **un repère de plus** que l'automatique : celui de la
    /// réponse.
    ///
    /// L'invariant était l'égalité, et il a tenu tant que `REPONSES` —
    /// `[data-message-author-role="assistant"]`, le seul pari écrit en dur du
    /// module — répondait. Le 4 octobre 2026 ChatGPT ne l'écrit plus : la page
    /// n'offre « aucune réponse », l'automatique ne peut plus rien éprouver, et
    /// la main n'avait aucun moyen de réparer puisque l'étape n'existait pas.
    /// Elle existe maintenant, et l'automatique ne sait toujours pas la faire —
    /// un clic ne se devine pas. L'écart est donc voulu, et il est d'exactement
    /// une cible.
    @Test("La main apprend la réponse en plus de ce qu'éprouve l'automatique")
    func unRepereDePlusQueLAutomatique() {
        let obligatoires = etapes.filter { !$0.facultative }.map(\.cible)
        #expect(Set(obligatoires) == Set(RelaisPreuves.parcours).union([.reponse]))
        #expect(obligatoires.count == RelaisPreuves.parcours.count + 1)
    }

    /// Renoncer à « Lire à haute voix » garde les cinq repères appris avant
    /// lui : il doit donc venir en dernier.
    @Test("Seule la lecture est facultative, et elle vient en dernier")
    func lectureFacultative() {
        #expect(etapes.filter(\.facultative).map(\.cible) == [.lecture])
        #expect(etapes.last?.facultative == true)
    }

    /// Le bouton d'envoi n'existe qu'une fois la zone remplie : c'est la
    /// seule étape qui prépare la page, et elle a une consigne de repli.
    @Test("Seul l'envoi écrit d'abord le message d'essai")
    func preparation() {
        #expect(etapes.filter { $0.preparation != nil }.map(\.cible) == [.envoi])
        guard case .messageDEssai(let sinon) = etapes[3].preparation else {
            Issue.record("l'envoi ne prépare pas la page")
            return
        }
        #expect(!sinon.isEmpty && sinon != etapes[3].consigne)
    }
}
