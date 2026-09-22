import Foundation
import Testing
@testable import CasprCore

/// Le catalogue des langues, lu dans le fichier que l'application embarque.
///
/// Un champ exigé que le fichier n'a plus — ou l'inverse — ne lève rien au
/// lancement : l'application retombe sur deux langues de secours, et le
/// sélecteur se vide du reste sans un mot. C'est arrivé à deux doigts de se
/// produire en retirant la couverture de l'ancien moteur local, un champ
/// non optionnel du décodeur. D'où le vrai fichier ici, et non un extrait.
@Suite("Catalogue des langues")
struct LanguageCatalogueTests {

    /// Le fichier que `install.sh` copie dans le bundle.
    static let bundled = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // CasprCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // app
        .appending(path: "Sources/Caspr/Resources/languages.json")

    @Test("Le fichier embarqué se décode, et n'est pas vide")
    func bundledFileDecodes() throws {
        let catalogue = try LanguageCatalogue.decode(Data(contentsOf: Self.bundled))
        #expect(catalogue.languages.count > 30)
        let codes = catalogue.languages.map(\.code)
        #expect(codes.contains("fr-FR"))
        #expect(codes.contains("en-US"))
        #expect(Set(codes).count == codes.count, "une locale en double")
    }

    @Test("Les langues sortent dans l'ordre d'affichage")
    func rowsAreSortedByRank() throws {
        let catalogue = try LanguageCatalogue.decode(Data(contentsOf: Self.bundled))
        let ranks = catalogue.languages.map(\.rank)
        #expect(ranks == ranks.sorted())
        #expect(catalogue.languages.first?.code == "fr-FR")
    }

    /// Un fichier d'une version antérieure portait la couverture de l'ancien
    /// moteur local, sous une clé que le décodeur ne lit plus. Une clé en trop
    /// ne doit rien casser : c'est ce qui permet d'en retirer une du décodeur
    /// sans exiger que tous les fichiers suivent au même instant.
    @Test("Une clé inconnue est ignorée")
    func unknownKeysAreIgnored() throws {
        let json = #"""
        {"retiredCoverage": ["fr"], "languages": [
          {"code": "fr-FR", "name": "Français", "region": "France", "flag": "🇫🇷",
           "frenchName": "français", "estimatedModelMegabytes": 65, "rank": 0}]}
        """#
        let catalogue = try LanguageCatalogue.decode(Data(json.utf8))
        #expect(catalogue.languages.map(\.code) == ["fr-FR"])
    }
}
