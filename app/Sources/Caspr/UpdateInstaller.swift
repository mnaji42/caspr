import AppKit
import Foundation
import Observation
import Security

/// Télécharge la nouvelle version, la vérifie, remplace le bundle, relance.
///
/// `UpdateChecker` sait dire qu'une version existe ; il ne savait rien en
/// faire, sinon ouvrir la page GitHub. Ce qui suivait n'était pas une mise à
/// jour, c'était une réinstallation manuelle : trouver le bon fichier au
/// milieu des sources et des sommes de contrôle, monter l'image, glisser le
/// bundle, confirmer le remplacement, rouvrir l'application. Cinq gestes pour
/// une correction de bug — c'est-à-dire, en pratique, personne ne met à jour.
///
/// ## Pourquoi c'est plus sûr ici que le passage par le navigateur
///
/// Caspr n'est pas notarisé. Un .dmg récupéré par Safari reçoit l'attribut de
/// quarantaine, et Gatekeeper refuse la première ouverture avec un dialogue
/// qui parle de développeur non identifié — le README explique comment passer
/// outre. Ce détour apprend à contourner Gatekeeper, ce qui est exactement la
/// mauvaise habitude à donner.
///
/// Un téléchargement fait ici n'est pas mis en quarantaine (l'application
/// n'est pas en bac à sable et ne déclare pas `LSFileQuarantineEnabled`), et
/// surtout il est soumis à une vérification *plus stricte* que celle de
/// Gatekeeper : le nouveau bundle doit satisfaire l'**exigence désignée de la
/// copie qui tourne**, c'est-à-dire porter la signature du même certificat.
/// Un miroir hostile, une release compromise ou une archive substituée
/// échouent à ce test. Gatekeeper, lui, se contente de demander l'avis de
/// l'utilisateur.
///
/// ## Ce qui n'est pas fait
///
/// Aucune élévation de privilèges. Si le bundle vit dans un dossier que la
/// session ne peut pas écrire, l'installation intégrée est refusée et le
/// bouton du téléchargement manuel reste — plutôt qu'un dialogue
/// d'authentification administrateur au milieu d'une mise à jour, qui est la
/// forme exacte de ce qu'on apprend aux gens à ne jamais accepter.
@MainActor
@Observable
final class UpdateInstaller {
    static let shared = UpdateInstaller()

    /// Le nom du fichier attaché aux releases. Fixé par `package-dmg.sh`, qui
    /// le garde sans numéro de version pour que l'URL reste stable.
    static let assetName = "Caspr.dmg"

    enum Phase: Equatable {
        case idle
        /// Fraction téléchargée, entre 0 et 1.
        case downloading(Double)
        case verifying
        case installing
        /// Le bundle est remplacé ; il ne reste qu'à redémarrer.
        case relaunching
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Une opération est-elle en cours ? Sert à verrouiller le bouton — un
    /// second clic pendant le téléchargement monterait deux fois la même image.
    var isBusy: Bool {
        switch phase {
        case .idle, .failed: false
        default: true
        }
    }

    // MARK: - Préalables

    /// Ce qui empêche l'installation intégrée ici, ou `nil` si rien ne
    /// l'empêche.
    ///
    /// Vérifié **avant** d'afficher le bouton, pas au moment du clic : un
    /// bouton qui échoue toujours est pire que son absence, parce qu'il fait
    /// croire que la panne est passagère.
    ///
    /// Calculé une seule fois : ni le chemin du bundle ni sa signature ne
    /// changent pendant que le processus tourne, et c'est un `body` SwiftUI
    /// qui lit cette propriété — réévalué à chaque image, il y ferait sinon
    /// une lecture disque et un déchiffrement de signature par image.
    static let obstacle: String? = firstObstacle()

