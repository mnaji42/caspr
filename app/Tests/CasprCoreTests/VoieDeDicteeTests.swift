import Foundation
import Testing
@testable import CasprCore

/// La voie de dictée, et son passage depuis l'interrupteur du relais.
///
/// Une erreur ici ne lève rien : elle fait dicter par macOS quelqu'un qui
/// avait allumé ChatGPT — ou l'inverse, et c'est alors une page tierce qui
/// écoute sans qu'on l'ait choisi.
@Suite("Voie de dictée")
struct VoieDeDicteeTests {

    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "caspr.tests.voie.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    /// Les valeurs brutes sont écrites sur le disque : en renommer une relit
    /// macOS chez tous ceux qui avaient choisi ChatGPT.
    @Test("Les identifiants persistés ne changent pas")
    func rawValuesAreStable() {
        #expect(VoieDeDictee.apple.rawValue == "apple")
        #expect(VoieDeDictee.chatgpt.rawValue == "chatgpt")
        #expect(VoieDeDictee.cle == "caspr.voie")
        #expect(VoieDeDictee.cleHeritee == "relais.actif")
    }

    @Test("Le relais allumé devient la voie ChatGPT")
    func switchedOnRelayBecomesChatGPT() {
        Self.withDefaults { defaults in
            defaults.set(true, forKey: "relais.actif")
            #expect(VoieDeDictee.migrer(defaults) == .chatgpt)
            #expect(VoieDeDictee.relue(defaults) == .chatgpt)
        }
    }

    @Test("Le relais éteint, ou jamais touché, devient la voie macOS")
    func otherwiseApple() {
        Self.withDefaults { defaults in
            defaults.set(false, forKey: "relais.actif")
            #expect(VoieDeDictee.migrer(defaults) == .apple)
        }
        Self.withDefaults { defaults in
            #expect(VoieDeDictee.migrer(defaults) == .apple)
            #expect(defaults.string(forKey: "caspr.voie") == "apple")
        }
    }

    /// L'interrupteur ne bouge plus après la migration : le relire à chaque
    /// lancement effacerait tout choix fait depuis.
    @Test("Une voie déjà rangée n'est jamais réécrite")
    func keepsAStoredChoice() {
        Self.withDefaults { defaults in
            defaults.set(true, forKey: "relais.actif")
            defaults.set("apple", forKey: "caspr.voie")
            #expect(VoieDeDictee.migrer(defaults) == nil)
            #expect(VoieDeDictee.relue(defaults) == .apple)
        }
    }

    /// Règle 10 du relais : aucune clé `relais.*` ne s'efface.
    @Test("L'interrupteur du relais reste sur le disque")
    func leavesTheLegacyKey() {
        Self.withDefaults { defaults in
            defaults.set(true, forKey: "relais.actif")
            VoieDeDictee.migrer(defaults)
            #expect(defaults.object(forKey: "relais.actif") as? Bool == true)
        }
    }

    @Test("Une valeur inconnue se relit comme macOS")
    func unknownValueReadsAsApple() {
        Self.withDefaults { defaults in
            defaults.set("whisper", forKey: "caspr.voie")
            #expect(VoieDeDictee.relue(defaults) == .apple)
        }
    }
}
