import Foundation
import Testing
@testable import CasprCore

@Suite("Format de l'historique")
struct HistoryEntryTests {

    /// L'entrée telle que la déclarent les 0.14.x : `mode` obligatoire, pas
    /// de `brut`. C'est le lecteur le plus exigeant qui existe encore sur des
    /// machines — quiconque revient à une 0.14 le retrouve.
    private struct Entree014: Decodable {
        let id: UUID
        let text: String
        let date: Date
        let mode: String
    }

    @Test("Un historique écrit aujourd'hui se relit dans une 0.14")
    func seRelitDansLaVersionDAvant() throws {
        let entrees = [
            HistoryEntry(text: "Bonjour à tous."),
            HistoryEntry(text: "Texte repris.", brut: "texte dicté"),
        ]
        let data = try JSONEncoder().encode(entrees)
        let relues = try JSONDecoder().decode([Entree014].self, from: data)
        #expect(relues.map(\.text) == ["Bonjour à tous.", "Texte repris."])
        #expect(relues.map(\.id) == entrees.map(\.id))
    }

    @Test("Une entrée écrite par une 0.14 se relit, son mode compris")
    func relitLesEntreesDAvant() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"Mot à mot","date":0,"mode":"verbatim"}]
        """
        let relues = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        #expect(relues.first?.text == "Mot à mot")
        #expect(relues.first?.brut == nil)
        // Réécrire l'historique ne doit pas effacer ce qu'on a relu.
        let reecrit = try JSONEncoder().encode(relues)
        let encore = try JSONDecoder().decode([Entree014].self, from: reecrit)
        #expect(encore.first?.mode == "verbatim")
    }

    @Test("Une entrée sans mode ni brut se relit quand même")
    func relitSansLesChampsFacultatifs() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"Sans mode","date":0}]
        """
        let relues = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        #expect(relues.first?.text == "Sans mode")
    }
}
