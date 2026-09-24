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

    @Test("Un échec prouvé replie de l'écoute à la réponse, et seulement un échec prouvé")
    func echec() {
        let prouves: [RelaisErreur] = [.refusParChatGPT("Limite atteinte"), .pasConnecte,
                                       .pageInterrompue, .pontAbsent]
        // La page a peut-être encore le texte : elle s'ouvre pour qu'on l'y
        // prenne.
        let autres: [RelaisErreur] = [.introuvable(.stop), .ecouteNonOuverte, .pasDeReponse,
                                      .envoiSansEffet]
        let repliees: Set<RelaisPhase> = [.ecoute, .transcription, .envoi, .reponse]
        for phase in RelaisPhase.allCases {
            for erreur in prouves {
                #expect(RelaisCycle.replie(apres: erreur, en: phase) == repliees.contains(phase),
                        "\(erreur) en \(phase)")
            }
            for erreur in autres {
                #expect(!RelaisCycle.replie(apres: erreur, en: phase), "\(erreur) en \(phase)")
            }
        }
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
        #expect(RelaisPhase.transcription.sortie == "touche de dictée pour abandonner, × pour tout annuler")
        #expect(RelaisPhase.lecture.sortie == "touche de dictée pour ne plus attendre")
    }
}
