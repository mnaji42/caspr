import AppKit

/// Les outils du système que Caspr lance — `launchctl`, `xattr`, `tccutil`,
/// `ditto`, `mdfind` — et sa propre relance.
///
/// Sept copies de `Process` puis `waitUntilExit` vivaient dans sept fichiers,
/// chacune avec sa façon de traiter l'échec : la sortie d'erreur lue ici,
/// jetée là, un échec de lancement avalé ailleurs. Un seul chemin les lance
/// maintenant, et rend tout ce qu'il sait.
enum Commande {
    struct Resultat {
        /// Le statut de sortie ; -1 quand l'outil n'a pas pu être lancé.
        let statut: Int32
        /// La sortie standard, seulement quand elle a été demandée.
        let sortie: String
        let erreur: String

        var reussi: Bool { statut == 0 }
    }

    /// Lance l'outil et attend qu'il rende la main — à ne pas appeler du fil
    /// principal pour un outil qui peut durer.
    ///
    /// `sortie` : lire la sortie standard ; sinon elle part au néant.
    @discardableResult
    static func executer(_ chemin: String, _ arguments: [String], sortie: Bool = false) -> Resultat {
        let tache = Process()
        tache.executableURL = URL(fileURLWithPath: chemin)
        tache.arguments = arguments
        let tubeSortie = sortie ? Pipe() : nil
        let tubeErreur = Pipe()
        tache.standardOutput = tubeSortie ?? FileHandle.nullDevice
        tache.standardError = tubeErreur
        guard (try? tache.run()) != nil else {
            return Resultat(statut: -1, sortie: "", erreur: "\(chemin) introuvable")
        }
        // Les tubes sont lus avant d'attendre, et ensemble : un tube plein
        // bloquerait le fils, qui ne se terminerait jamais et ferait pendre
        // l'application.
        let lue = Lue()
        let groupe = DispatchGroup()
        if let tubeSortie {
            DispatchQueue.global(qos: .utility).async(group: groupe) {
                lue.donnees = tubeSortie.fileHandleForReading.readDataToEndOfFile()
            }
        }
        let erreur = tubeErreur.fileHandleForReading.readDataToEndOfFile()
        groupe.wait()
        tache.waitUntilExit()
        return Resultat(statut: tache.terminationStatus,
                        sortie: texte(lue.donnees), erreur: texte(erreur))
    }

    private static func texte(_ donnees: Data) -> String {
        String(data: donnees, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// La sortie standard, lue sur un autre fil que l'erreur.
    private final class Lue: @unchecked Sendable {
        var donnees = Data()
    }

    /// Quitte, puis rouvre `bundle` — dans cet ordre, et sans recouvrement.
    ///
    /// Un `open` lancé avant de quitter donnerait deux Caspr en même temps,
    /// donc deux surveillances du raccourci clavier : une dictée sur deux
    /// s'écrirait en double. Un petit veilleur attend donc que ce processus-ci
    /// ait disparu ; détaché du nôtre, il est adopté par launchd et survit à
    /// notre sortie.
    ///
    /// `volume` : l'image disque à éjecter entre les deux — on ne peut pas
    /// éjecter un volume depuis un processus qui s'y exécute. `delai` : le
    /// temps laissé à la fenêtre pour dire ce qui se passe avant de quitter ;
    /// une application qui disparaît sans un mot se lit comme un plantage.
    @MainActor
    static func relancer(_ bundle: URL, ejecter volume: URL? = nil, delai: TimeInterval = 0) {
        let veilleur = Process()
        veilleur.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Le PID et les chemins passent en arguments positionnels plutôt que
        // dans le texte du script : rien à échapper, et un chemin contenant
        // une espace ne devient pas deux mots.
        veilleur.arguments = [
            "-c",
            """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
            /bin/sleep 0.4
            if [ -n "$3" ]; then
                /usr/bin/hdiutil detach "$3" -quiet 2>/dev/null \
                    || /usr/bin/hdiutil detach "$3" -force -quiet 2>/dev/null
            fi
            /usr/bin/open "$2"
            """,
            "caspr-relance",
            String(ProcessInfo.processInfo.processIdentifier),
            bundle.path,
            volume?.path ?? "",
        ]
        veilleur.standardOutput = FileHandle.nullDevice
        veilleur.standardError = FileHandle.nullDevice
        try? veilleur.run()
        guard delai > 0 else { return NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delai) { NSApp.terminate(nil) }
    }
}
