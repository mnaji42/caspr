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
/// règlent plus rien — sauf le lexique, écrit mot à mot par l'utilisateur : ses
/// mots partent d'abord à la corbeille, dans « Caspr — ancien lexique.txt ».
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
    /// à sa création. Créée avant, elle lirait la voie avant qu'elle ait été
    /// déduite de l'interrupteur du relais, et dicterait par macOS quelqu'un
    /// qui avait choisi ChatGPT.
    static func run() {
        // Un binaire lancé hors de son bundle — `swift run`, un test — lit un
        // autre domaine de réglages, et n'a aucune raison de vider les
        // dossiers de l'application installée.
        guard Bundle.main.bundleIdentifier == bundleIdentifier else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser

        disarmAgents(home: home)
        migrateSettings(home: home)

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

    private static func migrateSettings(home: URL) {
        let defaults = UserDefaults.standard
        // Le lexique n'est effacé qu'une fois sa copie dans la corbeille ;
        // sinon il reste, et le lancement suivant retente la copie.
        var keep: Set<String> = []
        if let words = LegacyCleanup.lexiconBackup(defaults),
           !trashLexicon(words, home: home) {
            keep.insert(LegacyCleanup.lexiconKey)
        }
        let done = LegacyCleanup.migrateSettings(defaults, keep: keep)
        for line in done { Log.notice("migration : \(line)") }
        // La voie est posée ici, une fois, et non déduite par `Preferences` à
        // chaque lecture : l'interrupteur du relais ne serait jamais devenu
        // muet, et il écraserait tout choix fait depuis.
        if let voie = VoieDeDictee.migrer(defaults) {
            Log.notice("migration : voie de dictée posée — \(voie.rawValue)")
        }
    }

    /// Écrit les mots du lexique dans un fichier texte, puis met ce fichier à
    /// la corbeille : c'est là que l'utilisateur cherchera ce que la mise à
    /// jour a retiré, à côté du corpus. Quelques octets, d'où le synchrone.
    private static func trashLexicon(_ words: String, home: URL) -> Bool {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "Caspr — ancien lexique.txt")
        do {
            try words.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            Log.error("migration : ancien lexique non copié, gardé jusqu'au "
                      + "prochain lancement — \(error.localizedDescription)")
            return false
        }
        return trash(LegacyCleanup.Location(file, "ancien lexique"), home: home)
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
