import AppKit
import Carbon.HIToolbox

/// Dépose le texte transcrit à l'emplacement du curseur de l'app active.
///
/// Deux voies existent sous macOS :
///
/// 1. l'API d'accessibilité (`AXUIElement`), qui écrit dans le champ ciblé ;
/// 2. le presse-papiers suivi d'un ⌘V synthétisé.
///
/// On privilégie (1) quand le champ l'accepte : rien ne transite par le
/// presse-papiers, donc aucun risque d'écraser ce que l'utilisateur y gardait,
/// et l'insertion est atomique. Beaucoup d'applications — navigateurs,
/// Electron, terminaux — n'exposent pas de champ inscriptible ; on retombe
/// alors sur (2), en restaurant le presse-papiers juste après.
@MainActor
final class TextInjector {
    enum InjectionError: LocalizedError {
        case accessibilityDenied

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Autorisation d'accessibilité requise pour insérer le texte."
            }
        }
    }

    /// Délai laissé à l'app cible pour traiter le ⌘V avant qu'on restaure le
    /// presse-papiers. Trop court, on restaure avant que le collage ait lu la
    /// valeur ; trop long, l'utilisateur voit son presse-papiers altéré.
    private let pasteSettleDelay: Duration = .milliseconds(180)

    var hasPermission: Bool { AXIsProcessTrusted() }

    /// Ouvre la fenêtre système de demande d'autorisation.
    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func inject(_ text: String) async throws {
        guard !text.isEmpty else { return }
        guard hasPermission else { throw InjectionError.accessibilityDenied }

        if injectViaAccessibility(text) { return }
        try await injectViaPasteboard(text)
    }

    // MARK: - Voie 1 : accessibilité

    private func injectViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused else { return false }
        let field = element as! AXUIElement

        // Un champ en lecture seule accepterait la valeur sans l'afficher.
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            field, kAXSelectedTextAttribute as CFString, &settable) == .success,
            settable.boolValue else { return false }

        // Écrire dans la sélection insère au curseur quand elle est vide, et
        // remplace la sélection sinon — c'est le comportement attendu.
        return AXUIElementSetAttributeValue(
            field, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    // MARK: - Voie 2 : presse-papiers

    private func injectViaPasteboard(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        try postCommandV()

        try? await Task.sleep(for: pasteSettleDelay)
        Self.restore(saved, to: pasteboard)
    }

    private func postCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InjectionError.accessibilityDenied
        }
        // Empêche notre ⌘V synthétique de réveiller le raccourci global.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) else {
            throw InjectionError.accessibilityDenied
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Copie le contenu du presse-papiers, tous types confondus.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            return stored
        }
    }

    private static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]],
                                to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
