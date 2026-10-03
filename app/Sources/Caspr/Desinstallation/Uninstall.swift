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
/// `Migration` les retire à chaque lancement de cette version — celle-là même
/// qui ouvre ce désinstalleur. Il n'en reste donc que si une corbeille a
/// échoué, ou pendant les secondes que dure le balayage. Pour ce cas, une
/// seule ligne, et le même geste que la migration
/// (`Migration.retirerLesRestes`) : une seule politique de ce qui part, et
/// jamais le dépôt de travail d'un développeur.
///
/// **Rien n'est effacé définitivement : tout part à la corbeille.** C'est la
/// convention de macOS, et surtout c'est ce qui sépare une erreur d'un
/// désastre. Un `rm -rf` mal coché serait irréversible ; une corbeille se
/// rouvre.
///
/// `@MainActor` parce que tout ce que ce type interroge l'est — les
/// autorisations, l'historique — et qu'il n'est appelé que par une
/// fenêtre. Seules les tailles, qui parcourent des dossiers entiers, se
/// mesurent ailleurs (cf. `details`).
@MainActor
enum Uninstall {

    // MARK: - Ce qui peut être retiré

    enum Item: String, CaseIterable, Identifiable {
        case settings
        case permissions
        case caches
        case restes

        var id: String { rawValue }

