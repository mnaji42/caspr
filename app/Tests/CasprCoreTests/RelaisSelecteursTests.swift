import Foundation
import Testing
@testable import CasprCore

/// La relecture du calibrage enregistré sous `relais.selecteurs`.
///
/// La sanction d'une erreur ici n'est pas un échec visible : c'est le
/// calibrage de chaque utilisateur effacé à la mise à jour, comme en 0.13.0,
/// quand `envoi` et `reponse` ont été ajoutés sans `decodeIfPresent`. Les
/// JSON ci-dessous sont ceux que chaque version publiée écrivait, reconstitués
/// depuis l'historique du fichier : une version qui ne sait plus les relire ne
/// doit pas pouvoir passer.
@Suite("Sélecteurs du relais")
struct RelaisSelecteursTests {

    private func relire(_ json: String) throws -> RelaisSelecteurs {
        try JSONDecoder().decode(RelaisSelecteurs.self, from: Data(json.utf8))
    }

    /// Un enregistrement vide ne doit pas lever : lever, c'est ce que
    /// `RelaisCatalogue.selecteurs(dans:)` traduit en « rien n'a été calibré ».
    @Test("Un objet vide rend les valeurs par défaut")
    func emptyObjectGivesDefaults() throws {
        #expect(try relire("{}") == RelaisSelecteurs())
    }

