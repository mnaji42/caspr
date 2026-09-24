import Testing
@testable import CasprCore

/// La table des gestes d'une dictée ChatGPT.
///
/// La sanction d'une erreur ici : une touche qui jette une réponse obtenue,
/// une croix qui insère quand même, ou un abandon qui rouvre la conversation
/// sous la réponse de ChatGPT.
@Suite("Machine d'une dictée ChatGPT")
struct RelaisCycleTests {

    @Test("La table entière des deux gestes")
    func table() {
        let attendu: [RelaisPhase: (touche: RelaisCycle.Decision, croix: RelaisCycle.Decision)] = [
            .demarrage: (.annulerLeDemarrage, .annulerLeDemarrage),
            .ecoute: (.arreter, .annuler),
            .transcription: (.replier, .annuler),
            .envoi: (.replier, .annuler),
            .reponse: (.replier, .annuler),
            .lecture: (.cesserDAttendre, .annuler),
            .livraison: (.annuler, .annuler),
        ]
        #expect(attendu.count == RelaisPhase.allCases.count)
        for phase in RelaisPhase.allCases {
            #expect(RelaisCycle.decider(.touche, en: phase) == attendu[phase]?.touche, "\(phase)")
            #expect(RelaisCycle.decider(.croix, en: phase) == attendu[phase]?.croix, "\(phase)")
        }
    }

    @Test("Après un échec prouvé : échouer au démarrage, replier ensuite, continuer en lecture")
    func echec() {
        #expect(RelaisCycle.apresEchec(en: .demarrage) == .echouer)
        for phase in [RelaisPhase.ecoute, .transcription, .envoi, .reponse] {
            #expect(RelaisCycle.apresEchec(en: phase) == .replier)
        }
        #expect(RelaisCycle.apresEchec(en: .lecture) == .continuer)
    }

    @Test("Chaque attente dit ce qu'on attend, et comment en sortir")
    func libelles() {
        #expect(RelaisPhase.demarrage.libelle == "ChatGPT se prépare…")
        #expect(RelaisPhase.transcription.libelle == "ChatGPT transcrit…")
        #expect(RelaisPhase.envoi.libelle == "Envoi à ChatGPT…")
        #expect(RelaisPhase.reponse.libelle == "ChatGPT répond…")
        #expect(RelaisPhase.lecture.libelle == "Lecture à haute voix…")
        for phase in RelaisPhase.allCases {
            // Toute phase affichée a sa sortie : aucune n'a de fin (30).
            #expect((phase.libelle == nil) == (phase.sortie == nil), "\(phase)")
        }
        #expect(RelaisPhase.transcription.sortie == "touche de dictée pour abandonner")
        #expect(RelaisPhase.lecture.sortie == "touche de dictée pour ne plus attendre")
    }
}
