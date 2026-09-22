import AppKit
import Foundation

/// Reprend ce que « Caspr » avait laissé, sous le nom de Caspr.
///
/// ## Pourquoi ce n'est pas un simple renommage
///
/// macOS attache beaucoup de choses à l'identifiant du bundle et au nom de
/// l'application, et aucune ne suit toute seule :
///
/// - Le dossier de support, qui contient **le corpus** — des centaines de
///   dictées réelles que rien ne permet de reconstituer.
/// - Les préférences, rangées sous un domaine qui est l'identifiant lui-même.
/// - L'agent launchd de l'ancien moteur local, dont le label porte l'ancien
///   identifiant : il tient ses fichiers ouverts, et doit sortir avant qu'on
///   déplace le dossier sous lui.
///
/// Les autorisations micro et accessibilité, elles, ne se migrent pas : TCC les
/// lie à l'identifiant et ne fournit aucun moyen de les transférer. Elles
/// seront redemandées, et c'est le prix assumé d'un identifiant propre.
///
/// ## Déplacer plutôt que copier
///
/// Le corpus pèse près d'un gigaoctet. Un déplacement sur le même volume est
/// une opération de l'index de fichiers : instantanée, atomique, et sans état
/// intermédiaire où la moitié des données existerait en double. Une copie
/// suivie d'une suppression aurait ces deux défauts, et le second est le pire :
/// une interruption au mauvais moment laisserait un corpus à moitié effacé.
enum Rebranding {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static let previousBundleID = "fr.lyriastudio.sofler"
    static let newBundleID = "fr.lyriastudio.caspr"
    static let previousAgentLabel = "fr.lyriastudio.sofler.engine"

    /// Les dossiers à reprendre : ancien emplacement, nouveau.
    private static var directories: [(from: URL, to: URL)] {
        [
            (home.appending(path: "Library/Application Support/Sofler"),
             home.appending(path: "Library/Application Support/Caspr")),
            (home.appending(path: "Library/Caches/sofler"),
             home.appending(path: "Library/Caches/caspr")),
            (home.appending(path: "Library/Logs/Sofler"),
             home.appending(path: "Library/Logs/Caspr")),
        ]
    }

    /// À appeler **avant** toute lecture de réglage ou de fichier de support.
    ///
    /// Sans effet dès la deuxième fois : chaque étape vérifie qu'il y a
    /// quelque chose à reprendre, et une installation neuve ne trouve rien.
    @MainActor static func migrateIfNeeded() {
        // Verrou : tant que le bundle porte l'ancien identifiant, il lit encore
        // l'ancien dossier. Déplacer les fichiers sous ses pieds rendrait le
        // corpus invisible à l'application qui vient de le déplacer. La
        // migration ne s'arme donc qu'une fois le renommage réellement en
        // place — d'ici là, elle ne fait rien, quel qu'en soit l'appelant.
        guard Bundle.main.bundleIdentifier == newBundleID else { return }
        retireOldAgent()
        moveDirectories()
        adoptPreferences()
    }

    // MARK: - L'agent de l'ancien nom

    /// Sorti d'abord, et c'est l'ordre qui compte : un service encore vivant
    /// tient ses fichiers ouverts pendant qu'on déplace le dossier sous lui.
    private static func retireOldAgent() {
        let plist = home.appending(
            path: "Library/LaunchAgents/\(previousAgentLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/\(previousAgentLabel)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        try? FileManager.default.removeItem(at: plist)
        NSLog("caspr: ancien agent launchd retiré")
    }

    // MARK: - Les dossiers

    private static func moveDirectories() {
        let fm = FileManager.default
        for (from, to) in directories {
            guard fm.fileExists(atPath: from.path) else { continue }
            // Le nouveau existe déjà : on ne fusionne pas, et on ne détruit
            // rien. Ce cas ne se produit qu'après une installation neuve suivie
            // d'une restauration de l'ancienne — trancher à sa place serait
            // décider du sort de données qu'on ne sait pas lire.
            guard !fm.fileExists(atPath: to.path) else {
                NSLog("caspr: \(to.lastPathComponent) existe déjà — "
                      + "\(from.lastPathComponent) laissé en place")
                continue
            }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                NSLog("caspr: \(from.lastPathComponent) repris")
            } catch {
                NSLog("caspr: reprise de \(from.lastPathComponent) impossible — "
                      + error.localizedDescription)
            }
        }
    }

    // MARK: - Les réglages

    /// Recopie l'ancien domaine dans le nouveau, clé par clé.
    ///
    /// Seulement si le nouveau est vierge : au deuxième lancement, les réglages
    /// courants sont ceux de Caspr, et les réécrire avec ceux de Caspr
    /// annulerait tout ce qui a été changé depuis.
    private static func adoptPreferences() {
        let defaults = UserDefaults.standard
        guard defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
                .map({ $0.isEmpty }) ?? true,
              let old = defaults.persistentDomain(forName: previousBundleID),
              !old.isEmpty
        else { return }

        // Les clés changent de préfixe avec le nom. Converties au passage :
        // les recopier telles quelles laisserait trente-deux réglages sous un
        // nom que plus rien ne lit.
        for (key, value) in old {
            let renamed = key.hasPrefix("sofler.")
                ? "caspr." + key.dropFirst("sofler.".count)
                : key
            defaults.set(value, forKey: renamed)
        }
        // L'ancien domaine est laissé intact : si quelque chose s'est mal
        // passé, il reste de quoi revenir en arrière à la main.
        NSLog("caspr: \(old.count) réglages repris de Caspr")
    }
}
