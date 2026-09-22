import Foundation
import CasprCore

/// Défait ce que la pile locale, le corpus et l'ancien nom ont laissé sur la
/// machine.
///
/// Depuis septembre 2026, Caspr ne dicte plus que de deux façons : avec macOS,
/// ou avec ChatGPT. Le code de l'ancien moteur local — CrisperWhisper — est
/// parti, et c'est justement pour ça que cette migration a été écrite
/// **avant** : sans elle, plus aucun code ne saurait arrêter un démon qui se
/// relance tout seul à chaque ouverture de session.
///
/// ## Pas de drapeau
///
/// Elle repasse à chaque lancement, et ne fait quelque chose que s'il reste
/// quelque chose à faire. Un drapeau posé une fois aurait deux défauts : une
/// corbeille refusée un jour (disque plein, dossier verrouillé) ne serait
/// jamais retentée, et un agent réinstallé après coup — par une ancienne
/// version relancée depuis une sauvegarde — ne serait jamais retiré. Le prix
/// est une poignée de `fileExists` par lancement.
///
/// ## Corbeille, jamais suppression
///
/// Ce qui part est gros et, pour le corpus, irremplaçable. Personne n'a cliqué
/// sur quoi que ce soit : une corbeille se rouvre, un `removeItem` non. Seuls
/// les réglages sont effacés pour de bon, et ce ne sont que des clés qui ne
/// règlent plus rien.
///
/// Les règles qui décident de *quoi* part vivent dans
/// `CasprCore/LegacyCleanup.swift`, sous tests. Ici, seulement les gestes.
@MainActor
enum Migration {
    private static let bundleIdentifier = "fr.lyriastudio.caspr"
    private static let previousBundleIdentifier = "fr.lyriastudio.sofler"

    /// À appeler au lancement, **avant la première lecture de
    /// `Preferences.shared`**.
    ///
    /// L'ordre n'est pas une précaution : `Preferences` lit ses clés une fois,
    /// à sa création. Créée avant, elle lirait la version de macOS avant que
    /// celle-ci ait remplacé l'ancien moteur, et retomberait sur un défaut
    /// plutôt que sur la version mesurée ici.
    static func run() {
        // Un binaire lancé hors de son bundle — `swift run`, un test — lit un
        // autre domaine de réglages, et n'a aucune raison de vider les
        // dossiers de l'application installée.
        guard Bundle.main.bundleIdentifier == bundleIdentifier else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser

        disarmAgents(home: home)
        migrateSettings()

        // Décidé ici, sur l'acteur principal, parce que c'est une lecture de
        // réglages ; le geste, lui, part avec le reste.
        let soflerPreferences = retirableSoflerPreferences(home: home)
        // Des gigaoctets à déplacer, sur un disque qui peut être lent : rien de
        // tout ça ne mérite de retarder l'apparition de l'icône.
        Task.detached(priority: .utility) {
            sweep(home: home, soflerPreferences: soflerPreferences)
        }
    }

    // MARK: - Le démon

    /// Synchrone, parce que c'est la priorité et que c'est court : le démon
    /// doit être sorti avant que quoi que ce soit touche aux fichiers qu'il
    /// tient ouverts.
    private static func disarmAgents(home: URL) {
        for label in LegacyCleanup.agentLabels {
            let plist = LegacyCleanup.agentPlist(label, home: home)
            guard FileManager.default.fileExists(atPath: plist.path) else { continue }
            // Un statut non nul veut dire, presque toujours, que l'agent
            // n'était pas chargé : ce n'est pas une raison de garder le plist,
            // qui le rechargerait à la prochaine ouverture de session.
            let status = launchctl(["bootout", "gui/\(getuid())/\(label)"])
            Log.notice("migration : agent \(label) sorti de launchd (statut \(status))")
            trash(LegacyCleanup.Location(plist, "agent \(label)"), home: home)
        }
    }

    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Les réglages

    private static func migrateSettings() {
        let defaults = UserDefaults.standard
        let done = LegacyCleanup.migrateSettings(defaults) {
            appleTechnology(defaults)
        }
        for line in done { Log.notice("migration : \(line)") }
    }