    private static func firstObstacle() -> String? {
        let bundle = Bundle.main.bundleURL
        let parent = bundle.deletingLastPathComponent()
        let fm = FileManager.default

        // macOS exécute une app encore en quarantaine depuis une copie
        // temporaire en lecture seule, à un chemin qui n'est pas celui qu'on
        // croit. Remplacer ce fantôme ne mettrait rien à jour : l'original
        // resterait où il est, et la copie disparaîtrait à la fermeture.
        if bundle.path.contains("/AppTranslocation/") {
            // Le cas de loin le plus fréquent n'est pas « pas encore
            // installée » : c'est installée, puis lancée depuis la fenêtre de
            // l'image disque, restée ouverte juste à côté. Dire « glissez-la
            // dans Applications » à quelqu'un qui vient précisément de le
            // faire, c'est lui laisser croire que son geste n'a pas pris.
            let name = bundle.lastPathComponent
            let elsewhere = ["/Applications/\(name)",
                             NSHomeDirectory() + "/Applications/\(name)"]
                .first { fm.fileExists(atPath: $0) }
            if let elsewhere {
                return "Cette fenêtre appartient à la copie restée dans "
                    + "l'image disque, pas à celle que vous avez installée — "
                    + "macOS l'exécute en lecture seule depuis un dossier "
                    + "temporaire. Quittez Caspr, éjectez l'image, puis "
                    + "ouvrez `\(elsewhere)`. Les autorisations que vous "
                    + "auriez accordées à cette copie-ci sont à revoir : elles "
                    + "ont été données à un chemin qui n'existera plus."
            }
            return "Caspr tourne depuis une copie temporaire, ce que macOS "
                + "fait tant que l'application n'a pas été déplacée dans "
                + "Applications. Glissez-la dans Applications, éjectez "
                + "l'image disque, et ouvrez la copie installée : la mise à "
                + "jour intégrée sera alors possible."
        }

        guard fm.isWritableFile(atPath: parent.path),
              fm.isDeletableFile(atPath: bundle.path) else {
            return "Ce compte n'a pas le droit d'écrire dans "
                + "\(parent.lastPathComponent). Passez par le téléchargement, "
                + "ou faites installer Caspr par un compte administrateur."
        }

        // Une signature ad hoc n'a pas de certificat : son exigence désignée
        // contient le hash du binaire, qui change à chaque version. Il n'y a
        // donc rien de stable à quoi comparer la nouvelle copie, et accepter
        // sans comparer reviendrait à exécuter ce que le réseau a bien voulu
        // rendre. Le cas est celui d'une release construite sans le certificat
        // de signature — cf. l'avertissement de release.yml.
        guard let requirement = designatedRequirementText() else {
            return "La signature de cette copie est illisible : impossible de "
                + "vérifier que la mise à jour vient de la même source."
        }
        if requirement.contains("cdhash") {
            return "Cette copie est signée ad hoc, sans certificat. Rien ne "
                + "permettrait de vérifier que la nouvelle version vient bien "
                + "du même auteur : la mise à jour doit passer par le "
                + "téléchargement."
        }
        return nil
    }