    /// v0.12.0 : le micro, l'arrêt et la zone de saisie, rien d'autre.
    @Test("Le calibrage de la 0.12 se relit")
    func readsVersion012() throws {
        let s = try relire(#"{"micro":".m","stop":".s","composeur":".c"}"#)
        #expect(s.micro == ".m")
        #expect(s.stop == ".s")
        #expect(s.composeur == ".c")
        #expect(s.envoi.isEmpty && s.reponse.isEmpty && s.copier.isEmpty)
        #expect(s.estCalibre)
        #expect(!RelaisCatalogue.reorganiser.estUtilisable(s))
    }

    /// v0.13 : l'envoi et le repère de la réponse, avant le bouton copier.
    /// Ce repère suffit encore à dialoguer — l'exiger ferait disparaître les
    /// modules chez qui a calibré à cette époque.
    @Test("Le calibrage de la 0.13 se relit, et sait encore dialoguer")
    func readsVersion013() throws {
        let s = try relire(#"""
            {"micro":".m","stop":".s","composeur":".c","envoi":".e","reponse":".r"}
            """#)
        #expect(s.envoi == ".e")
        #expect(s.reponse == ".r")
        #expect(RelaisCatalogue.reorganiser.estUtilisable(s))
        #expect(s.copier.isEmpty)
        #expect(RelaisCapacite.recuperer.estAcquise(s))
    }

    /// v0.14.2 ajoute le bouton copier ; v0.14.5 le bloc qui le porte.
    @Test("Les calibrages de la 0.14 se relisent")
    func readsVersion014() throws {
        let v142 = try relire(#"""
            {"micro":".m","stop":".s","composeur":".c","envoi":".e","reponse":".r",
             "copier":".k"}
            """#)
        #expect(v142.copier == ".k")
        #expect(v142.copierParent.isEmpty)

        let v145 = try relire(#"""
            {"micro":".m","stop":".s","composeur":".c","envoi":".e","reponse":".r",
             "copier":".k","copierParent":".kp"}
            """#)
        #expect(v145.copierParent == ".kp")
        #expect(v145.lecture.isEmpty && v145.lectureMenu.isEmpty)
        #expect(!v145.saitLire)
    }

    /// Une clé qu'une version plus récente aurait ajoutée n'empêche pas de
    /// relire les autres : revenir à une version antérieure ne doit pas coûter
    /// le calibrage non plus.
    @Test("Une clé inconnue est ignorée")
    func ignoresUnknownKey() throws {
        let s = try relire(#"{"micro":".m","stop":".s","demain":".d"}"#)
        #expect(s.micro == ".m")
        #expect(s.estCalibre)
    }

    private var complet: RelaisSelecteurs {
        var s = RelaisSelecteurs()
        s.micro = ".micro"
        s.stop = ".stop"
        s.composeur = ".composeur"
        s.envoi = ".envoi"
        s.reponse = ".reponse"
        s.copier = ".copier"
        s.copierParent = ".copierParent"
        s.lecture = ".lecture"
        s.lectureParent = ".lectureParent"
        s.lectureMenu = ".lectureMenu"
        s.lectureMenuParent = ".lectureMenuParent"
        return s
    }

    @Test("Un calibrage complet survit à l'aller-retour")
    func roundTrips() throws {
        let data = try JSONEncoder().encode(complet)
        #expect(try JSONDecoder().decode(RelaisSelecteurs.self, from: data) == complet)
    }

    /// Les clés écrites sont celles que les versions précédentes relisent.
    /// Renommer une propriété changerait la clé en silence — et l'ancien
    /// calibrage, relu sous l'ancien nom, serait vide.
    @Test("Les clés enregistrées ne changent pas de nom")
    func keysAreStable() throws {
        let data = try JSONEncoder().encode(complet)
        let objet = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(Set(objet.keys) == [
            "micro", "stop", "composeur", "envoi", "reponse", "copier",
            "copierParent", "lecture", "lectureParent", "lectureMenu",
            "lectureMenuParent",
        ])
        // Et chaque valeur sous sa propre clé, pas sous celle d'une voisine.
        for (cle, valeur) in objet { #expect(valeur == "." + cle) }
    }

    /// La calibration écrit par l'indice, cible après cible : un cas branché
    /// sur le mauvais champ ferait apprendre l'envoi à la place du copier.
    @Test("L'indice par cible lit et écrit le bon champ")
    func subscriptTargetsItsOwnField() {
        var s = RelaisSelecteurs()
        for cible in RelaisCible.allCases { s[cible] = cible.rawValue }
        for cible in RelaisCible.allCases { #expect(s[cible] == cible.rawValue) }
        #expect(s.envoi == "envoi")
        #expect(s.copier == "copier")
    }
    /// Le calibrage réel d'une machine où la dictée bouclait, relevé dans
    /// `relais.selecteurs` le 4 octobre 2026.
    ///
    /// Cinq repères sur sept sont des adresses — un `data-testid`, des libellés
    /// d'accessibilité — et deux sont des chaînes de position. Ce sont
    /// exactement les deux qui ont cassé : la zone de saisie, que la dictée
    /// attendait sans fin (« zone non » à chaque relevé du journal), et la
    /// réponse, dont le dernier élément trouvé tombait dans un autre tour — ce
    /// qui faisait refuser par « Pas ce bouton-là » un bouton « copier »
    /// pourtant correctement désigné.
    @Test("Un repère retenu par sa position est signalé comme fragile")
    func positionalSelectorsAreFlagged() throws {
        let s = try relire(#"""
            {"stop":"[aria-label=\"Arrêter la dictée\"]",
             "composeur":"div:nth-of-type(3) > div:nth-of-type(2) > div > div > div > div",
             "micro":"[aria-label=\"Dicter\"]",
             "reponse":"div:nth-of-type(1) > div:nth-of-type(1) > div > div > div > p",
             "copier":"[data-testid=\"copy-turn-action-button\"]",
             "envoi":"[aria-label=\"Envoyer\"]",
             "lecture":"[data-testid=\"voice-play-turn-action-button\"]"}
            """#)
        #expect(s.estCalibre)
        #expect(s.fragiles == [.composeur, .reponse])
    }

    /// Un calibrage entièrement fait d'adresses ne doit rien déclencher : la
    /// mise en garde ne vaut que si elle reste rare.
    @Test("Des repères d'identité ne sont pas signalés")
    func addressSelectorsAreNotFlagged() {
        var s = RelaisSelecteurs()
        s.micro = #"[aria-label="Dicter"]"#
        s.stop = #"[aria-label="Arrêter"]"#
        s.composeur = "#prompt-textarea"
        s.reponse = #"[data-message-author-role="assistant"]"#
        #expect(s.fragiles.isEmpty)
    }

    /// Une cible jamais calibrée n'est pas « fragile » : elle est absente, ce
    /// qu'`estCalibre` et le filet des heuristiques traitent déjà.
    @Test("Un repère vide n'est pas fragile")
    func emptySelectorIsNotFragile() {
        #expect(RelaisSelecteurs().fragiles.isEmpty)
    }
}

