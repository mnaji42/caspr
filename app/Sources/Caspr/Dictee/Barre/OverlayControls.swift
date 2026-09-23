import AppKit

/// Un menu déroulant qui répond au premier clic.
///
/// Le panneau ne prend pas le focus — c'est tout son intérêt : il ne vole pas
/// le curseur à l'application dans laquelle on dicte. Mais un contrôle
/// ordinaire consomme alors le premier clic pour activer la fenêtre, et il
/// faut cliquer deux fois. Pendant une dictée, ce premier clic perdu est
/// exactement celui qu'on croyait avoir donné.
final class FirstMouseMenuButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        font = .systemFont(ofSize: 11, weight: .semibold)
        controlSize = .small
    }

    convenience init() { self.init(frame: .zero, pullsDown: false) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas utilisé") }
}

/// Bouton qui répond au premier clic dans une fenêtre inactive.
///
/// Le panneau ne devient jamais clé — c'est ce qui garantit que le curseur ne
/// bouge pas. En contrepartie tout clic y est un « premier clic », que
/// `NSControl` ignore par défaut.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Barres de niveau sonore, défilant de droite à gauche.
final class LevelMeter: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    private let barCount = 9
    private var history: [Float] = []

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        history.append(level)
        if history.count > barCount { history.removeFirst(history.count - barCount) }

        let barWidth: CGFloat = 3
        let gap = (bounds.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)

        for index in 0..<barCount {
            let value = index < history.count ? history[history.count - 1 - index] : 0
            let height = max(3, CGFloat(value) * bounds.height)
            // Les barres récentes sont franches, les anciennes s'effacent :
            // le sens de défilement se lit sans y penser.
            let fade = 1 - CGFloat(index) / CGFloat(barCount) * 0.75
            context.setFillColor(NSColor.casprAccent.withAlphaComponent(fade).cgColor)
            let x = bounds.width - CGFloat(index + 1) * barWidth - CGFloat(index) * gap
            let rect = NSRect(x: x, y: (bounds.height - height) / 2,
                              width: barWidth, height: height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5,
                                   cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
    }
}
