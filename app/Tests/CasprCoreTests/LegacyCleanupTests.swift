import Foundation
import Testing
@testable import CasprCore

/// Ce que la migration de septembre 2026 reprend, et surtout ce qu'elle ne
/// touche pas.
///
/// Elle s'exécute sans que personne l'ait demandée, sur la machine de chaque
/// utilisateur, et ce qu'elle rate ne se voit pas : un calibrage du relais
/// effacé ressemble à un relais cassé, un dépôt de développeur à la corbeille
/// ressemble à un disque qui a perdu des fichiers. D'où des tests qui portent
/// autant sur ce qui reste que sur ce qui part.
@Suite("Migration de la refonte")
struct LegacyCleanupTests {

    /// Un domaine de réglages jetable, pour ne jamais toucher ceux de la
    /// machine qui fait tourner les tests.
    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "caspr.tests.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    /// Les réglages qu'aucune migration n'a le droit d'effacer — règle 10 du
    /// relais, et ce que l'utilisateur remarquerait le premier.
    private static let protected: [String: Any] = [
        "relais.selecteurs": Data([1, 2, 3]),
        "relais.actif": true,
        "relais.modules": ["brut"],
        "relais.mode": "reorganiser",
        "caspr.shortcut": ["keyCode": 2, "modifiers": 256, "label": "⌘D"],
        "caspr.languages.selected": ["fr-FR", "en-US"],
        "caspr.languages.primary": "fr-FR",
        "caspr.history": Data([4, 5, 6]),
        "caspr.dictation.destination": "notes",
        "caspr.notes.file": "/tmp/notes.md",
    ]

    @Test("CrisperWhisper devient macOS, famille et version ensemble")
    func migratesFinalEngine() {
        Self.withDefaults { defaults in
            defaults.set("crisperwhisper", forKey: "caspr.engine.final")
            LegacyCleanup.migrateSettings(defaults) { "apple-legacy" }
            #expect(defaults.string(forKey: "caspr.engine.final") == "apple")
            #expect(defaults.string(forKey: "caspr.engine.apple") == "apple-legacy")
        }
    }

    /// Une installation qui ne s'est pas relancée depuis la séparation en deux
    /// réglages n'a que l'ancienne clé : sans ce cas, `Preferences` la
    /// relirait et reprendrait CrisperWhisper.
    @Test("L'ancien réglage unique sur CrisperWhisper est repris aussi")
    func migratesLegacyEngine() {
        Self.withDefaults { defaults in
            defaults.set("crisperwhisper", forKey: "caspr.engine")
            LegacyCleanup.migrateSettings(defaults) { "apple" }
            #expect(defaults.string(forKey: "caspr.engine.final") == "apple")
            #expect(defaults.string(forKey: "caspr.engine.apple") == "apple")
        }
    }

    /// La question « quelle version de macOS ? » interroge le système : un
    /// utilisateur déjà sur macOS n'a pas à la payer à chaque lancement, ni à
    /// voir sa version réécrite.
    @Test("Qui est déjà sur macOS garde sa version, sans interroger le système")
    func leavesAppleUsersAlone() {
        Self.withDefaults { defaults in
            defaults.set("apple", forKey: "caspr.engine.final")
            defaults.set("apple-legacy", forKey: "caspr.engine.apple")
            var asked = false
            let done = LegacyCleanup.migrateSettings(defaults) {
                asked = true
                return "apple"
            }
            #expect(!asked)
            #expect(done.isEmpty)
            #expect(defaults.string(forKey: "caspr.engine.apple") == "apple-legacy")
        }
    }

    @Test("Le filet de sécurité ne retombe plus sur CrisperWhisper")
    func migratesLastValidEngine() {
        Self.withDefaults { defaults in
            defaults.set("apple", forKey: "caspr.engine.final")
            defaults.set("apple", forKey: "caspr.engine.apple")
            defaults.set("crisperwhisper", forKey: "caspr.engine.lastValid")
            LegacyCleanup.migrateSettings(defaults) { "apple-legacy" }
            // La version réglée, pas celle qu'on aurait choisie à sa place.
            #expect(defaults.string(forKey: "caspr.engine.lastValid") == "apple")
        }
    }

