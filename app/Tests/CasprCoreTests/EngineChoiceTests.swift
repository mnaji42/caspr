import Testing
@testable import CasprCore

/// Les deux versions du moteur de macOS, et ce qui doit rester vrai d'elles.
///
/// Ces règles ne lèvent aucune erreur quand elles se trompent : un identifiant
/// renommé relit simplement le défaut au lancement suivant, deux libellés
/// identiques donnent un sélecteur à deux lignes pareilles.
@Suite("Versions du moteur de macOS")
struct EngineChoiceTests {

    /// `systemEngines` bâtit le sélecteur et fixe l'ordre de préférence. Une
    /// version qui y manquerait ne serait jamais proposée, ni jamais choisie
    /// en repli.
    @Test("Toutes les versions sont proposées, Apple Intelligence d'abord")
    func systemListCoversEveryCase() {
        #expect(Set(EngineChoice.systemEngines) == Set(EngineChoice.allCases))
        #expect(EngineChoice.systemEngines.first == .apple)
    }

    /// Les modes passent par le prompt d'un décodeur. Aucune version de macOS
    /// n'en a : leur prêter cette capacité ferait afficher un sélecteur de
    /// mode sans effet.
    @Test("Aucune version n'a de modes")
    func noPromptCapability() {
        for engine in EngineChoice.allCases {
            #expect(!engine.hasModes)
        }
    }

    /// Les `rawValue` sont écrits dans les préférences. En renommer un ne
    /// casse aucune compilation : ça relit simplement `nil` au prochain
    /// lancement, et l'utilisateur retrouve la version par défaut sans que
    /// rien ne le dise.
    @Test("Les identifiants persistés sont ceux déjà écrits sur disque")
    func rawValuesAreStable() {
        #expect(EngineChoice.apple.rawValue == "apple")
        #expect(EngineChoice.appleLegacy.rawValue == "apple-legacy")
        for engine in EngineChoice.allCases {
            #expect(EngineChoice(rawValue: engine.rawValue) == engine)
        }
    }

    /// L'ancien moteur local ne doit plus se relire. S'il se relisait, un
    /// réglage que la migration n'aurait pas encore traduit ferait dicter
    /// avec un moteur que plus rien ne sait lancer.
    @Test("L'identifiant de l'ancien moteur local ne se relit plus")
    func retiredEngineIsGone() {
        #expect(EngineChoice(rawValue: LegacyCleanup.retiredEngine) == nil)
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
