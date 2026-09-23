import Foundation
import Testing
@testable import CasprCore

/// Ce que la calibration automatique a le droit d'écrire.
///
/// La sanction d'une erreur ici est un calibrage qui marchait depuis des
/// semaines remplacé, en silence, par la moitié d'un autre : un parcours
/// automatique qui échoue à mi-chemin ne doit rien rendre à enregistrer.
@Suite("Preuves de la calibration automatique")
struct RelaisPreuvesTests {

    /// Un calibrage complet, tel qu'un utilisateur l'a fait à la main.
    private var ancien: RelaisSelecteurs {
        var s = RelaisSelecteurs()
        s.micro = ".m"; s.stop = ".s"; s.composeur = ".c"
        s.envoi = ".e"; s.reponse = ".r"
        s.copier = ".k"; s.copierParent = ".kp"
        s.lecture = ".l"; s.lectureParent = ".lp"
        s.lectureMenu = ".lm"; s.lectureMenuParent = ".lmp"
        return s
    }

    private func toutProuve() -> RelaisPreuves {
        var p = RelaisPreuves()
        p.prouve(.composeur, "#prompt-textarea")
        p.prouve(.micro, #"[data-testid="composer-speech-button"]"#)
        p.prouve(.stop, #"[data-testid="composer-speech-button-stop"]"#)
        p.prouve(.envoi, #"[data-testid="send-button"]"#)
        p.prouve(.copier, #"[data-testid="copy-turn-action-button"]"#, parent: "")
        return p
    }

    @Test("Rien n'est rendu tant qu'un seul repère manque")
    func partialGivesNothing() {
        for manquant in RelaisPreuves.parcours {
            var p = RelaisPreuves()
            for cible in RelaisPreuves.parcours where cible != manquant {
                p.prouve(cible, ".x")
            }
            p.manque(manquant, "pas vu")
            #expect(!p.complet)
            #expect(p.manquants == [manquant])
            #expect(p.calibrage(remplacant: ancien) == nil)
        }
    }

    @Test("Un parcours vide ne rend rien, et dit tout ce qui manque")
    func emptyGivesNothing() {
        let p = RelaisPreuves()
        #expect(p.manquants == RelaisPreuves.parcours)
        #expect(p.calibrage(remplacant: ancien) == nil)
    }

    /// « Lire à haute voix » reste manuel, et le repère de la réponse sert
    /// encore de repli : le parcours ne les a pas éprouvés, il n'y touche pas.
    @Test("Un parcours complet remplace ce qu'il a prouvé, et rien d'autre")
    func completeKeepsWhatItDidNotProve() throws {
        let nouveau = try #require(toutProuve().calibrage(remplacant: ancien))
        #expect(nouveau.composeur == "#prompt-textarea")
        #expect(nouveau.micro == #"[data-testid="composer-speech-button"]"#)
        #expect(nouveau.envoi == #"[data-testid="send-button"]"#)
        #expect(nouveau.copier == #"[data-testid="copy-turn-action-button"]"#)
        // Prouvé par la recherche autour de la réponse : l'ancien bloc ne
        // doit pas survivre, il désignerait un autre chemin que celui vu.
        #expect(nouveau.copierParent.isEmpty)
        #expect(nouveau.reponse == ".r")
        #expect(nouveau.lecture == ".l")
        #expect(nouveau.lectureParent == ".lp")
        #expect(nouveau.lectureMenu == ".lm")
        #expect(nouveau.lectureMenuParent == ".lmp")
        #expect(nouveau.saitDialoguer)
    }

    @Test("Un premier calibrage sort du parcours prêt à dicter et à dialoguer")
    func firstCalibration() throws {
        let nouveau = try #require(toutProuve().calibrage(remplacant: RelaisSelecteurs()))
        #expect(nouveau.estCalibre)
        #expect(nouveau.saitDialoguer)
        #expect(nouveau.saitCopier)
        #expect(!nouveau.saitLire)
    }

    @Test("Un sélecteur vide, ou un repère hors du parcours, ne prouve rien")
    func emptyOrForeignIsNoProof() {
        var p = toutProuve()
        p.prouve(.lecture, ".l2")
        #expect(p.selecteurs[.lecture] == nil)

        var q = RelaisPreuves()
        q.prouve(.micro, "")
        #expect(q.manquants.contains(.micro))
    }

    /// Une raison posée après la preuve ne l'efface pas : le parcours a pu
    /// essayer d'autres candidats après avoir trouvé le bon.
    @Test("Une preuve l'emporte sur une raison")
    func proofWinsOverReason() {
        var p = RelaisPreuves()
        p.manque(.envoi, "premier candidat muet")
        p.prouve(.envoi, ".e")
        p.manque(.envoi, "second candidat muet")
        #expect(p.selecteurs[.envoi] == ".e")
        #expect(p.raisons[.envoi] == nil)
    }
}
