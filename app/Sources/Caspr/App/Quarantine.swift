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
///
/// Hors du fil principal : `xattr` est un processus qu'on attend.
enum Quarantine {

    /// Retire l'attribut de `bundle`, si présent et si on peut écrire.
    ///
    /// `bundle` : le bundle réellement installé (`Uninstall.appBundle`, lu sur
    /// le fil principal), pas la copie translocalisée que macOS exécute tant
    /// que l'attribut est là. Retirer l'attribut du fantôme ne servirait à
    /// rien : il disparaît à la fermeture, et l'original garde le sien.
    ///
    /// Silencieux en cas d'échec : un compte sans droit d'écriture sur
    /// l'application n'y peut rien, et l'en informer au lancement serait une
    /// inquiétude pour un problème qu'il ne peut pas résoudre.
    static func clear(bundle: URL) {
        guard has(bundle) else { return }

        let fm = FileManager.default
        guard fm.isWritableFile(atPath: bundle.path) else {
            Log.info("quarantaine : présente mais bundle non inscriptible")
            return
        }

        let statut = retirer(de: bundle)
        Log.info(statut == 0 ? "quarantaine retirée du bundle" : "quarantaine : xattr a répondu \(statut)")
    }

    /// Retire l'attribut de tout ce que contient `url` ; rend le statut de
    /// `xattr`.
    @discardableResult
    static func retirer(de url: URL) -> Int32 {
        Commande.executer("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path]).statut
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
