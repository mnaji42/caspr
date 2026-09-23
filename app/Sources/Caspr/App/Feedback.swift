import AppKit

/// Retours sonores discrets.
///
/// La pastille ne suffit pas : au déclenchement, le regard est encore sur le
/// texte qu'on est en train d'écrire, pas en bas de l'écran. Un son confirme
/// immédiatement que l'enregistrement a démarré, sans avoir à vérifier.
///
/// On emprunte les sons système plutôt que d'embarquer des fichiers : ils sont
/// familiers, calibrés en volume, et suivent les réglages de l'utilisateur.
enum Feedback {
    private static func play(_ name: String) {
        guard UserDefaults.standard.object(forKey: "caspr.sounds") as? Bool ?? true,
              let sound = NSSound(named: name) else { return }
        sound.stop()          // coupe l'occurrence précédente si on enchaîne vite
        sound.play()
    }

    static func recordingStarted() { play("Tink") }
    static func recordingStopped() { play("Pop") }
    static func cancelled() { play("Funk") }

    static var soundsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "caspr.sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "caspr.sounds") }
    }
}
