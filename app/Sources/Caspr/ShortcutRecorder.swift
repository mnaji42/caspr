import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Champ qui capture une combinaison de touches.
///
/// Il faut un `NSView` : SwiftUI n'expose pas les événements clavier bruts, et
/// c'est précisément d'eux qu'on a besoin — on veut la touche *physique* et
/// les modificateurs, pas le caractère produit, qui dépend de la disposition.
///
/// Contrainte macOS 15+ à connaître avant de choisir : un raccourci dont les
/// seuls modificateurs sont Option et/ou Majuscule est refusé par le système,
/// au titre de la lutte contre les enregistreurs de frappe. On le vérifie ici
/// pour le dire tout de suite, plutôt que de laisser l'enregistrement échouer
/// silencieusement.
struct ShortcutRecorder: NSViewRepresentable {
    /// `nil` quand aucun raccourci n'est retenu — cf. `init(optional:id:)`.
    @Binding var shortcut: HotkeyMonitor.Shortcut?
    /// L'identifiant que porte la combinaison retenue. Pris au raccourci
    /// quand il y en a un ; un raccourci facultatif, lui, n'en a pas toujours
    /// un à qui le demander.
    let id: UInt32

    /// Un raccourci qui existe toujours, comme celui de la dictée.
    init(shortcut: Binding<HotkeyMonitor.Shortcut>) {
        _shortcut = Binding(shortcut)
        id = shortcut.wrappedValue.id
    }

    /// Un raccourci qu'on peut ne pas avoir.
    init(optional shortcut: Binding<HotkeyMonitor.Shortcut?>, id: UInt32) {
        _shortcut = shortcut
        self.id = id
    }

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.shortcut = shortcut
        view.shortcutID = id
        view.onChange = { new in shortcut = new }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var shortcut: HotkeyMonitor.Shortcut?
        var shortcutID: UInt32 = HotkeyMonitor.Shortcut.dictate.id
        var onChange: ((HotkeyMonitor.Shortcut) -> Void)?
        private var recording = false
        private var refusal: String?

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

        override func mouseDown(with event: NSEvent) {
            recording = true
            refusal = nil
            window?.makeFirstResponder(self)
            needsDisplay = true
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            needsDisplay = true
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }

            if event.keyCode == UInt16(kVK_Escape) {
                recording = false
                needsDisplay = true
                return
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Le système refuse Option et Majuscule seuls : autant le dire
            // maintenant, l'enregistrement échouerait sans rien afficher.
            let strong = flags.contains(.control) || flags.contains(.command)
            guard strong else {
                refusal = "macOS refuse un raccourci sans Contrôle ni Commande."
                needsDisplay = true
                return
            }

            var carbon: UInt32 = 0
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.option)  { carbon |= UInt32(optionKey) }
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }

            let new = HotkeyMonitor.Shortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: carbon,
                label: Self.label(flags: flags, keyCode: event.keyCode),
                id: shortcutID)
            shortcut = new
            recording = false
            refusal = nil
            needsDisplay = true
            onChange?(new)
        }

        /// Rend la combinaison telle qu'un utilisateur de Mac la lit.
        static func label(flags: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option)  { text += "⌥" }
            if flags.contains(.shift)   { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            return text + (Self.names[keyCode] ?? Self.character(for: keyCode))
        }

        /// Touches sans caractère imprimable.
        private static let names: [UInt16: String] = [
            UInt16(kVK_Space): "Espace", UInt16(kVK_Return): "⏎",
            UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        ]

        /// Caractère imprimé par cette touche physique, dans la disposition
        /// courante — un `D` sur AZERTY comme sur QWERTY se lit « D ».
        private static func character(for keyCode: UInt16) -> String {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
                    .takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(
                    source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            var dead: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = data.withUnsafeBytes { raw -> OSStatus in
                guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress
                else { return -1 }
                return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                      UInt32(LMGetKbdType()),
                                      OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                      &dead, characters.count, &length, &characters)
            }
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }

        override func draw(_ dirtyRect: NSRect) {
            let radius: CGFloat = 7
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: radius, yRadius: radius)
            (recording ? NSColor.casprAccent.withAlphaComponent(0.18)
                       : NSColor.white.withAlphaComponent(0.06)).setFill()
            path.fill()
            (recording ? NSColor.casprAccent : NSColor.white.withAlphaComponent(0.10)).setStroke()
            path.stroke()

            let text = refusal
                ?? (recording ? "Tapez la combinaison…" : shortcut?.label ?? "Aucun")
            let colour: NSColor = refusal != nil ? .casprWarning
                : (recording ? .casprAccent : .secondaryLabelColor)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: refusal != nil ? 9 : 12,
                                         weight: .medium),
                .foregroundColor: colour,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2),
                withAttributes: attributes)
        }
    }
}
