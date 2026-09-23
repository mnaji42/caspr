import AppKit
import CasprCore

/// Où atterrit le texte transcrit.
///
/// Par défaut au curseur de l'application active. Une fois verrouillé sur un
/// fichier, tout y est ajouté quoi que fasse le curseur — on continue de
/// travailler normalement et les notes s'accumulent au bon endroit.
///
/// Le verrou vise un **fichier**, pas un champ texte, et c'est délibéré.
/// Retenir un `AXUIElement` paraît plus direct mais casse vite : la référence
/// devient caduque dès que l'onglet change, que la fenêtre se ferme ou que
/// l'éditeur recycle sa vue. Et les éditeurs qui comptent ici — Cursor,
/// VS Code — sont des applications Electron dont l'arbre d'accessibilité
/// n'expose pas de champ inscriptible fiable. Écrire dans le fichier
/// fonctionne toujours, l'éditeur recharge tout seul, et ça marche même
/// fenêtre fermée.
enum DictationTarget: Equatable {
    case caret
    case file(URL)

    var isLocked: Bool {
        if case .file = self { return true }
        return false
    }

    var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    var displayName: String {
        switch self {
        case .caret: "Curseur de l'app active"
        case .file(let url): url.lastPathComponent
        }
    }
}

/// Ajoute le texte dicté à un fichier.
@MainActor
enum TargetWriter {
    enum WriteError: LocalizedError {
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .notWritable(let name):
                return "Écriture impossible dans \(name). Vérifier les droits du fichier."
            }
        }
    }

    static func append(_ text: String, to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = TextComposition.appending(text, to: existing)
        guard updated != existing else { return }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw WriteError.notWritable(url.lastPathComponent)
        }
    }

    /// Fichier ouvert dans l'application active, si on parvient à l'identifier.
    ///
    /// Deux voies, dans cet ordre :
    ///
    /// 1. `AXDocument`, que publient les applications natives — Xcode, TextEdit,
    ///    Notes. Direct et fiable quand il existe.
    /// 2. Le **titre de la fenêtre**, pour les éditeurs Electron (VS Code,
    ///    Cursor, Antigravity), qui n'exposent aucun document via
    ///    l'accessibilité mais affichent « fichier.ext — dossier » dans leur
    ///    barre de titre. On en extrait le nom et on le localise.
    ///
    /// La seconde voie est indispensable : ce sont précisément les éditeurs
    /// dans lesquels on prend des notes de revue.
    static func frontmostDocument() -> URL? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let focused = window else { return nil }
        let axWindow = focused as! AXUIElement

        if let url = documentAttribute(of: axWindow) {
            NSLog("caspr: document via AXDocument — %@", url.path)
            return url
        }
        if let url = documentFromTitle(of: axWindow) {
            NSLog("caspr: document via titre de fenêtre — %@", url.path)
            return url
        }
        NSLog("caspr: aucun document identifié pour %@",
              app.localizedName ?? "l'app active")
        return nil
    }

    private static func documentAttribute(of window: AXUIElement) -> URL? {
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXDocumentAttribute as CFString, &document) == .success,
            let path = document as? String, !path.isEmpty else { return nil }

        let url = path.hasPrefix("file://")
            ? URL(string: path)
            : URL(fileURLWithPath: path)
        return url.flatMap(validated)
    }

    /// Déduit le fichier du titre de la fenêtre.
    ///
    /// Les éditeurs dérivés de VS Code titrent « fichier.ext — projet », avec
    /// un point ou une puce devant quand il reste des modifications non
    /// enregistrées. On isole le nom, puis on le localise avec Spotlight en
    /// privilégiant les chemins contenant le nom du projet — sans quoi un
    /// `README.md` renverrait n'importe lequel des dizaines présents sur le
    /// disque.
    private static func documentFromTitle(of window: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &value) == .success,
            let title = value as? String, !title.isEmpty else { return nil }

        guard let parsed = TextComposition.parseWindowTitle(title) else { return nil }
        return locate(fileNamed: parsed.fileName, preferring: parsed.hints)
    }

    /// Localise un fichier par son nom via Spotlight.
    private static func locate(fileNamed name: String,
                               preferring hints: [String]) -> URL? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["-name", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let candidates = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
            .filter { $0.lastPathComponent == name }
            .compactMap(validated)
            .map(\.path)

        return TextComposition.bestCandidate(among: candidates, preferring: hints)
            .map { URL(fileURLWithPath: $0) }
    }

    /// Un chemin n'est retenu que s'il désigne un fichier réel et inscriptible.
    ///
    /// Une première version se contentait de tester l'existence : « / » passait,
    /// d'où une cible verrouillée sur la racine du disque.
    private static func validated(_ url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory),
              !isDirectory.boolValue,
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != "/",
              FileManager.default.isWritableFile(atPath: url.path)
        else { return nil }
        return url
    }

    /// Ce que Caspr perçoit de l'application active.
    ///
    /// La détection dépend de ce que publie chaque application, et il n'y a
    /// aucun moyen de le deviner de l'extérieur. Plutôt que de faire deviner
    /// l'utilisateur, on lui montre la matière brute.
    static func diagnostics() -> String {
        guard AXIsProcessTrusted() else {
            return "Accessibilité non accordée — la détection est impossible."
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "Aucune application au premier plan."
        }
        var lines = ["Application : \(app.localizedName ?? "?")"]

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let focused = window else {
            lines.append("Fenêtre focalisée : introuvable")
            return lines.joined(separator: "\n")
        }
        let axWindow = focused as! AXUIElement

        var doc: CFTypeRef?
        let docStatus = AXUIElementCopyAttributeValue(
            axWindow, kAXDocumentAttribute as CFString, &doc)
        lines.append("AXDocument : " + (docStatus == .success
            ? String(describing: doc!) : "non publié"))

        var title: CFTypeRef?
        let titleStatus = AXUIElementCopyAttributeValue(
            axWindow, kAXTitleAttribute as CFString, &title)
        let titleText = titleStatus == .success ? (title as? String ?? "?") : "non publié"
        lines.append("Titre de fenêtre : \(titleText)")

        if let url = frontmostDocument() {
            lines.append("\nFichier identifié : \(url.path)")
        } else {
            lines.append("\nAucun fichier identifié — le sélecteur s'ouvrira.")
        }
        return lines.joined(separator: "\n")
    }

    /// Sélecteur de fichier, pour les applications qui ne publient rien.
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choisir le fichier de destination"
        panel.message = "Les transcriptions seront ajoutées à la fin de ce fichier."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
