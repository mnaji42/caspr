import AppKit
import Foundation
import ServiceManagement
import CasprCore

/// Ce que Caspr a déposé sur la machine, et comment le retirer.
///
/// Une application qui demande le micro, l'accessibilité et le droit de
/// démarrer toute seule doit savoir partir. Sans ça, désinstaller veut dire
/// glisser un bundle à la corbeille et laisser derrière soi une session
/// ChatGPT connectée et des autorisations accordées à quelque chose qui
/// n'existe plus.
///
/// ## Les restes de l'ancien moteur local
///
/// Caspr n'installe plus rien de lui-même. Mais jusqu'en septembre 2026 il
/// savait installer un moteur local : un service lancé à l'ouverture de
/// session, un environnement Python, des poids de un à trois gigaoctets.
/// `Migration` les met à la corbeille au lancement ; ce désinstalleur garde
/// pourtant de quoi les retirer, parce qu'il est le filet de qui n'aurait
/// jamais lancé la version qui migre — une copie ancienne remplacée à la main,
/// par exemple. Ces trois lignes n'apparaissent **que si** quelque chose
/// reste sur le disque ; chez tous les autres, la fenêtre ne les montre pas.
/// Les emplacements viennent de `LegacyCleanup`, la même table que la
/// migration.
///
/// **Rien n'est effacé définitivement : tout part à la corbeille.** C'est la
/// convention de macOS, et surtout c'est ce qui sépare une erreur d'un
/// désastre. Un `rm -rf` mal coché serait irréversible ; une corbeille se
/// rouvre.
///
/// `@MainActor` parce que tout ce que ce type interroge l'est — les
/// autorisations, l'historique — et qu'il n'est appelé que par une
/// fenêtre. Les lectures de disque qu'il fait sont courtes et ponctuelles :
/// les sortir du fil principal compliquerait sans rien gagner.
@MainActor
enum Uninstall {

    // MARK: - Ce qui peut être retiré

    enum Item: String, CaseIterable, Identifiable {
        case settings
        case permissions
        case service
        case engine
        case logs
        case model

        var id: String { rawValue }

        var label: String {
            switch self {
            case .settings: "Réglages et historique"
            case .permissions: "Autorisations micro, accessibilité, dictée"
            case .service: "Ancien moteur local — service"
            case .engine: "Ancien moteur local — Python et ses bibliothèques"
            case .logs: "Journaux et fichiers temporaires"
            case .model: "Ancien moteur local — modèle"
            }
        }

        var explanation: String {
            switch self {
            case .settings:
                "Votre raccourci, vos langues, vos préférences et les "
                    + "transcriptions récentes."
            case .permissions:
                "Retire Caspr des Réglages Système — micro, accessibilité et "
                    + "reconnaissance vocale. Sans ça, il y reste listé alors "
                    + "qu'il n'existe plus."
            case .service:
                "Le service qu'une ancienne version de Caspr lançait à "
                    + "l'ouverture de session. Plus rien ne s'en sert."
            case .engine:
                // « Python » inquiète à juste titre : il faut dire lequel part,
                // et surtout lesquels ne partent pas.
                "L'environnement Python qu'une ancienne version de Caspr avait "
                    + "installé — torch, transformers et l'outil `uv`, **dans "
                    + "le dossier de Caspr** et nulle part ailleurs. Ni le "
                    + "Python de votre système, ni celui de Homebrew, ni les "
                    + "versions que `uv` garde pour vos autres projets ne sont "
                    + "touchés. Plus rien ne s'en sert ; le retirer libère plus "
                    + "d'un gigaoctet."
            case .logs:
                "Sans valeur une fois l'application partie."
            case .model:
                "Les poids que l'ancien moteur local avait téléchargés depuis "
                    + "Hugging Face. Seuls les siens : les autres modèles du "
                    + "cache Hugging Face ne sont pas touchés. Plus rien ne "
                    + "s'en sert."
            }
        }

        /// Coché d'avance ?
        ///
        /// Ce qui ne sert plus à rien, oui : le service et les poids de
        /// l'ancien moteur local ne servent à aucune version de Caspr.
        /// L'environnement Python, non : sur une machine de développement, il
        /// vit dans le dépôt de travail, où l'on s'en sert encore pour
        /// relancer l'ancien moteur à la main.
        var checkedByDefault: Bool {
            switch self {
            case .settings, .permissions, .service, .logs, .model: true
            case .engine: false
            }
        }
    }

    // MARK: - Emplacements

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static let bundleIdentifier = "fr.lyriastudio.caspr"

