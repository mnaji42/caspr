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

    @Test("Sans brut ni son utilisable, l'aperçu de macOS est le texte qui reste")
    func apercu() {
        // Un contexte de la page hors 16 kHz : l'écho ne compte aucune
        // seconde, l'aperçu, qui convertit, a écrit (93, 97).
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 0, ecrit: true, apercu: " bonjour ")
                == .insererLApercu("bonjour"))
        // Le son entier passe avant : macOS relit toute la phrase.
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 60, ecrit: true, apercu: "bonjour")
                == .transcrireParMacOS)
        // Le brut de ChatGPT passe avant tout (94).
        #expect(RelaisRepli.choisir(brutLu: "brut", secondesAudio: 0, ecrit: true, apercu: "bonjour")
                == .inserer("brut"))
        // Un module qui n'écrit nulle part le garde au menu ; un aperçu blanc
        // n'est pas un texte.
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 0, ecrit: false, apercu: "bonjour") == .garder)
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 0, ecrit: true, apercu: " \n") == .rien)
    }

    /// macOS sans son modèle ou sans son droit : rien ne se télécharge ni ne
    /// se demande au milieu d'une dictée. L'aperçu s'insère s'il y en a un,
    /// sinon le son reste au menu.
    @Test func macOSPasPret() {
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 60, ecrit: true, macOSPret: false) == .garder)
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 60, ecrit: true, apercu: "bonjour", macOSPret: false)
            == .insererLApercu("bonjour"))
        #expect(RelaisRepli.choisir(brutLu: "brut", secondesAudio: 60, ecrit: true, macOSPret: false)
            == .inserer("brut"))
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 0.1, ecrit: true, macOSPret: false) == .rien)
        // Une page morte ne dit plus « dictée perdue » quand l'aperçu reste.
        #expect(RelaisRepli.annonce(.insererLApercu("x"), apres: .pageInterrompue)
                == "La page ChatGPT s'est fermée — aperçu de macOS inséré")
        #expect(RelaisRepli.annonce(.insererLApercu("x"), apres: nil, son: 0, parle: 60)
                == "Aperçu de macOS inséré — ChatGPT abandonné")
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

    @Test("Un son qui ne couvre pas la dictée se dit : le texte de macOS n'en est qu'une partie")
    func couverture() {
        // Le contexte de la page parti un instant après la preuve d'écoute.
        #expect(RelaisRepli.couvre(son: 12.4, parle: 12.6))
        #expect(RelaisRepli.couvre(son: 55, parle: 60))
        #expect(!RelaisRepli.couvre(son: 40, parle: 60))
        #expect(!RelaisRepli.couvre(son: 2, parle: 5))
        // Rien à comparer : une page morte avant l'arrêt figé.
        #expect(RelaisRepli.couvre(son: 3, parle: 0))
        #expect(RelaisRepli.annonce(.transcrireParMacOS, apres: nil, son: 55, parle: 60)
                == "Transcrit par macOS — ChatGPT abandonné")
        #expect(RelaisRepli.annonce(.transcrireParMacOS, apres: nil, son: 12.4, parle: 60)
                == "Transcrit par macOS (12 s de son sur 60 s) — ChatGPT abandonné")
        #expect(RelaisRepli.annonce(.transcrireParMacOS, apres: .pasConnecte, son: 12.4, parle: 60)
                == "ChatGPT : session déconnectée — transcrit par macOS (12 s de son sur 60 s)")
        // Le brut de ChatGPT vient de tout le son de la page : le tee n'y est
        // pour rien.
        #expect(RelaisRepli.annonce(.inserer("x"), apres: nil, son: 0, parle: 60)
                == "Transcription brute insérée — ChatGPT abandonné")
    }

    @Test("Le motif du repli : ce que le menu garde si macOS échoue à son tour")
    func motifs() {
        #expect(RelaisRepli.motif(apres: nil) == "ChatGPT abandonné")
        #expect(RelaisRepli.motif(apres: .refusParChatGPT("Limite atteinte")) == "ChatGPT : Limite atteinte")
        #expect(RelaisRepli.motif(apres: .pageInterrompue) == "La page ChatGPT s'est fermée")
        #expect(RelaisRepli.motif(apres: .pontAbsent) == "Caspr est incomplet : réinstallez-le")
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
        // Après, la seconde passe rend le brut elle-même (48).
        #expect(!RelaisCycle.replie(apres: .refusParChatGPT("Limite atteinte"), en: .reponse))
    }

    /// Dix minutes dictées, et ChatGPT rend la zone vide : la page
    /// entendait une voix, la dictée n'est pas un silence (34, E2).
    @Test("Une zone revenue vide sur une voix entendue est une dictée perdue, que macOS reprend")
    func zoneVideSurUneVoix() {
        #expect(RelaisRepli.parole(crete: 0.25, apercu: ""))
        #expect(RelaisRepli.parole(crete: 0, apercu: "bonjour"))
        #expect(!RelaisRepli.parole(crete: 0.005, apercu: " \n"))
        // Le tee n'a rien reçu : rien ne prouve une voix, la dictée finit comme avant (100).
        #expect(!RelaisRepli.parole(crete: 0, apercu: ""))
        #expect(RelaisRepli.choisir(brutLu: nil, secondesAudio: 600, ecrit: true) == .transcrireParMacOS)
        #expect(RelaisRepli.annonce(.transcrireParMacOS, apres: .rienTranscrit, son: 600, parle: 600)
                == "ChatGPT n'a rien transcrit — transcrit par macOS")
    }

    /// Un appui muet dont le clic dépasse le seuil de la crête : macOS,
    /// repris sur ce son, n'y entend rien non plus. Ce n'était qu'un
    /// silence, qui finit sans rien au menu (34, 57).
    @Test("Une zone vide que macOS ne transcrit pas non plus est un silence")
    func silenceConfirmeParMacOS() {
        #expect(RelaisRepli.silence(apres: .rienTranscrit, apercu: ""))
        #expect(RelaisRepli.silence(apres: .rienTranscrit, apercu: " \n"))
        // L'aperçu a écrit : une voix, que le menu garde.
        #expect(!RelaisRepli.silence(apres: .rienTranscrit, apercu: "bonjour"))
        // Abandonnée ou refusée, la dictée n'est pas jugée sur macOS : un vide
        // y garde l'audio, comme partout ailleurs.
        #expect(!RelaisRepli.silence(apres: nil, apercu: ""))
        #expect(!RelaisRepli.silence(apres: .pageInterrompue, apercu: ""))
    }

    /// Un refus relevé à tort pendant la transcription porte les mots dictés.
    /// La barre et le menu les montrent — c'est l'écran de l'utilisateur —,
    /// le journal, jamais : ni la ligne du repli, ni l'échec que l'icône
    /// affiche ensuite, qui ne garde que sa longueur (cf. `CasprApp.render`).
    @Test("Le journal d'un repli après un refus n'en garde pas le texte, la barre si")
    func refusHorsDuJournal() {
        let dictee = "Je n'ai pas compris, tu peux réessayer ?"
        let refus = RelaisErreur.refusParChatGPT(dictee)
        for repli: RelaisRepli in [.garder, .transcrireParMacOS, .inserer(dictee), .insererLApercu(dictee), .rien] {
            #expect(!RelaisRepli.pourLeJournal(repli, apres: refus).contains(dictee))
        }
        #expect(RelaisRepli.annonce(.garder, apres: refus)?.contains(dictee) == true)
        #expect(RelaisRepli.pourLeJournal(.garder, apres: nil) == "repli après la touche — gardé dans le menu de Caspr")
        #expect(RelaisRepli.pourLeJournal(.rien, apres: .pasConnecte)
                == "repli après \(RelaisErreur.pasConnecte.localizedDescription) — rien à livrer")
    }
}
