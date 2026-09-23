import AppKit

/// Sélecteur à deux ou trois valeurs, dessiné à la main.
///
/// `NSSegmentedControl` a été essayé d'abord, et écarté pour une raison
/// mesurée : en style `.capsule`, `selectedSegmentBezelColor` est ignoré — le
/// segment actif reste du gris système. Sans teinte, l'état actif se distingue
/// à peine de l'inactif, ce qui vide de son sens l'idée même de montrer l'état
/// plutôt que l'action.
///
/// Le contrôle vit dans un panneau qui ne devient **jamais** fenêtre clé, pour
/// que le curseur de l'utilisateur ne bouge pas. Tout clic y est donc un
/// « premier clic », que `NSControl` ignore par défaut : d'où
/// `acceptsFirstMouse` sur chaque segment, sans quoi il faudrait cliquer deux
/// fois.
@MainActor
final class PillSelector: NSView {
    var onSelect: ((Int) -> Void)?

    private let accent: NSColor
    private var buttons: [SegmentButton] = []
    private let stack = NSStackView()
    private(set) var selectedIndex = 0

    // `padding: 3px` autour de segments de 22 pt.
    private static let height: CGFloat = 28
    private static let inset: CGFloat = 3

    init(labels: [String], accent: NSColor) {
        self.accent = accent
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Le groupe flotte au-dessus du panneau principal, donc au-dessus de
        // n'importe quelle fenêtre : il lui faut son propre fond, sans quoi
        // un simple fond translucide serait illisible sur du texte clair.
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = Self.height / 2
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = accent.withAlphaComponent(0.35).cgColor
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        // La même ardoise que la carte et que les fenêtres, dans une vue à
        // part. La poser sur `glass.layer.backgroundColor` ne tenait pas :
        // `NSVisualEffectView` réécrit son calque quand il ravive son matériau.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.casprWindow.cgColor
        tint.layer?.cornerRadius = Self.height / 2
        tint.layer?.masksToBounds = true
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            tint.topAnchor.constraint(equalTo: glass.topAnchor),
            tint.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        rebuild(with: labels)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
        ])
        select(0)
    }

    /// Remplace les segments.
    ///
    /// Les langues déclarées changent pendant que la barre existe — on en
    /// ajoute une depuis les Réglages sans que la dictée s'arrête. Construire
    /// les segments une fois pour toutes obligerait à jeter le contrôle entier
    /// pour en changer un libellé.
    func setLabels(_ labels: [String]) {
        rebuild(with: labels)
        select(min(selectedIndex, max(labels.count - 1, 0)))
    }

    private func rebuild(with labels: [String]) {
        for button in buttons {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons = labels.enumerated().map { index, label in
            let button = SegmentButton(title: label)
            button.target = self
            button.action = #selector(tapped(_:))
            button.tag = index
            stack.addArrangedSubview(button)
            return button
        }
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    func setLabel(_ text: String, at index: Int) {
        guard buttons.indices.contains(index) else { return }
        buttons[index].title = text
        buttons[index].restyle(selected: index == selectedIndex, accent: accent)
        invalidateIntrinsicContentSize()
    }

    func setEnabled(_ enabled: Bool, at index: Int) {
        guard buttons.indices.contains(index) else { return }
        buttons[index].isEnabled = enabled
        buttons[index].alphaValue = enabled ? 1 : 0.35
    }

    func select(_ index: Int) {
        guard buttons.indices.contains(index) else { return }
        selectedIndex = index
        for (position, button) in buttons.enumerated() {
            button.restyle(selected: position == index, accent: accent)
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        // On ne repeint pas ici : c'est le contrôleur qui décide si le
        // changement est accepté, et il rappelle `select` en retour. Une
        // bascule refusée — les notes sans fichier mémorisé, par exemple — ne
        // doit pas s'afficher comme si elle avait eu lieu.
        onSelect?(sender.tag)
    }
}

/// Un segment. Bouton sans bordure dont le fond porte l'état.
private final class SegmentButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 12
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Actif = fond teinté et texte à la teinte, plutôt qu'un aplat saturé
    /// sous du blanc.
    ///
    /// L'aplat plein se voyait de loin, mais il criait : sur une barre qu'on
    /// garde sous les yeux pendant qu'on travaille, c'est fatigant. Un fond à
    /// faible opacité suffit à désigner l'état, et le texte à la teinte le
    /// confirme sans forcer le contraste.
    /// Le segment actif est **turquoise plein, texte sombre**.
    ///
    /// Il était turquoise à 20 % d'opacité avec du texte turquoise clairci :
    /// un état sélectionné qui se lit comme un survol, et qui ne tranchait pas
    /// assez sur le verre du groupe pour qu'on sache d'un coup d'œil quelle
    /// langue écoute. Le prototype pose `background: var(--accent)` et
    /// `color: #042f2e` — c'est la même pastille que les boutons primaires de
    /// la fenêtre de réglages, et elle se voit.
    func restyle(selected: Bool, accent: NSColor) {
        layer?.backgroundColor = selected ? accent.cgColor : NSColor.clear.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: selected
                ? Self.onAccent
                : NSColor.white.withAlphaComponent(0.7),
        ])
    }

    /// Le vert très sombre que le prototype pose sur le turquoise. Du blanc
    /// dessus serait illisible : l'accent est une couleur claire.
    private static let onAccent = NSColor(srgbRed: 0x04 / 255, green: 0x2F / 255,
                                          blue: 0x2E / 255, alpha: 1)

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        // `padding: 4px 10px`.
        size.width += 20
        size.height = 22
        return size
    }
}