    /// Le bundle à retirer : celui qui est installé, pas la copie fantôme.
    ///
    /// Trouvé par l'application elle-même et non à un chemin écrit en dur —
    /// elle peut vivre dans ~/Applications. Mais `Bundle.main.bundleURL` ne
    /// suffit pas : tant qu'une application est en quarantaine, macOS
    /// l'exécute depuis une copie temporaire montée en lecture seule, et
    /// c'est *elle* que cette propriété désigne.
    ///
    /// Le symptôme observé est sans ambiguïté :
    ///
    ///     « Caspr » couldn't be moved to the trash because the volume
    ///     « BBBD2386-… » doesn't have one.
    ///
    /// Ce volume-là n'a effectivement pas de corbeille. Et même s'il en avait
    /// eu une, on aurait jeté le fantôme : l'application réellement installée
    /// serait restée en place pendant que la fenêtre annonçait « Caspr est
    /// désinstallé ». Un désinstalleur qui ment est pire qu'absent.
    static var appBundle: URL {
        let running = Bundle.main.bundleURL
        guard running.path.contains("/AppTranslocation/") else { return running }
        return original(of: running) ?? running
    }

    /// Remonte d'une copie translocalisée vers l'application d'origine.
    private static func original(of translocated: URL) -> URL? {
        // `SecTranslocateCreateOriginalPathForURL` existe depuis macOS 10.12
        // mais n'apparaît pas dans la surcouche Swift du framework Security.
        // On va la chercher au chargement plutôt que de deviner : elle rend le
        // chemin exact, y compris pour une application lancée depuis les
        // Téléchargements ou une clé USB, là où une liste d'emplacements
        // probables se tromperait.
        typealias Resolve = @convention(c)
            (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "SecTranslocateCreateOriginalPathForURL") {
            let resolve = unsafeBitCast(symbol, to: Resolve.self)
            if let url = resolve(translocated as CFURL, nil)?
                .takeRetainedValue() as URL?,
               url.path != translocated.path,
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        // Repli, si le symbole venait à disparaître d'une version de macOS :
        // les deux seuls endroits où une application s'installe.
        let name = translocated.lastPathComponent
        return [URL(fileURLWithPath: "/Applications/\(name)"),
                home.appending(path: "Applications/\(name)")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Caspr tourne-t-il depuis un support en lecture seule ?
    ///
    /// C'est le cas quand on double-clique l'application **dans la fenêtre de
    /// l'image disque** au lieu de la glisser dans Applications d'abord — de
    /// loin l'erreur la plus fréquente sur macOS, et vérifiée trois fois ici.
    /// Rien n'est alors installé : le désinstalleur n'a pas échoué, il n'avait
    /// rien à retirer. Le message « le volume n'a pas de corbeille » décrivait
    /// la conséquence, jamais la cause.
    static var runsFromReadOnlyVolume: Bool {
        let values = try? appBundle.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly ?? false
    }

    private static var preferencesFile: URL {
        home.appending(path: "Library/Preferences/\(bundleIdentifier).plist")
    }
    /// Ne contient plus, chez qui l'avait installé, que la déclaration et
    /// l'environnement de l'ancien moteur local.
    ///
    /// Il n'est jamais retiré d'un bloc : ce qu'il contient appartient à des
    /// cases différentes, et un fichier que cette version ne connaît pas n'a
    /// pas à partir sans qu'on l'ait coché. Le dossier lui-même s'en va à la
    /// fin, s'il ne reste rien dedans.
    private static var supportDirectory: URL {
        LegacyCleanup.supportDirectory(home: home)
    }

    /// La déclaration que l'installation de l'ancien moteur local laissait :
    /// elle dit où vit son environnement Python.
    private static var engineDescriptor: URL {
        LegacyCleanup.engineDescriptor(home: home)
    }

    /// Ce que l'installation de l'ancien moteur local a laissé sur la machine.
    ///
    /// Déduit du descripteur, jamais d'un chemin écrit en dur — et la
    /// distinction n'est pas cosmétique ici. Se tromper d'emplacement dans un
    /// désinstalleur ne produit pas un message d'erreur : ça met à la
    /// corbeille le dossier de quelqu'un d'autre.
    ///
    /// D'où la règle sur le dépôt cloné : il ne part **que** s'il se trouve
    /// exactement là où la commande d'installation le met, `~/.caspr`. Sur
    /// une machine de développement, `project` désigne le dépôt de travail ;
    /// en remonter d'un cran et le jeter effacerait le code source et tout ce
    /// qui n'y est pas encore commité. Dans ce cas seul l'environnement
    /// Python s'en va — c'est lui qui pèse, et lui seul se régénère.
    ///
    /// Plus large que `LegacyCleanup.engineLocations`, qui ne touche jamais un
    /// dépôt de travail : la migration agit sans que personne l'ait demandé,
    /// ce désinstalleur agit sur une case cochée.
    private static var enginePaths: [(url: URL, label: String)] {
        let fm = FileManager.default
        var found: [(URL, String)] = []

        // L'outil, quand c'est Caspr qui l'a récupéré. Celui de Homebrew
        // n'est jamais touché : il n'appartient pas à cette application, et
        // d'autres projets s'en servent.
        let tool = supportDirectory.appending(path: "tools")
        if fm.fileExists(atPath: tool.path) { found.append((tool, "uv")) }

        guard let project = (try? Data(contentsOf: engineDescriptor))
            .flatMap(LegacyCleanup.engineProject(descriptor:))
        else { return found }
        let projectURL = URL(fileURLWithPath: project).standardizedFileURL

        // Installation faite depuis l'application : tout tient dans un dossier
        // qui n'appartient qu'à Caspr, code et environnement compris.
        let own = supportDirectory.appending(path: "engine").standardizedFileURL
        if projectURL.path == own.path, fm.fileExists(atPath: own.path) {
            found.append((own, "moteur Python"))
            return found
        }

        // Installation faite au Terminal, du temps où c'était la seule voie.
        // Le dépôt cloné ne part que s'il est exactement là où la commande le
        // mettait — comparé par `path`, jamais comme deux `URL` :
        // `deletingLastPathComponent()` rend « …/.caspr/ » quand
        // `appending(path:)` rend « …/.caspr », et l'égalité d'URL porte sur
        // la chaîne entière, barre oblique comprise. Le test échouait donc
        // toujours, et le dépôt d'un utilisateur survivait à la case qui
        // promettait de le retirer.
        let clone = projectURL.deletingLastPathComponent()
        let canonical = home.appending(path: ".caspr").standardizedFileURL
        if clone.path == canonical.path, fm.fileExists(atPath: clone.path) {
            found.append((clone, "moteur Python"))
            return found
        }

        // Dépôt de travail d'un développeur : seul l'environnement s'en va.
        // Remonter d'un cran et jeter le dossier parent effacerait le code
        // source et tout ce qui n'y est pas commité.
        let venv = projectURL.appending(path: ".venv")
        if fm.fileExists(atPath: venv.path) {
            found.append((venv, "bibliothèques Python du moteur"))
        }
        return found
    }
    private static var logsDirectory: URL {
        home.appending(path: "Library/Logs/Caspr")
    }
    /// Les caches, aux trois endroits où ils atterrissent.
    ///
    /// `Library/Caches/caspr` est celui que l'application crée elle-même. Les
    /// deux autres, macOS les fabrique dans son dos, sous l'identifiant de
    /// bundle : un dossier de cache dès qu'une API système en demande un, et
    /// `HTTPStorages` à la première requête réseau — c'est-à-dire dès la
    /// première vérification de mise à jour. Ni l'un ni l'autre n'était retiré,
    /// et un balayage après désinstallation les retrouvait tous les deux.
    private static var cacheDirectories: [URL] {
        [home.appending(path: "Library/Caches/caspr"),
         home.appending(path: "Library/Caches/\(bundleIdentifier)"),
         home.appending(path: "Library/HTTPStorages/\(bundleIdentifier)")]
    }
    /// RELAIS — la session ChatGPT du relais.
    ///
    /// WebKit range les cookies d'une `WKWebView` sous l'identifiant de bundle,
    /// hors du bundle lui-même : retirer l'application laissait donc derrière
    /// elle une session **connectée** au compte de l'utilisateur. C'est
    /// précisément ce que ce désinstalleur existe pour éviter, et ça ne se
    /// voyait nulle part — le dossier ne porte pas le mot « Caspr » et aucun
    /// écran ne le mentionne.
    ///
    /// Retirée avec les réglages plutôt que sous un élément à elle : c'est de
    /// l'état applicatif, et lui donner sa propre case exposerait dans le
    /// désinstalleur une fonctionnalité qui doit rester facile à retrancher.
    private static var relaisSession: URL {
        home.appending(path: "Library/WebKit/\(bundleIdentifier)")
    }

    /// L'agent launchd de l'ancien moteur local — le premier des deux labels,
    /// l'autre étant celui de Sofler, que `Rebranding` retire déjà.
    private static var serviceLabel: String { LegacyCleanup.agentLabels[0] }

    private static var launchAgent: URL {
        LegacyCleanup.agentPlist(serviceLabel, home: home)
    }
    /// Uniquement les poids de l'ancien moteur local, variante par variante,
    /// avec leurs verrous. Le cache Hugging Face est partagé avec tout autre
    /// projet qui utilise la bibliothèque : l'effacer en entier ferait
    /// retélécharger des gigaoctets qui ne nous appartiennent pas.
    private static var modelLocations: [LegacyCleanup.Location] {
        LegacyCleanup.modelLocations(home: home)
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Ce que l'élément occupe, prêt à afficher. Vide s'il n'y a rien.
    static func detail(for item: Item) -> String {
        switch item {
        case .settings:
            let entries = TranscriptionHistory.storedCount
            let base = entries > 0 ? "\(entries) transcription(s) récente(s)" : "réglages seuls"
            // RELAIS — la session est dite, pas seulement retirée.
            //
            // Elle partait déjà avec les réglages, mais en silence : personne
            // ne devine qu'une case « Réglages et historique » décide aussi
            // d'une session ouverte sur un service tiers. Or c'est
            // l'information qui compte le plus dans cet écran — laisser
            // derrière soi un compte connecté est précisément ce qu'on vient y
            // éviter, et une suppression qu'on ne voit pas ne rassure personne.
            guard FileManager.default.fileExists(atPath: relaisSession.path) else { return base }
            return base + ", session ChatGPT connectée"
        case .permissions:
            return Permissions.allGranted ? "accordées" : "partiellement accordées"
        case .service:
            return FileManager.default.fileExists(atPath: launchAgent.path)
                ? "installé" : "non installé"
        case .engine:
            let paths = enginePaths
            guard !paths.isEmpty else { return "déclaration seule" }
            return size(of: paths.map(\.url))
        case .logs:
            return size(of: [logsDirectory] + cacheDirectories)
        case .model:
            return size(of: modelLocations.map(\.url))
        }
    }

    /// L'élément a-t-il quelque chose à retirer ? Sinon la fenêtre ne le
    /// propose pas.
    static func isPresent(_ item: Item) -> Bool {
        let fm = FileManager.default
        switch item {
        case .settings: return fm.fileExists(atPath: preferencesFile.path)
        case .permissions: return true
        case .service: return fm.fileExists(atPath: launchAgent.path)
        case .engine:
            return !enginePaths.isEmpty
                || fm.fileExists(atPath: engineDescriptor.path)
        case .logs:
            return fm.fileExists(atPath: logsDirectory.path)
                || cacheDirectories.contains { fm.fileExists(atPath: $0.path) }
        case .model: return !modelLocations.isEmpty
        }
    }

    // MARK: - Exécution

    /// Retire ce qui est demandé, puis l'application elle-même.
    ///
    /// - Returns: le compte rendu, ligne par ligne. Affiché avant de quitter :
    ///   quelqu'un qui désinstalle veut la preuve que c'est fait, pas une
    ///   fenêtre qui disparaît.
    static func perform(_ items: Set<Item>) -> [String] {
        var report: [String] = []

        // Le service se relancerait tout seul : il part en premier, avant les
        // fichiers dont il dépend.
        if items.contains(.service) {
            runTool("/bin/launchctl",
                    ["bootout", "gui/\(getuid())/\(serviceLabel)"])
            report.append(trash(launchAgent, "service de l'ancien moteur local"))
        }

        // Après le service, qui s'exécutait depuis cet environnement Python :
        // le sortir d'abord évite de retirer le sol sous un processus vivant.
        if items.contains(.engine) {
            for path in enginePaths {
                report.append(trash(path.url, path.label))
            }
            // Le descripteur part avec le moteur qu'il décrit. Laissé seul, il
            // survivait à toute désinstallation raisonnable — et une
            // réinstallation retrouvait une déclaration pointant vers un
            // moteur qui n'existait plus.
            report.append(trash(engineDescriptor, "déclaration du moteur"))
        }

        if items.contains(.logs) {
            report.append(trash(logsDirectory, "journaux"))
            // Un seul compte rendu pour les trois emplacements : leur nombre
            // est un détail d'implémentation de macOS, pas une information
            // que quelqu'un attend en désinstallant.
            let manager = FileManager.default
            let present = cacheDirectories.filter {
                manager.fileExists(atPath: $0.path)
            }
            for cache in present {
                try? manager.trashItem(at: cache, resultingItemURL: nil)
            }
            report.append(present.isEmpty
                ? "· fichiers temporaires — rien à retirer"
                : "✓ fichiers temporaires — mis à la corbeille")
        }

        if items.contains(.model) {
            // Un dossier et un verrou par variante : autant de lignes
            // identiques, qu'une seule suffit à dire.
            let lines = modelLocations.map {
                trash($0.url, "modèle de l'ancien moteur local")
            }
            report.append(contentsOf: Set(lines).sorted())
        }

        if items.contains(.settings) {
            report.append(trash(preferencesFile, "réglages et historique"))
            // RELAIS — la session ChatGPT part avec les réglages.
            //
            // L'effacement par l'API de WebKit a déjà eu lieu, avant l'appel
            // (cf. `UninstallWindow`) : le magasin d'une WKWebsiteDataStore n'a
            // pas d'emplacement contractuel, une partie vit dans des processus
            // annexes, et supprimer les fichiers sous un WebKit encore vivant
            // laisse la session revenir. Ce balayage-ci ne ramasse que ce qui
            // pourrait rester derrière.
            if FileManager.default.fileExists(atPath: relaisSession.path) {
                report.append(trash(relaisSession, "session ChatGPT du relais"))
            }
            // Le démon de préférences en garde une copie en mémoire et
            // réécrirait le fichier qu'on vient de retirer.
            runTool("/usr/bin/killall", ["cfprefsd"])
        }

        if items.contains(.permissions) {
            // « SpeechRecognition » depuis que la version Dictée du moteur de
            // macOS existe : macOS la compte comme un droit distinct du micro,
            // et la laisser accordée à une application retirée est exactement
            // ce que ce désinstalleur existe pour éviter.
            //
            // Et c'est **tout** ce que les moteurs de macOS laissent derrière
            // eux, vérifié version par version. Leurs modèles de
            // reconnaissance n'appartiennent pas à Caspr : ceux de la Dictée
            // sont installés par Réglages Système › Clavier › Dictée et
            // servent à la dictée du système, ceux d'Apple Intelligence sont
            // des actifs partagés par toutes les applications qui les
            // demandent. Les retirer priverait l'utilisateur d'une
            // fonctionnalité de macOS qu'il n'a jamais installée pour nous.
            // Reste la locale réservée auprès d'`AssetInventory` : elle est
            // rattachée à l'application, plafonnée à une seule à la fois
            // (cf. `LivePreview.reserve`), et disparaît avec elle.
            for service in ["Microphone", "Accessibility", "SpeechRecognition"] {
                runTool("/usr/bin/tccutil", ["reset", service, bundleIdentifier])
            }
            report.append("✓ autorisations révoquées")
        }

        // Le dossier de support lui-même, une fois ses occupants partis.
        // Sans ce balayage, une désinstallation complète laisserait une
        // coquille vide, un dossier `backups` que plus rien n'écrit et un
        // `.DS_Store` — c'est-à-dire l'impression tenace, en rouvrant le
        // Finder, que quelque chose n'est pas parti.
        if LegacyCleanup.isEffectivelyEmpty(supportDirectory) {
            report.append(trash(supportDirectory, "dossier de Caspr"))
        }

        // Jamais optionnel. Laissé en place, macOS tenterait de lancer une
        // application supprimée à chaque ouverture de session, et se
        // plaindrait de ne pas la trouver.
        do {
            try SMAppService.mainApp.unregister()
            report.append("✓ retiré des ouvertures de session")
        } catch {
            // Pas inscrit : il n'y a rien à défaire, ce n'est pas un échec.
        }

        // En dernier : le code qui s'exécute vit dedans. Il reste chargé en
        // mémoire, donc la fenêtre survit assez pour afficher ce compte rendu.
        if runsFromReadOnlyVolume {
            report.append("· application — rien à retirer : elle tourne depuis "
                          + "l'image disque, elle n'a jamais été installée")
        } else {
            report.append(trash(appBundle, "application"))
        }
        return report
    }

    // MARK: - Outils

    /// Corbeille, jamais suppression. Voir l'en-tête du fichier.
    private static func trash(_ url: URL, _ label: String) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "· \(label) — rien à retirer"
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return "✓ \(label) — mis à la corbeille"
        } catch {
            return "✗ \(label) — \(error.localizedDescription)"
        }
    }

    private static func runTool(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func size(of urls: [URL]) -> String {
        var total: Int64 = 0
        for url in urls {
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            else { continue }
            for case let file as URL in walker {
                let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        guard total > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