    /// La version de macOS qui remplace CrisperWhisper.
    ///
    /// `systemEngine` rend `nil` précisément là où CrisperWhisper avait le plus
    /// de raisons d'avoir été choisi : Mac Intel, machine virtuelle, Mac sans
    /// Apple Intelligence. La Dictée en dernier recours, parce que c'est elle
    /// qui marche partout où la dictée du système marche. Si même elle ne
    /// marche pas ici, la migration ne ment pas pour autant : elle pose le
    /// réglage, et c'est l'accueil qui dit ce qui manque.
    private static func appleTechnology(_ defaults: UserDefaults) -> String {
        let current = defaults.string(forKey: LegacyCleanup.Key.appleTechnology)
            .flatMap(EngineChoice.init(rawValue:)) ?? .apple
        let chosen = EngineChoice.systemEngine(preferring: current,
                                               for: primaryLanguage(defaults))
        return (chosen ?? .appleLegacy).rawValue
    }

    /// La langue principale, relue comme `Preferences` la relit — sans passer
    /// par elle, qui ne doit pas encore exister.
    private static func primaryLanguage(_ defaults: UserDefaults) -> String {
        let selected = defaults.stringArray(forKey: "caspr.languages.selected") ?? []
        if let primary = defaults.string(forKey: "caspr.languages.primary"),
           selected.contains(primary) {
            return primary
        }
        if let first = selected.first { return first }
        if let legacy = defaults.string(forKey: "caspr.language") {
            return Language.preferred(for: legacy)
        }
        return Language.fallback
    }

    /// Le domaine de réglages de Sofler, si plus rien n'en a besoin.
    ///
    /// Le renommage le laissait exprès, pour pouvoir revenir en arrière à la
    /// main. Il ne part qu'une fois que Caspr a ses propres réglages : c'est
    /// qu'ils ont été repris, ou qu'on s'en est passé.
    private static func retirableSoflerPreferences(home: URL) -> URL? {
        let defaults = UserDefaults.standard
        guard let current = defaults.persistentDomain(forName: bundleIdentifier),
              !current.isEmpty else { return nil }
        let file = home.appending(
            path: "Library/Preferences/\(previousBundleIdentifier).plist")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    // MARK: - Les fichiers

    nonisolated private static func sweep(home: URL, soflerPreferences: URL?) {
        let descriptor = LegacyCleanup.engineDescriptor(home: home)
        let project = (try? Data(contentsOf: descriptor))
            .flatMap(LegacyCleanup.engineProject(descriptor:))

        let engine = LegacyCleanup.engineLocations(home: home, project: project)
        var engineGone = true
        for location in engine where !trash(location, home: home) {
            engineGone = false
        }
        if let project {
            let path = URL(fileURLWithPath: project).standardizedFileURL.path
            let owned = engine.contains {
                let root = $0.url.standardizedFileURL.path
                return path == root || path.hasPrefix(root + "/")
            }
            if !owned {
                Log.notice("migration : moteur installé dans un dépôt de travail "
                           + "(\(display(URL(fileURLWithPath: path), home: home))) "
                           + "— laissé en place")
            }
        }
        // Le descripteur est la seule trace de l'endroit où le dépôt cloné a
        // été mis. Tant que celui-ci n'est pas parti, on le garde : le
        // lancement suivant saura encore quoi retenter.
        if engineGone {
            trash(LegacyCleanup.Location(descriptor, "déclaration du moteur"), home: home)
        }

        for location in LegacyCleanup.modelLocations(home: home)
            + LegacyCleanup.otherLocations(home: home) {
            trash(location, home: home)
        }
        if let soflerPreferences {
            trash(LegacyCleanup.Location(soflerPreferences, "réglages de Sofler"),
                  home: home)
        }

        // Le dossier de support, une fois ses occupants partis. Sans lui, une
        // coquille vide resterait, et avec elle l'impression tenace, en
        // rouvrant le Finder, que quelque chose n'est pas parti.
        let support = LegacyCleanup.supportDirectory(home: home)
        if LegacyCleanup.isEffectivelyEmpty(support) {
            trash(LegacyCleanup.Location(support, "dossier de Caspr"), home: home)
        }
    }

    /// Rend vrai quand il ne reste rien à cet endroit.
    @discardableResult
    nonisolated private static func trash(_ location: LegacyCleanup.Location,
                                          home: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: location.url.path) else { return true }
        let place = display(location.url, home: home)
        do {
            try fm.trashItem(at: location.url, resultingItemURL: nil)
            Log.notice("migration : \(location.label) mis à la corbeille — \(place)")
            return true
        } catch {
            Log.error("migration : \(location.label) non retiré, retenté au "
                      + "prochain lancement — \(place) : \(error.localizedDescription)")
            return false
        }
    }

    /// Le chemin tel qu'on le lit, et sans le nom du compte : le journal est
    /// public.
    nonisolated private static func display(_ url: URL, home: URL) -> String {
        let path = url.path
        return path.hasPrefix(home.path)
            ? "~" + path.dropFirst(home.path.count)
            : path
    }
}
