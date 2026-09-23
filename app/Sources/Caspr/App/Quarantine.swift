import Foundation

/// L'attribut que macOS pose sur ce qui vient du réseau, et qu'on retire de
/// soi-même une fois lancé.
///
/// ## Le problème
///
/// Caspr est signé mais pas notarisé. Gatekeeper ne conteste que les fichiers
/// portant `com.apple.quarantine` — attribut que tout navigateur pose sur ce
/// qu'il télécharge, et qui se propage à l'application glissée dans
/// Applications. Quelqu'un qui autorise Caspr une fois depuis les Réglages
/// Système peut donc revoir le même dialogue plus tard : l'autorisation vaut
/// pour ce bundle précis, mais l'attribut reste, et avec lui la possibilité
/// d'un nouveau contrôle. Observé en conditions réelles — quitter puis rouvrir
/// a suffi.
///
/// ## Ce qu'on fait
///
/// Au lancement, une fois que le système nous a laissés démarrer, on retire
/// l'attribut de notre propre bundle. Le dialogue ne peut alors plus revenir.
///
/// Ça n'affaiblit rien, et il faut voir pourquoi : le contrôle initial a déjà
/// eu lieu — sans quoi ce code ne s'exécuterait pas — et l'utilisateur a déjà
/// donné son accord. Retirer l'attribut n'ouvre aucune porte : quiconque
/// pourrait remplacer le bundle plus tard aurait, par construction, le droit
/// d'écrire dedans, donc aussi celui d'en retirer l'attribut lui-même.
///
/// ## Ce que ça ne fait pas
///
/// **Le tout premier lancement affichera toujours le dialogue.** Rien du côté
/// de l'application ne peut l'éviter : à ce moment-là elle n'a pas encore le
/// droit de s'exécuter. Seule la notarisation le supprime, et elle suppose un
/// compte Apple Developer. Ce qui est réglé ici, c'est la deuxième fois — et
/// toutes les suivantes.
@MainActor
enum Quarantine {

    /// Retire l'attribut du bundle courant, si présent et si on peut écrire.
    ///
    /// Silencieux en cas d'échec : un compte sans droit d'écriture sur
    /// l'application n'y peut rien, et l'en informer au lancement serait une
    /// inquiétude pour un problème qu'il ne peut pas résoudre.
    static func clearFromOwnBundle() {
        // Le bundle réellement installé, pas la copie translocalisée que macOS
        // exécute tant que l'attribut est là. Retirer l'attribut du fantôme ne
        // servirait à rien : il disparaît à la fermeture, et l'original garde
        // le sien. Cf. Uninstall.appBundle.
        let bundle = Uninstall.appBundle
        guard has(bundle) else { return }

        let fm = FileManager.default
        guard fm.isWritableFile(atPath: bundle.path) else {
            Log.info("quarantaine : présente mais bundle non inscriptible")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", bundle.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
        Log.info(task.terminationStatus == 0
                 ? "quarantaine retirée du bundle"
                 : "quarantaine : xattr a répondu \(task.terminationStatus)")
    }

    /// L'attribut est-il posé ? Vérifié avant de lancer un processus : sur une
    /// application installée depuis longtemps la réponse est non, et démarrer
    /// `xattr` à chaque ouverture de session pour rien serait gratuit.
    private static func has(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }
}
