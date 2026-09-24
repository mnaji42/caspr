import Testing
@testable import CasprCore

/// Le repli d'une dictée ChatGPT à laquelle on renonce, ou que la page fait
/// échouer.
///
/// La sanction d'une erreur ici : une minute de parole perdue parce que
/// ChatGPT transcrivait encore, un texte de macOS inséré à la place d'une
/// transcription de ChatGPT déjà lue, ou un module qui n'écrit nulle part qui
/// écrit quand même.
@Suite("Repli d'une dictée ChatGPT")
struct RelaisRepliTests {

    @Test("Toutes les combinaisons : brut lu ou non, son ou non, module qui écrit ou non")
    func combinaisons() {
        let cas: [(brut: String?, secondes: Double, ecrit: Bool, attendu: RelaisRepli)] = [
            // Le brut lu l'emporte sur le son (94).
            ("bonjour", 60, true, .inserer("bonjour")),
            ("bonjour", 0, true, .inserer("bonjour")),
            // Pas de brut : macOS transcrit le son de la page (93).
            (nil, 60, true, .transcrireParMacOS),
            // Un brut vide n'est pas un texte : la dictée a déjà fini sur
            // « Rien n'a été entendu ».
            ("", 60, true, .transcrireParMacOS),
            // Ni brut ni son : le chemin d'avant (20, 100).
            (nil, 0, true, .rien),
            ("", 0.1, true, .rien),
            // Un module qui n'écrit nulle part n'écrit jamais (48, 54).
            ("bonjour", 60, false, .garder),
            (nil, 60, false, .garder),
            ("bonjour", 0, false, .garder),
            (nil, 0, false, .rien),
        ]
        for c in cas {
            #expect(RelaisRepli.choisir(brutLu: c.brut, secondesAudio: c.secondes, ecrit: c.ecrit) == c.attendu,
                    "\(c)")
        }
    }

    @Test("Le son compte à partir de 0,3 s, le seuil de la voie macOS")
    func seuil() {
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 0.29, ecrit: true) == .rien)
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 0.3, ecrit: true) == .transcrireParMacOS)
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 0.29, ecrit: false) == .rien)
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 0.3, ecrit: false) == .garder)
    }

    @Test("La barre dit d'où vient le texte, et pourquoi ce n'est pas de ChatGPT")
    func annonces() {
        #expect(RelaisRepli.annonce(.inserer("x"), apres: nil)
                == "Transcription brute insérée — ChatGPT abandonné")
        #expect(RelaisRepli.annonce(.transcrireParMacOS, apres: nil)
                == "Transcrit par macOS — ChatGPT abandonné")
        #expect(RelaisRepli.annonce(.garder, apres: nil) == "Gardé dans le menu de Caspr")
        #expect(RelaisRepli.annonce(.rien, apres: nil) == nil)
        #expect(RelaisRepli.annonce(.transcrireParMacOS, apres: .refusParChatGPT("Limite atteinte"))
                == "ChatGPT : Limite atteinte — transcrit par macOS")
        #expect(RelaisRepli.annonce(.transcrireParMacOS, apres: .pasConnecte)
                == "ChatGPT : session déconnectée — transcrit par macOS")
        // Pas « dictée perdue » : elle ne l'est pas.
        #expect(RelaisRepli.annonce(.transcrireParMacOS, apres: .pageInterrompue)
                == "La page ChatGPT s'est fermée — transcrit par macOS")
        #expect(RelaisRepli.annonce(.garder, apres: .pageInterrompue)
                == "La page ChatGPT s'est fermée — gardé dans le menu de Caspr")
    }

    @Test("La touche replie pendant l'attente, la croix annule : le brut, sinon le son")
    func gestes() {
        // Pendant « ChatGPT transcrit… », le brut n'est pas lu : macOS (93).
        #expect(RelaisCycle.decider(.touche, en: .transcription) == .replier)
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 60, ecrit: true) == .transcrireParMacOS)
        // Pendant « ChatGPT répond… », il l'est : le brut (94).
        #expect(RelaisCycle.decider(.touche, en: .reponse) == .replier)
        #expect(RelaisRepli.choisir(brutLu: "brut", secondesAudio: 60, ecrit: true) == .inserer("brut"))
        // La croix n'insère jamais, à aucune phase (49, 95).
        for phase in RelaisPhase.allCases where phase != .demarrage {
            #expect(RelaisCycle.decider(.croix, en: phase) == .annuler, "\(phase)")
        }
        // Un échec prouvé pendant l'écoute ou la transcription replie (96–98).
        #expect(RelaisCycle.replie(apres: .pageInterrompue, en: .ecoute))
        #expect(RelaisCycle.replie(apres: .refusParChatGPT("Limite atteinte"), en: .transcription))
    }
}
