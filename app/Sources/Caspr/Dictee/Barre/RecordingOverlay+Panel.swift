import AppKit
import AVFoundation
import QuartzCore

// La construction de la barre et la disposition de ses rangées : ce qui ne
// sert qu'à monter le panneau, puis à le recomposer quand les langues, les
// modules ou les écrans changent.
extension RecordingOverlay {
    func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Visible au-dessus du plein écran et sur tous les bureaux : dicter en
        // travaillant ailleurs est précisément l'usage.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // La fenêtre elle-même ne dessine rien : les onglets doivent flotter
        // *à côté* de la carte, séparés par du vide, et non dans un même bloc.
        let root = NSView()
        panel.contentView = root

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Self.accent.withAlphaComponent(0.35).cgColor
        // L'ombre portée du prototype (`0 16px 36px rgba(0, 0, 0, 0.6)`) est
        // déjà rendue par `panel.hasShadow` : macOS la dérive de l'alpha du
        // contenu. La reposer sur le calque obligerait à lever
        // `masksToBounds`, donc à laisser le flou déborder des coins.
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)

        // Le fond de fenêtre de l'application, et rien d'autre.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.casprWindow.cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            tint.topAnchor.constraint(equalTo: card.topAnchor),
            tint.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        // Le reflet du verre : une lumière rasante en haut, qui s'éteint vers
        // le bas. C'est ce dégradé, plus que la transparence, qui donne
        // l'impression d'une surface et non d'un rectangle gris.
        let sheen = CAGradientLayer()
        sheen.colors = [NSColor.white.withAlphaComponent(0.10).cgColor,
                        NSColor.white.withAlphaComponent(0.02).cgColor,
                        NSColor.clear.cgColor]
        sheen.locations = [0, 0.35, 1]
        tint.layer?.addSublayer(sheen)
        cardSheen = sheen
        self.card = card

        buildIndicators()
        buildControls()

        let recording = makeRow([dot, timeLabel, meter, NSView(), micButton, cancelButton])
        let tabs = makeSpacedRow([moduleControl, targetControl])
        recordingRow = recording
        textRow = tabs

        let inner = NSStackView(views: [recording, previewLabel])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = Self.rowSpacing
        inner.translatesAutoresizingMaskIntoConstraints = false
        container = inner

        card.addSubview(inner)
        card.addSubview(waitCancelButton)
        waitCancelButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        root.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let height = previewLabel.heightAnchor.constraint(
            equalToConstant: Self.previewLineHeight)
        height.isActive = true
        previewHeight = height

        // Deux ancrages hauts pour la carte, un seul actif à la fois : masquer
        // les onglets ne suffit pas, une contrainte reste en vigueur même
        // quand la vue qu'elle vise est cachée. Sans ça, l'état
        // « Transcription… » gardait la place des onglets et la carte se
        // retrouvait écrasée sur quelques pixels.
        // Les onglets sont l'**étage 2, sous la carte** — c'est la géométrie du
        // prototype, et elle se tient : la carte porte ce qu'on écoute, les
        // onglets ce qu'on en fait. Posés au-dessus, ils s'interposaient entre
        // le regard et le texte reconnu, qui est la seule chose qu'on lit
        // vraiment pendant qu'on parle.
        // Les modules passent **au-dessus**, à droite. Ils n'apparaissent que
        // sous le relais : le laisser en bas obligeait la rangée du bas à se
        // réorganiser selon le moteur, et la destination changeait de place
        // d'une dictée à l'autre. En haut, il apparaît et disparaît sans rien
        // déplacer de ce qui reste.
        root.addSubview(moduleControl)
        NSLayoutConstraint.activate([
            moduleControl.topAnchor.constraint(equalTo: root.topAnchor),
            moduleControl.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                  constant: -6),
        ])
        cardBelowModules = card.topAnchor.constraint(equalTo: moduleControl.bottomAnchor,
                                                  constant: Self.tabGap)
        cardAtTop = card.topAnchor.constraint(equalTo: root.topAnchor)

        tabsBelowCard = tabs.topAnchor.constraint(equalTo: card.bottomAnchor,
                                                  constant: Self.tabGap)
        cardAlone = card.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        tabsBelowCard?.isActive = true

        NSLayoutConstraint.activate([
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // `padding: 0 6px` : les groupes affleurent la carte sans la
            // dépasser, leur ombre portée comprise.
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            tabs.heightAnchor.constraint(equalToConstant: Self.controlRowHeight),

            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                           constant: Self.padding + 4),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                            constant: -(Self.padding + 4)),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.padding),

            recording.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            recording.widthAnchor.constraint(equalTo: inner.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: inner.widthAnchor),

            waitCancelButton.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                                       constant: -Self.padding),
            waitCancelButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            // La carte ne s'élargit plus pour accueillir le message : il faut
            // donc qu'il tienne dedans. Les messages d'échec sont déjà écrits
            // pour ça (cf. `Livraison.conserver`), et la troncature
            // est le filet pour ceux qui viendraient du système.
            statusLabel.widthAnchor.constraint(
                lessThanOrEqualTo: card.widthAnchor,
                constant: -2 * Self.padding),
        ])
        return panel
    }

    /// La rangée du bas : les langues à gauche, la destination à droite.
    ///
    /// Trois compositions à gauche, selon ce qu'il y a à choisir :
    ///
    /// - **Plusieurs langues, jusqu'à trois** : les pastilles de bascule.
    /// - **Au-delà de trois** : un menu, qui dit la langue en cours sans
    ///   élargir la barre.
    /// - **Une seule** : un simple indicateur, qui dit dans quelle langue on
    ///   parle.
    /// - **Sous ChatGPT, aperçu en direct activé** : le badge de la voie, et
    ///   le menu des langues de l'aperçu à côté (cf.
    ///   `Status.badgeAvecLesLangues`).
    ///
    /// Les modules ne sont pas ici : ils sont passés **au-dessus de la carte, à
    /// droite** (cf. `makePanel`). Ils n'apparaissent que sous le relais, et
    /// les laisser en bas obligeait cette rangée à se réorganiser selon le
    /// moteur — la destination changeait alors de place d'une dictée à
    /// l'autre.
    ///
    /// Appelée à chaque mise à jour, mais ne fait rien tant que la composition
    /// ne change pas : reconstruire des contraintes vingt fois par seconde
    /// pendant une dictée serait absurde.
    func layoutTabs(switchable: Bool, usesMenu: Bool, badge: Bool) {
        let wanted = Layout(switchable: switchable, usesMenu: usesMenu, badge: badge)
        guard wanted != tabsLayout || textRow == nil else { return }
        tabsLayout = wanted
        guard let row = textRow else { return }
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // Les langues à gauche, la destination à droite.
        // Le badge part d'abord de la composition précédente : un groupe
        // détaché le retiendrait encore.
        languageBadge.removeFromSuperview()
        let langues: NSView = usesMenu ? languageMenu : languageControl
        let left: NSView = !switchable ? languageBadge
            : (badge ? makeRow([languageBadge, langues]) : langues)
        fill(row, with: [left, targetControl])
    }

    /// La rangée des modules, montrée ou cachée à **chaque** mise à jour.
    ///
    /// Hors de `layoutTabs`, qui sort tôt quand la composition de la rangée du
    /// bas n'a pas bougé : la rangée du haut ne serait alors jamais rétablie
    /// après une transcription ou un échec, qui la cachent tous deux.
    func layoutModules(show: Bool) {
        moduleControl.isHidden = !show
        cardBelowModules?.isActive = show
        cardAtTop?.isActive = !show
    }

    /// Un seul module n'est pas un choix : la pastille n'apparaît qu'à deux.
    var showsModules: Bool { status.moduleLabels.count > 1 }

    struct Layout: Equatable {
        var switchable: Bool
        var usesMenu: Bool
        var badge: Bool
    }

    /// Rangée `space-between` : les groupes sont plaqués aux bords.
    ///
    /// C'était `space-evenly`, entretoises de bord comprises, ce qui ramenait
    /// les deux groupes vers le centre — ils flottaient au milieu de la barre
    /// au lieu d'en tenir les extrémités, et l'ensemble ne ressemblait plus à
    /// la maquette. Le prototype pose `justify-content: space-between` : rien
    /// aux bords, tout l'espace entre les groupes.
    private func makeSpacedRow(_ views: [NSView]) -> NSStackView {
        let row = makeRow([])
        row.spacing = 0
        fill(row, with: views)
        return row
    }

    /// Pose les contrôles, et une entretoise **entre** chacun — aucune au bord.
    private func fill(_ row: NSStackView, with views: [NSView]) {
        guard !views.isEmpty else { return }
        var spacers: [NSView] = []
        for (index, view) in views.enumerated() {
            if index > 0 {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
                spacers.append(spacer)
                row.addArrangedSubview(spacer)
            }
            row.addArrangedSubview(view)
        }
        // Avec trois contrôles, les deux intervalles doivent rester égaux,
        // sinon celui du milieu n'est pas au centre.
        for spacer in spacers.dropFirst() {
            spacer.widthAnchor.constraint(equalTo: spacers[0].widthAnchor).isActive = true
        }
    }

    private func makeRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        // La vue vide sert d'entretoise : elle seule doit s'étirer.
        for view in views where type(of: view) == NSView.self {
            view.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        }
        return row
    }

    private func buildIndicators() {
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        timeLabel.textColor = .labelColor
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .center
        // Deux lignes possibles depuis que l'échec porte sa phrase de secours.
        // Sans lever le mode ligne unique, le `\n` qui les sépare s'afficherait
        // comme une espace et la seconde ligne serait tronquée avec la
        // première.
        statusLabel.usesSingleLineMode = false
        statusLabel.cell?.wraps = true
        statusLabel.maximumNumberOfLines = 1
        languageBadge.font = .systemFont(ofSize: 11, weight: .medium)
        languageBadge.textColor = .tertiaryLabelColor
        languageBadge.alignment = .center

        // Italique et discret : l'aperçu ne doit jamais être pris pour le
        // texte qui sera inséré.
        previewLabel.font = NSFontManager.shared.convert(
            .systemFont(ofSize: Self.previewFontSize), toHaveTrait: .italicFontMask)
        previewLabel.textColor = .secondaryLabelColor
        // Repli simple : la coupe est faite en amont, sur la chaîne, donc
        // AppKit n'a plus qu'à mettre à la ligne.
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.maximumNumberOfLines = Self.previewLines
        previewLabel.usesSingleLineMode = false
        previewLabel.cell?.wraps = true
        // Sans ça, le champ impose sa largeur naturelle au panneau : mesuré,
        // une fenêtre de 1164 px pour un écran de 1728, le texte sortant par
        // la droite. Un libellé doit céder, c'est le panneau qui commande.
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            meter.widthAnchor.constraint(equalToConstant: 46),
            meter.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func buildControls() {
        for (button, action) in [(micButton, #selector(openMicrophoneModes))] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.target = self
            button.action = action
            // Réagit sans que Caspr passe au premier plan.
            button.setButtonType(.momentaryChange)
        }
        for button in [cancelButton, waitCancelButton] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.setButtonType(.momentaryChange)
            button.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                   accessibilityDescription: "Tout annuler")
            button.contentTintColor = .tertiaryLabelColor
            button.toolTip = "Tout annuler — rien n'est inséré\nLe texte déjà transcrit reste dans le menu de Caspr"
            button.target = self
            button.action = #selector(annulerDepuisLaBarre)
        }
        waitCancelButton.isHidden = true

        moduleControl.onSelect = { [weak self] index in
            self?.onSelectModule?(index)
        }
        targetControl.onSelect = { [weak self] index in
            self?.onSelectTarget?(index == 1)
        }
        languageMenu.target = self
        languageMenu.action = #selector(pickLanguageFromMenu)
        languageControl.onSelect = { [weak self] index in
            guard let codes = self?.languageCodes, codes.indices.contains(index)
            else { return }
            self?.onSelectLanguage?(codes[index])
        }
    }

    @objc private func pickLanguageFromMenu(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard menuCodes.indices.contains(index) else { return }
        onSelectLanguage?(menuCodes[index])
    }

    /// Jette le panneau après un changement d'écrans, et le remonte aussitôt
    /// si une dictée est en cours — sinon la barre disparaîtrait en plein
    /// milieu d'une phrase.
    func rebuildForNewScreens() {
        guard panel != nil else { return }
        let wasRecording = isRecording
        let elapsed = startedAt

        stopProcessingGlow()
        panel?.orderOut(nil)
        panel = nil
        tabsBelowCard = nil
        cardAlone = nil
        cardBelowModules = nil
        cardAtTop = nil
        container = nil
        recordingRow = nil
        textRow = nil
        card = nil
        cardSheen = nil
        tabsLayout = nil
        NSLog("caspr: écrans modifiés — panneau reconstruit")

        guard wasRecording else { return }
        showRecording(status)
        startedAt = elapsed          // le chrono ne repart pas de zéro
    }

    /// Bas de l'écran, centré — hors du regard et du texte en cours de saisie,
    /// mais visible du coin de l'œil.
    func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + 90))
    }

    @objc private func annulerDepuisLaBarre() {
        onCancel?()
    }

    @objc private func openMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}
