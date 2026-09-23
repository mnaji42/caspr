import AppKit
import AVFoundation

/// Accès aux volets d'autorisation des Réglages Système.
///
/// Une app ne peut pas s'accorder ces droits ni même rouvrir le dialogue une
/// fois qu'un refus a été enregistré. Le mieux qu'elle puisse faire est
/// d'amener l'utilisateur au bon endroit en un clic, plutôt que de lui
/// demander de naviguer dans les Réglages.
enum Permissions {
    private static func open(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        open("Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("Privacy_Accessibility")
    }

    /// Confidentialité et sécurité › Reconnaissance vocale.
    ///
    /// Le seul chemin qui reste une fois le droit refusé ou révoqué : macOS ne
    /// représentera plus son dialogue, et la case ne se recoche qu'ici.
    static func openSpeechRecognitionSettings() {
        open("Privacy_SpeechRecognition")
    }

    /// Demande l'accessibilité par le dialogue de macOS, plutôt que d'expédier
    /// l'utilisateur dans les Réglages Système sans prévenir.
    ///
    /// Aucune application ne peut s'accorder ce droit : le passage par les
    /// Réglages est imposé par le système, pas par nous. Mais macOS sait au
    /// moins présenter la demande lui-même, avec un bouton qui y mène. C'est
    /// une marche de moins, et surtout c'est une *demande* au lieu d'un saut
    /// dans une autre application.
    ///
    /// Le dialogue n'est présenté qu'une fois par application : passé là,
    /// l'appel ne fait plus rien de visible, et il faut le lien direct. Les
    /// deux chemins doivent donc rester offerts.
    ///
    /// - Returns: vrai si le droit est déjà accordé.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Efface l'autorisation d'accessibilité pour repartir de zéro.
    ///
    /// Sert à une panne précise, et déroutante. macOS attache l'autorisation à
    /// la **signature** de l'application, pas à son chemin. Quand la signature
    /// change — une version signée autrement que la précédente — l'ancienne
    /// entrée survit et ne correspond plus au binaire qui tourne. Les Réglages
    /// Système affichent alors Caspr coché, tandis que Caspr jure qu'il n'a
    /// rien. Décocher et recocher n'y change rien : la case pilote une entrée
    /// périmée.
    ///
    /// Mesuré sur une machine où le problème s'était installé : `tccutil` a
    /// effacé **cinq** entrées pour le même identifiant, une par signature
    /// portée au fil des versions.
    ///
    /// La vraie parade est en amont — signer toutes les versions avec la même
    /// identité, cf. scripts/make-signing-cert.sh. Ceci répare l'existant.
    @discardableResult
    static func resetAccessibility() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", "fr.lyriastudio.caspr"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Résumé lisible de l'état courant, affiché dans le menu.
    static func summary(accessibilityGranted: Bool) -> String {
        let mic = switch AudioRecorder.microphoneAccess {
        case .granted: "micro ✓"
        case .undetermined: "micro —"
        case .denied: "micro ✗"
        }
        return "\(mic)   accessibilité \(accessibilityGranted ? "✓" : "✗")"
    }

    static var allGranted: Bool {
        AudioRecorder.microphoneAccess == .granted && AXIsProcessTrusted()
    }
}