    /// L'exigence désignée de la copie qui tourne, sous forme lisible.
    private static func designatedRequirementText() -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL,
                                          [], &code) == errSecSuccess,
              let code else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess
        else { return nil }
        return text as String?
    }

    // MARK: - Installation

    /// Le chemin complet : téléchargement, vérification, remplacement, relance.
    ///
    /// La fonction ne rend la main que si quelque chose a échoué — au bout du
    /// chemin, l'application se termine pour se rouvrir dans sa nouvelle
    /// version.
    func install(_ release: UpdateChecker.Release) async {
        guard !isBusy else { return }
        guard let asset = release.asset else {
            phase = .failed("Cette release n'attache pas de \(Self.assetName) : "
                            + "il n'y a rien à installer automatiquement.")
            return
        }
        if let obstacle = Self.obstacle {
            phase = .failed(obstacle)
            return
        }

        let installed = Bundle.main.bundleURL
        // Le dossier de travail est privé à la session et effacé quoi qu'il
        // arrive : une mise à jour ratée ne doit pas laisser derrière elle
        // l'image disque qu'on venait de télécharger.
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "caspr-update-\(UUID().uuidString)")
        // Le bundle est préparé **à côté** de celui qu'il remplace, donc sur le
        // même volume : c'est la condition pour que l'échange final soit
        // atomique plutôt qu'une copie qu'une coupure de courant laisserait à
        // moitié faite. Le point initial le cache du Finder le temps que ça
        // dure.
        let staged = installed.deletingLastPathComponent()
            .appending(path: ".Caspr-\(UUID().uuidString).app")

        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: staged)
        }

        do {
            try FileManager.default.createDirectory(
                at: workspace, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])

            phase = .downloading(0)
            let dmg = workspace.appending(path: Self.assetName)
            try await Self.download(asset, to: dmg) { [weak self] fraction in
                // Le dernier avancement peut arriver après que l'étape
                // suivante a commencé : sans cette garde, l'affichage
                // repasserait de « vérification » à « téléchargement 100 % ».
                guard case .downloading = self?.phase else { return }
                self?.phase = .downloading(fraction)
            }

            phase = .verifying
            try await Self.extract(dmg: dmg, expecting: release.version,
                                   into: workspace, stagingAt: staged)

            phase = .installing
            try await Self.swap(staged, onto: installed)

            phase = .relaunching
            Log.info("update: \(UpdateChecker.currentVersion) → \(release.version)")
            Self.relaunch(installed)
        } catch {
            Log.error("update: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Efface un échec pour que le bouton redevienne cliquable.
    func reset() { phase = .idle }

    // MARK: - Téléchargement

    private nonisolated static func download(
        _ asset: UpdateChecker.Release.Asset,
        to destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        var request = URLRequest(url: asset.url)
        request.setValue("Caspr/\(currentVersionForHeader)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        // Le délai vaut pour l'inactivité, pas pour la durée totale : une
        // liaison lente est lente, ce n'est pas une panne. C'est le silence
        // qui en est une.
        request.timeoutInterval = 60

        try await AssetDownload(to: destination, progress: progress).run(request)

        let written = (try? FileManager.default.attributesOfItem(
            atPath: destination.path)[.size] as? Int64) ?? 0
        // GitHub annonce la taille de la pièce jointe : une divergence signale
        // un téléchargement tronqué que hdiutil rejetterait ensuite avec un
        // message beaucoup moins clair.
        if asset.size > 0, written != asset.size {
            throw Failure.truncated(received: written, expected: asset.size)
        }
    }

    /// Recopié plutôt qu'appelé sur `UpdateChecker` : cette fonction ne
    /// s'exécute pas sur le fil principal.
    private nonisolated static var currentVersionForHeader: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Ouverture de l'image et vérification

    /// Monte l'image, contrôle ce qu'elle contient, en dépose une copie prête à
    /// prendre la place de l'ancienne.
    ///
    /// Tout est vérifié **avant** que quoi que ce soit ne bouge dans
    /// Applications : à la sortie de cette fonction, ou bien `staged` contient
    /// un bundle authentifié, ou bien rien n'a été touché.
    private nonisolated static func extract(
        dmg: URL, expecting version: String, into workspace: URL, stagingAt staged: URL
    ) async throws {
        let mount = workspace.appending(path: "mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)

        let attach = run("/usr/bin/hdiutil",
                         ["attach", dmg.path, "-mountpoint", mount.path,
                          "-nobrowse", "-readonly", "-quiet"])
        guard attach.status == 0 else {
            throw Failure.mount(attach.error)
        }
        defer {
            // `-force` en second essai : hdiutil refuse de détacher un volume
            // qu'un indexeur vient d'ouvrir dans notre dos, et l'image resterait
            // montée dans le Finder après une mise à jour réussie.
            if run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]).status != 0 {
                _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            }
        }

        let app = mount.appending(path: "Caspr.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw Failure.appMissing
        }

        // La version annoncée par l'API et celle du bundle doivent coïncider.
        // Sans ce contrôle, une pièce jointe remplacée après coup pourrait
        // faire installer n'importe quoi sous le nom d'une version qu'on vient
        // de présenter à l'utilisateur.
        let plist = app.appending(path: "Contents/Info.plist")
        let found = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"]
                     as? String) ?? "?"
        guard found == version else {
            throw Failure.versionMismatch(announced: version, found: found)
        }

        try verifySignature(of: app)

        // `ditto` plutôt que `cp` : c'est l'outil qui recopie un bundle signé
        // sans en altérer les attributs étendus, dont dépend le sceau qu'on
        // vient de vérifier.
        let copy = run("/usr/bin/ditto", [app.path, staged.path])
        guard copy.status == 0 else { throw Failure.copy(copy.error) }

        // La quarantaine, s'il y en a une, part **après** la vérification et
        // jamais avant. Ce qu'on retire là, c'est le drapeau qui déclencherait
        // le dialogue « développeur non identifié » ; on l'a remplacé par un
        // contrôle plus strict — même certificat que la copie déjà installée —
        // et non par rien.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
    }

    /// Le nouveau bundle est-il signé par la même main que celui qui tourne ?
    ///
    /// C'est la seule garantie sérieuse de toute la chaîne. TLS dit que
    /// l'octet vient bien de GitHub ; il ne dit pas que GitHub sert ce qu'on
    /// croit. L'exigence désignée, elle, tient à une clé privée qui n'est ni
    /// sur le serveur de release ni sur cette machine.
    private nonisolated static func verifySignature(of candidate: URL) throws {
        var running: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL,
                                          [], &running) == errSecSuccess,
              let running
        else { throw Failure.unreadableSignature }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(running, [], &requirement) == errSecSuccess,
              let requirement
        else { throw Failure.unreadableSignature }

        var new: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &new) == errSecSuccess,
              let new
        else { throw Failure.unreadableSignature }

        let flags = SecCSFlags(rawValue: SecCSFlags.RawValue(
            kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        let status = SecStaticCodeCheckValidity(new, flags, requirement)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String?
            throw Failure.signature(reason ?? "code \(status)")
        }
    }

    // MARK: - Remplacement

    /// Met le nouveau bundle à la place de l'ancien, d'un seul geste.
    ///
    /// `replaceItemAt` échange les deux répertoires au niveau du système de
    /// fichiers : à aucun instant il n'existe de Caspr.app à moitié écrit. Et
    /// comme c'est un remplacement et non une copie par-dessus, **rien de
    /// l'ancienne version ne survit** — un fichier retiré entre deux versions
    /// disparaît vraiment, là où un `cp -R` par-dessus l'aurait laissé traîner
    /// indéfiniment.
    ///
    /// Remplacer le bundle d'où s'exécute le processus en cours est permis :
    /// le noyau garde le contenu ouvert tant qu'on tourne, et c'est déjà ce
    /// que fait macOS quand on met une application à la corbeille pendant
    /// qu'elle est ouverte.
    private nonisolated static func swap(_ staged: URL, onto installed: URL) async throws {
        do {
            try FileManager.default.replaceItem(
                at: installed, withItemAt: staged,
                backupItemName: nil,
                // Les métadonnées du nouveau bundle, pas celles de l'ancien :
                // recopier les secondes par-dessus toucherait aux attributs
                // étendus que la signature scelle.
                options: [.usingNewMetadataOnly],
                resultingItemURL: nil)
        } catch {
            throw Failure.install(error.localizedDescription)
        }

        // Sans ça, les Réglages Système peuvent continuer d'afficher l'ancienne
        // entrée dans le volet Accessibilité — la même précaution que prend
        // scripts/install.sh.
        _ = run("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                + "LaunchServices.framework/Support/lsregister",
                ["-f", installed.path])
    }

    /// Quitte, puis rouvre — dans cet ordre, et sans recouvrement.
    ///
    /// Un `open` lancé avant de quitter donnerait deux Caspr en même temps,
    /// donc deux surveillances du raccourci clavier : une dictée sur deux
    /// s'écrirait en double. Le petit veilleur ci-dessous attend simplement
    /// que ce processus-ci ait disparu. Détaché du nôtre, il est adopté par
    /// launchd et survit à notre sortie.
    private static func relaunch(_ app: URL) {
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Le PID et le chemin passent en arguments positionnels plutôt que dans
        // le texte du script : rien à échapper, et un chemin contenant une
        // espace ne devient pas deux mots.
        watcher.arguments = [
            "-c",
            """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
            /bin/sleep 0.3
            /usr/bin/open "$2"
            """,
            "caspr-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            app.path,
        ]
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        try? watcher.run()

        // Laisse le temps à la fenêtre d'afficher « redémarrage » : une
        // application qui disparaît sans un mot au clic d'un bouton se lit
        // comme un plantage, pas comme une mise à jour réussie.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Outils

    @discardableResult
    private nonisolated static func run(_ path: String, _ arguments: [String])
        -> (status: Int32, error: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = pipe
        guard (try? task.run()) != nil else { return (-1, "\(path) introuvable") }
        // Lu avant d'attendre : un tube plein bloquerait le processus fils, qui
        // ne se terminerait jamais et ferait pendre l'application.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (task.terminationStatus, text)
    }

    // MARK: - Échecs

    private enum Failure: LocalizedError {
        case truncated(received: Int64, expected: Int64)
        case mount(String)
        case appMissing
        case versionMismatch(announced: String, found: String)
        case unreadableSignature
        case signature(String)
        case copy(String)
        case install(String)

        var errorDescription: String? {
            switch self {
            case .truncated(let received, let expected):
                "Téléchargement incomplet : \(bytes(received)) reçus sur "
                    + "\(bytes(expected)). Rien n'a été installé."
            case .mount(let detail):
                "L'image disque n'a pas pu être ouverte"
                    + (detail.isEmpty ? "." : " : \(detail)")
            case .appMissing:
                "L'image téléchargée ne contient pas Caspr.app."
            case .versionMismatch(let announced, let found):
                "La release annonce la version \(announced) mais l'image "
                    + "contient la \(found). Rien n'a été installé."
            case .unreadableSignature:
                "Impossible de lire la signature de l'une des deux copies. "
                    + "Rien n'a été installé."
            case .signature(let reason):
                "La nouvelle version ne porte pas la même signature que "
                    + "celle installée : rien n'a été remplacé (\(reason)). "
                    + "Deux causes ordinaires — cette copie-ci a été compilée "
                    + "depuis les sources et porte un certificat local, ou la "
                    + "release a été publiée sans certificat. Passez par le "
                    + "téléchargement."
            case .copy(let detail):
                "La copie du nouveau bundle a échoué"
                    + (detail.isEmpty ? "." : " : \(detail)")
            case .install(let detail):
                "Le remplacement a échoué : \(detail). L'ancienne version est "
                    + "intacte."
            }
        }

        private func bytes(_ count: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
        }
    }
}

