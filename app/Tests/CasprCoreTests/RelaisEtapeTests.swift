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
        #expect(etapes.map(\.cible) == [.micro, .stop, .composeur, .envoi, .copier, .lecture])
    }

    /// Les deux parcours apprennent les mêmes repères : ce que la main montre
    /// en plus de l'automatique, c'est « Lire à haute voix », et rien d'autre.
    @Test("Les étapes obligatoires sont celles de l'automatique")
    func memesReperesQueLAutomatique() {
        let obligatoires = etapes.filter { !$0.facultative }.map(\.cible)
        #expect(Set(obligatoires) == Set(RelaisPreuves.parcours))
        #expect(obligatoires.count == RelaisPreuves.parcours.count)
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
