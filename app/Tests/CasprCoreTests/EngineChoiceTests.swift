import Testing
@testable import CasprCore

/// Les deux versions du moteur de macOS, et ce qui doit rester vrai d'elles.
///
/// Ces règles ne lèvent aucune erreur quand elles se trompent : une version
/// mal choisie rend une chaîne vide, deux libellés identiques une carte qui
/// ne dit plus laquelle écrit.
@Suite("Versions du moteur de macOS")
struct EngineChoiceTests {

    /// `systemEngines` fixe l'ordre de préférence. Une version qui y
    /// manquerait ne serait jamais montrée comme disponible.
    @Test("Toutes les versions sont proposées, Apple Intelligence d'abord")
    func systemListCoversEveryCase() {
        #expect(Set(EngineChoice.systemEngines) == Set(EngineChoice.allCases))
        #expect(EngineChoice.systemEngines.first == .apple)
    }

    /// Apple Intelligence écrit mieux : dès qu'elle sait la langue, c'est
    /// elle, que la Dictée soit prête ou non.
    @Test("Apple Intelligence prête l'emporte")
    func appleWinsWhenReady() {
        for legacy in [true, false] {
            #expect(EngineChoice.automatic(appleReady: true, legacyReady: legacy,
                                           appleUnanswered: false) == .apple)
        }
    }

    /// Le cas de la machine virtuelle : Apple Intelligence se dit disponible
    /// sans modèle. Seule une réponse du système la rend prête ; sans elle,
    /// la Dictée qui marche doit écrire.
    @Test("La Dictée prête écrit quand Apple Intelligence ne l'est pas")
    func legacyWhenAppleIsNotReady() {
        for unanswered in [true, false] {
            #expect(EngineChoice.automatic(appleReady: false, legacyReady: true,
                                           appleUnanswered: unanswered) == .appleLegacy)
        }
    }

    @Test("Aucune prête : Apple Intelligence si le système n'a pas encore répondu")
    func noneReady() {
        #expect(EngineChoice.automatic(appleReady: false, legacyReady: false,
                                       appleUnanswered: true) == .apple)
        #expect(EngineChoice.automatic(appleReady: false, legacyReady: false,
                                       appleUnanswered: false) == .appleLegacy)
    }

    @Test("Deux versions ne portent jamais le même libellé")
    func labelsAreDistinct() {
        let labels = EngineChoice.allCases.map(\.fullLabel)
        #expect(Set(labels).count == labels.count)
    }

    @Test("Chaque version explique ce qu'elle change")
    func everyVersionExplainsItself() {
        for engine in EngineChoice.allCases {
            #expect(!engine.versionExplanation.isEmpty)
        }
    }
}