// MARK: - Le téléchargement lui-même

/// Un `URLSessionDownloadTask` habillé en `async`, pour l'avancement.
///
/// `URLSession.download(for:)` existe et tiendrait en une ligne, mais ne dit
/// rien pendant qu'il travaille. Une image de plusieurs dizaines de
/// mégaoctets derrière un bouton muet passe pour un bouton cassé, et se
/// reclique.
final class AssetDownload: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: @MainActor (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    /// Dernier pourcentage annoncé : sans ce filtre, un téléchargement rapide
    /// programmerait des milliers de sauts vers le fil principal pour des
    /// variations invisibles.
    private var lastReported = -1

    init(to destination: URL, progress: @escaping @MainActor (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        // Éphémère : ni cache ni cookie ne doivent survivre à un
        // téléchargement de mise à jour.
        let session = URLSession(configuration: .ephemeral, delegate: self,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        let percent = Int(Double(written) / Double(expected) * 100)
        guard percent != lastReported else { return }
        lastReported = percent
        let fraction = Double(percent) / 100
        Task { @MainActor in progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Le fichier temporaire est effacé dès le retour de cette méthode : le
        // déplacement doit se faire ici, pas plus tard.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(.failure(error))
        }
        // La conclusion attend `didCompleteWithError`, qui suit toujours et
        // porte seul le statut HTTP : un 404 arrive lui aussi ici, avec la page
        // d'erreur en guise d'image disque.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            finish(.failure(DownloadFailure.http(code)))
            return
        }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    enum DownloadFailure: LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(404):
                "Le fichier de la release est introuvable (404). Elle a peut-"
                    + "être été publiée sans son image disque."
            case .http(let code):
                "Le téléchargement a répondu \(code)."
            }
        }
    }
}