    @Test("Les réglages sans objet partent, les autres restent à l'identique")
    func removesObsoleteKeysOnly() {
        Self.withDefaults { defaults in
            for (key, value) in Self.protected { defaults.set(value, forKey: key) }
            for key in LegacyCleanup.obsoleteKeys { defaults.set("x", forKey: key) }
            defaults.set("crisperwhisper", forKey: "caspr.engine.final")

            LegacyCleanup.migrateSettings(defaults) { "apple" }

            for key in LegacyCleanup.obsoleteKeys {
                #expect(defaults.object(forKey: key) == nil, "\(key)")
            }
            for (key, value) in Self.protected {
                let kept = defaults.object(forKey: key) as? NSObject
                #expect(kept == value as? NSObject, "\(key)")
            }
        }
    }

    /// L'accueil rouvre là où on l'a quitté. Relu comme un rang, l'ancien
    /// index désignerait l'écran d'après dès que l'accueil en perd un.
    @Test("L'étape d'accueil passe d'un rang à un nom, et l'ancien rang part")
    func translatesOnboardingStep() {
        Self.withDefaults { defaults in
            defaults.set(2, forKey: "caspr.onboarding.step")
            LegacyCleanup.migrateSettings(defaults) { "apple" }
            #expect(defaults.string(forKey: "caspr.onboarding.screen") == "liveEngine")
            #expect(defaults.object(forKey: "caspr.onboarding.step") == nil)
        }
    }

    @Test("Un rang inconnu ne désigne aucun écran, et ne reste pas")
    func dropsUnknownOnboardingStep() {
        Self.withDefaults { defaults in
            defaults.set(9, forKey: "caspr.onboarding.step")
            LegacyCleanup.migrateSettings(defaults) { "apple" }
            #expect(defaults.object(forKey: "caspr.onboarding.screen") == nil)
            #expect(defaults.object(forKey: "caspr.onboarding.step") == nil)
        }
    }

    /// Une ancienne version relancée après la nouvelle réécrit son rang ; il
    /// ne doit pas écraser l'étape que la nouvelle a rangée depuis.
    @Test("Un nom déjà rangé l'emporte sur un vieux rang")
    func keepsOnboardingScreen() {
        Self.withDefaults { defaults in
            defaults.set("finalEngine", forKey: "caspr.onboarding.screen")
            defaults.set(0, forKey: "caspr.onboarding.step")
            LegacyCleanup.migrateSettings(defaults) { "apple" }
            #expect(defaults.string(forKey: "caspr.onboarding.screen") == "finalEngine")
            #expect(defaults.object(forKey: "caspr.onboarding.step") == nil)
        }
    }

    @Test("Aucune clé du relais n'est jamais dans la liste à effacer")
    func neverListsRelaisKeys() {
        #expect(!LegacyCleanup.obsoleteKeys.contains { $0.hasPrefix("relais.") })
    }

    @Test("Un second passage ne trouve plus rien à faire")
    func isIdempotent() {
        Self.withDefaults { defaults in
            defaults.set("crisperwhisper", forKey: "caspr.engine.final")
            defaults.set("crisperwhisper", forKey: "caspr.engine.lastValid")
            defaults.set(["fastapi"], forKey: "caspr.lexicon")
            defaults.set(true, forKey: "caspr.schema.migrated")
            #expect(!LegacyCleanup.migrateSettings(defaults) { "apple" }.isEmpty)
            #expect(LegacyCleanup.migrateSettings(defaults) { "apple" }.isEmpty)
        }
    }

    /// Tant que `Preferences` n'a pas posé sa marque, l'ancienne clé est ce
    /// qui distingue une installation existante d'une neuve.
    @Test("L'ancien réglage unique reste tant qu'il sert encore à quelque chose")
    func keepsLegacyKeyUntilSuperseded() {
        Self.withDefaults { defaults in
            defaults.set("apple-legacy", forKey: "caspr.engine")
            LegacyCleanup.migrateSettings(defaults) { "apple" }
            #expect(defaults.string(forKey: "caspr.engine") == "apple-legacy")

            defaults.set("apple", forKey: "caspr.engine.final")
            defaults.set("apple-legacy", forKey: "caspr.engine.apple")
            defaults.set(true, forKey: "caspr.schema.migrated")
            LegacyCleanup.migrateSettings(defaults) { "apple" }
            #expect(defaults.object(forKey: "caspr.engine") == nil)
        }
    }