        var label: String {
            switch self {
            case .settings: "Réglages et historique"
            case .permissions: "Autorisations micro, accessibilité, dictée"
            case .caches: "Fichiers temporaires"
            case .restes: "Restes de l'ancien moteur local"
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
            case .caches:
                "Le cache de la page ChatGPT, et ceux que macOS crée sous le "
                    + "nom de Caspr. Sans valeur une fois l'application partie."
            case .restes:
                // « Python » inquiète à juste titre : il faut dire lequel part,
                // et surtout lesquels ne partent pas.
                "Ce qu'une version d'avant septembre 2026 avait installé : un "
                    + "service, un environnement Python dans le dossier de Caspr "
                    + "ou dans `~/.caspr`, un modèle, des journaux. Caspr les "
                    + "retire de lui-même ; s'il en reste, c'est qu'un retrait a "
                    + "échoué. Ni le Python de votre système, ni celui de "
                    + "Homebrew, ni un dépôt de travail ne sont touchés."
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
    private static var supportDirectory: URL {
        LegacyCleanup.supportDirectory(home: home)
    }

    /// Les caches que macOS fabrique dans le dos de l'application, sous
    /// l'identifiant de bundle : un dossier de cache dès qu'une API système en
    /// demande un — le cache disque de la page ChatGPT y vit —, et
    /// `HTTPStorages` à la première requête réseau, c'est-à-dire dès la
    /// première vérification de mise à jour. Ni l'un ni l'autre n'était
    /// retiré, et un balayage après désinstallation les retrouvait tous les
    /// deux. Ceux de l'ancien moteur local et de l'ancien nom, Sofler, sont
    /// des restes (cf. `restes`).
    private static var cacheDirectories: [URL] {
        [home.appending(path: "Library/Caches/\(bundleIdentifier)"),
         home.appending(path: "Library/HTTPStorages/\(bundleIdentifier)")]
    }
    /// La session ChatGPT du relais.
    ///
    /// WebKit range les cookies d'une `WKWebView` sous l'identifiant de bundle,
    /// hors du bundle lui-même : retirer l'application laissait donc derrière
    /// elle une session **connectée** au compte de l'utilisateur. C'est
    /// précisément ce que ce désinstalleur existe pour éviter, et ça ne se
    /// voyait nulle part — le dossier ne porte pas le mot « Caspr » et aucun
    /// écran ne le mentionne.
    ///
    /// Deux emplacements : le magasin de WebKit, et le fichier de cookies
    /// que macOS range à côté du dossier `HTTPStorages` — ce dernier part avec
    /// les caches, son voisin `.binarycookies` restait, avec les cookies de
    /// chatgpt.com, d'auth.openai.com et de Google dedans. L'effacement par
    /// WebKit le vide, s'il a eu le temps d'atteindre le disque.
    ///
    /// Retirée avec les réglages plutôt que sous un élément à elle : c'est de
    /// l'état applicatif, comme l'historique, et `details()` la nomme
    /// (« session ChatGPT connectée ») pour que la case dise ce qu'elle
    /// emporte.
    private static var relaisSession: [URL] {
        [home.appending(path: "Library/WebKit/\(bundleIdentifier)"),
         home.appending(path: "Library/HTTPStorages/\(bundleIdentifier).binarycookies")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Ce que l'ancien moteur local a laissé et qui est encore là : la même
    /// table que la migration, qui les retire au lancement.
    private static var restes: [URL] {
        let descriptor = LegacyCleanup.engineDescriptor(home: home)
        let project = (try? Data(contentsOf: descriptor)).flatMap(LegacyCleanup.engineProject(descriptor:))
        let emplacements = LegacyCleanup.agentLabels.map { LegacyCleanup.agentPlist($0, home: home) }
            + [descriptor]
            + (LegacyCleanup.engineLocations(home: home, project: project)
                + LegacyCleanup.modelLocations(home: home)
                + LegacyCleanup.otherLocations(home: home)).map(\.url)
        return emplacements.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Ce que chaque élément occupe, prêt à afficher ; vide s'il n'y a rien.
    ///
    /// Mesuré une fois, à l'ouverture de la fenêtre, et hors du fil
    /// principal : les tailles parcourent des dossiers entiers, et la vue les
    /// redemandait à chaque case cochée.
    static func details() async -> [Item: String] {
        let entries = TranscriptionHistory.storedCount
        var settings = entries > 0 ? "\(entries) transcription(s) récente(s)" : "réglages seuls"
        // La session ChatGPT est dite, pas seulement retirée.
        //
        // Elle partait déjà avec les réglages, mais en silence : personne
        // ne devine qu'une case « Réglages et historique » décide aussi
        // d'une session ouverte sur un service tiers. Or c'est
        // l'information qui compte le plus dans cet écran — laisser
        // derrière soi un compte connecté est précisément ce qu'on vient y
        // éviter, et une suppression qu'on ne voit pas ne rassure personne.
        if !relaisSession.isEmpty {
            settings += ", session ChatGPT connectée"
        }
        let caches = cacheDirectories
        let restes = restes
        let (tailleCaches, tailleRestes) = await Task.detached(priority: .userInitiated) {
            (size(of: caches), size(of: restes))
        }.value
        return [.settings: settings,
                .permissions: Permissions.allGranted ? "accordées" : "partiellement accordées",
                .caches: tailleCaches,
                .restes: tailleRestes]
    }

    /// L'élément a-t-il quelque chose à retirer ? Sinon la fenêtre ne le
    /// propose pas.
    static func isPresent(_ item: Item) -> Bool {
        let fm = FileManager.default
        switch item {
        case .settings: return fm.fileExists(atPath: preferencesFile.path)
        case .permissions: return true
        case .caches: return cacheDirectories.contains { fm.fileExists(atPath: $0.path) }
        case .restes: return !restes.isEmpty
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

        // Le démon d'abord, puis ses fichiers : le geste de la migration.
        // Cochée d'avance même absente (cf. `UninstallView`) : sans rien à
        // retirer, rien à dire.
        if items.contains(.restes), isPresent(.restes) {
            report.append(Migration.retirerLesRestes(home: home)
                ? "✓ restes de l'ancien moteur local — mis à la corbeille"
                : "✗ restes de l'ancien moteur local — certains n'ont pas pu partir, "
                    + "voir le journal")
        }

        if items.contains(.caches) {
            // Un seul compte rendu pour les deux emplacements : leur nombre
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

        if items.contains(.settings) {
            report.append(trash(preferencesFile, "réglages et historique"))
            // La session ChatGPT part avec les réglages.
            //
            // L'effacement par l'API de WebKit a déjà eu lieu, avant l'appel
            // (cf. `UninstallWindow`) : le magasin d'une WKWebsiteDataStore n'a
            // pas d'emplacement contractuel, une partie vit dans des processus
            // annexes, et supprimer les fichiers sous un WebKit encore vivant
            // laisse la session revenir. Ce balayage-ci ne ramasse que ce qui
            // pourrait rester derrière.
            // Une ligne pour les deux emplacements, comme les caches ; un
            // échec passe devant, c'est lui qu'il faut lire.
            let session = relaisSession.map { trash($0, "session ChatGPT du relais") }
            if let ligne = session.first(where: { $0.hasPrefix("✗") }) ?? session.first {
                report.append(ligne)
            }
            // Le démon de préférences en garde une copie en mémoire et
            // réécrirait le fichier qu'on vient de retirer : on lui fait
            // oublier ce domaine-ci. Le tuer, comme on le faisait, tuait celui
            // de toutes les applications de la session. Après la corbeille, et
            // non avant : vidé d'abord, le fichier n'y aurait plus rien gardé.
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            CFPreferencesAppSynchronize(bundleIdentifier as CFString)
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
                Commande.executer("/usr/bin/tccutil", ["reset", service, bundleIdentifier])
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

    nonisolated private static func size(of urls: [URL]) -> String {
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
