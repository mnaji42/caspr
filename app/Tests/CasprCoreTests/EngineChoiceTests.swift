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
                                           appleNotRefused: false) == .apple)
        }
    }

    /// Apple Intelligence qui propose la langue sans en avoir le modèle —
    /// ou la machine virtuelle, où elle se dit disponible sans rien savoir
    /// faire. La Dictée qui marche doit écrire, plutôt qu'une transcription
    /// qui commencerait par un téléchargement, et échouerait hors ligne.
    @Test("La Dictée prête écrit quand Apple Intelligence ne l'est pas")
    func legacyWhenAppleIsNotReady() {
        for notRefused in [true, false] {
            #expect(EngineChoice.automatic(appleReady: false, legacyReady: true,
                                           appleNotRefused: notRefused) == .appleLegacy)
        }
    }

    @Test("Aucune prête : Apple Intelligence si le système ne l'a pas refusée")
    func noneReady() {
        #expect(EngineChoice.automatic(appleReady: false, legacyReady: false,
                                       appleNotRefused: true) == .apple)
        #expect(EngineChoice.automatic(appleReady: false, legacyReady: false,
                                       appleNotRefused: false) == .appleLegacy)
    }

    @Test("Deux versions ne portent jamais le même libellé")
    func labelsAreDistinct() {
        let labels = EngineChoice.allCases.map(\.fullLabel)
        #expect(Set(labels).count == labels.count)
    }
}