    // MARK: - Les fichiers

    private static let home = URL(fileURLWithPath: "/Users/quelquun")

    private static func paths(_ locations: [LegacyCleanup.Location]) -> [String] {
        locations.map(\.url.path)
    }

    @Test("Le moteur installé par l'application part avec son outil")
    func ownEngine() {
        let project = "/Users/quelquun/Library/Application Support/Caspr/engine"
        let paths = Self.paths(LegacyCleanup.engineLocations(home: Self.home,
                                                             project: project))
        #expect(paths == [
            "/Users/quelquun/Library/Application Support/Caspr/engine",
            "/Users/quelquun/Library/Application Support/Caspr/tools",
        ])
    }

    @Test("Le dépôt cloné par l'ancienne commande part s'il est à ~/.caspr")
    func canonicalClone() {
        let paths = Self.paths(LegacyCleanup.engineLocations(
            home: Self.home, project: "/Users/quelquun/.caspr/engine"))
        #expect(paths.contains("/Users/quelquun/.caspr"))
    }

    /// Le cas qui justifie à lui seul ces tests : un développeur dont le
    /// moteur tournait depuis son dépôt de travail. Ni le dépôt, ni son
    /// parent, ni son `.venv` — rien de ce qui est sous git n'est touché.
    @Test("Un dépôt de travail n'est jamais touché")
    func developerRepository() {
        let project = "/Users/quelquun/code/caspr/engine"
        let paths = Self.paths(LegacyCleanup.engineLocations(home: Self.home,
                                                             project: project))
        #expect(!paths.contains { $0.hasPrefix("/Users/quelquun/code") })
    }

    @Test("Seuls les modèles CrisperWhisper sont pris dans le cache partagé")
    func onlyCrisperWhisperModels() {
        let hub = "/Users/quelquun/.cache/huggingface/hub/"
        let expected = ["small", "medium", "turbo", "large"].flatMap { variant in
            ["\(hub)models--nyralabs--CrisperWhisper2.0_\(variant)",
             "\(hub).locks/models--nyralabs--CrisperWhisper2.0_\(variant)"]
        }
        #expect(Set(Self.paths(LegacyCleanup.modelLocations(home: Self.home)))
                == Set(expected))
    }

    /// Le dossier de support n'est jamais jeté d'un bloc, et l'historique des
    /// transcriptions n'y vit pas : il est dans les réglages.
    @Test("Le dossier de support n'est jamais visé en entier")
    func neverTargetsSupportDirectory() {
        let support = LegacyCleanup.supportDirectory(home: Self.home).path
        let all = LegacyCleanup.engineLocations(home: Self.home, project: nil)
            + LegacyCleanup.modelLocations(home: Self.home)
            + LegacyCleanup.otherLocations(home: Self.home)
        #expect(!Self.paths(all).contains(support))
    }

    @Test("Le descripteur se relit sans le type qui l'écrivait")
    func readsDescriptor() {
        let data = Data("""
            {"model":"turbo","project":"/Users/quelquun/.caspr/engine","uv":"/opt/homebrew/bin/uv"}
            """.utf8)
        #expect(LegacyCleanup.engineProject(descriptor: data)
                == "/Users/quelquun/.caspr/engine")
        #expect(LegacyCleanup.engineProject(descriptor: Data("{".utf8)) == nil)
    }

    @Test("Un dossier qui ne contient que des miettes est vide ; un fichier, non")
    func effectiveEmptiness() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "caspr-vide-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appending(path: "a/b"),
                               withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: ".DS_Store"))
        #expect(LegacyCleanup.isEffectivelyEmpty(root))

        try Data("x".utf8).write(to: root.appending(path: "a/b/reste.txt"))
        #expect(!LegacyCleanup.isEffectivelyEmpty(root))
        #expect(!LegacyCleanup.isEffectivelyEmpty(root.appending(path: "absent")))
    }
}
