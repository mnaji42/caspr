import OSLog

/// Journal de l'application, lisible depuis la Console et `log show`.
///
/// `NSLog` interpole en `<private>` par défaut : les messages existent mais
/// sortent caviardés, ce qui rend un diagnostic à distance impossible — on se
/// retrouve à déduire l'état de l'application depuis les journaux internes de
/// CoreAudio, ce qui a déjà coûté une fausse piste.
///
/// Ce qui passe ici est donc marqué explicitement public. Rien de sensible n'y
/// transite : des états, des durées, des noms de moteurs. **Jamais** le texte
/// dicté, qui reste entre l'utilisateur et son curseur.
enum Log {
    private static let logger = Logger(subsystem: "fr.lyriastudio.caspr",
                                       category: "dictation")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    /// Ce qu'on voudra relire après coup, et non seulement voir passer.
    ///
    /// `info` n'est gardé qu'en mémoire : un geste fait une seule fois au
    /// lancement — une migration qui met des fichiers à la corbeille — aurait
    /// disparu du journal avant que quiconque se demande où ils sont passés.
    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Les millisecondes écoulées depuis `debut`, pour les durées du journal.
    static func ms(depuis debut: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - debut) / .milliseconds(1))
    }
}
