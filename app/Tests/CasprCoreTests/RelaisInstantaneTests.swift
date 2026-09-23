import Foundation
import Testing
@testable import CasprCore

/// Le relevé que rend la page, décodé même partiel.
@Suite("Instantané du relais")
struct RelaisInstantaneTests {

    private static func decoder(_ json: String) throws -> RelaisInstantane {
        try JSONDecoder().decode(RelaisInstantane.self, from: Data(json.utf8))
    }

    /// Un pont d'une autre version peut omettre un champ : le relevé entier
    /// ne doit pas en devenir illisible, ce qui se lirait comme un silence.
    @Test("Un relevé partiel se décode, chaque champ absent à sa valeur par défaut")
    func partiel() throws {
        #expect(try Self.decoder("{}") == RelaisInstantane())
        let vu = try Self.decoder(#"{"ok":true,"composeur":true,"reponse":{"nouvelles":2},"inconnu":1}"#)
        #expect(vu.composeur && !vu.micro && !vu.authentification)
        #expect(vu.reponse == .init(nouvelles: 2))
        #expect(vu.texte == nil && vu.echec == nil)
    }

    @Test("Une zone introuvable se distingue d'une zone vide ; l'échec se lit entier")
    func champs() throws {
        #expect(try Self.decoder(#"{"texte":null}"#).texte == nil)
        #expect(try Self.decoder(#"{"texte":""}"#).texte == "")
        #expect(try Self.decoder(#"{"echec":null}"#).echec == nil)
        #expect(try Self.decoder(#"{"echec":{"texte":"Réessayez","reconnue":true}}"#).echec
                == .init(texte: "Réessayez", reconnue: true))
        let vu = try Self.decoder("""
            {"conversation":true,"authentification":false,"composeur":false,"micro":true,
             "stop":true,"enregistrement":true,
             "reponse":{"nouvelles":1,"enCours":true,"longueur":42,"copierPret":false}}
            """)
        #expect(vu.conversation && vu.micro && vu.stop && vu.enregistrement)
        #expect(vu.reponse == .init(nouvelles: 1, enCours: true, longueur: 42))
    }
}
