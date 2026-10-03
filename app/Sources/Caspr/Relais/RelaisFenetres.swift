import AppKit
import WebKit
import CasprCore

// Les deux fenêtres du relais, et la vue web qui passe de l'une à l'autre.
//
// Le code le plus fragile du dépôt, et il n'a rien d'évident : leurs
// exigences sont opposées point par point (cf. RELAIS.md, « Les deux
// fenêtres »). La grande prend le clavier et active l'application ; la barre
// ne fait jamais ni l'un ni l'autre, et suit les bureaux. La vue web vit dans
// la barre, rangée hors champ — jamais retirée de l'écran, le système
// suspendant une fenêtre qu'il croit cachée.

/// La barre : la fenêtre qui héberge la page hors des moments de réglage.
///
/// Elle ne prend **jamais** le clavier, et c'est structurel. L'insertion par
/// accessibilité vise l'élément focalisé de l'application au premier plan ; or
/// le pont focalise la zone de saisie de ChatGPT pour la vider. Une barre
/// capable de devenir fenêtre clé ferait donc écrire la dictée dans la page au
/// lieu de l'éditeur — c'est ce qui est arrivé, et l'insertion depuis
/// l'historique tombait dans le même piège.
///
/// Elle suit les bureaux, pour la raison inverse : sans `canJoinAllSpaces`,
/// changer d'écran en pleine dictée la laissait derrière, macOS la comptait
/// alors comme invisible, et WebKit suspendait la page — capture micro
/// comprise.
final class BarreRelais: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Position hors champ de la fenêtre quand le relais travaille en silence.
    ///
    /// La fenêtre reste « devant » du point de vue du serveur de fenêtres,
    /// simplement à des coordonnées que personne ne regarde. C'est délibéré :
    /// une WKWebView dont la fenêtre est retirée de l'écran (`orderOut`) voit
    /// son JavaScript ralenti par le système, ce qui suffirait à faire échouer
    /// l'attente de la transcription.
    static let horsChamp = NSPoint(x: -19_000, y: -20_000)

    /// Rangée hors champ, et décidée telle : rien d'autre que `poser` ne doit
    /// la ramener à l'écran.
    ///
    /// Brancher ou débrancher un écran fait ramener par AppKit, sur un écran
    /// visible, toute fenêtre qui n'est plus sur aucun — et une barre hors
    /// champ ne l'est jamais. Le propriétaire l'a vue, capture à l'appui,
    /// surgir seule au milieu de l'écran sans dictée en cours : pas clé, donc
    /// sourde à Échap, elle y restait jusqu'au cycle de dictée suivant.
    private(set) var rangee = false

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        // Le filet, si AppKit la déplace sans passer par `constrainFrameRect`.
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(aBouge),
                           name: NSWindow.didMoveNotification, object: self)
        centre.addObserver(self, selector: #selector(ecransChanges),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Hors champ, en restant à l'écran (cf. `horsChamp`). L'état vient
    /// après le déplacement : rien ne doit croire rangée une barre qui n'y
    /// est pas encore.
    func ranger() {
        setFrameOrigin(Self.horsChamp)
        rangee = true
    }

    /// Sous les yeux. L'état tombe avant : le filet ne doit pas renvoyer hors
    /// champ une barre qu'on montre — pas même pendant une dictée où l'on
    /// branche un écran.
    func poser(_ cadre: NSRect) {
        rangee = false
        setFrame(cadre, display: true)
    }

    /// Mesuré sur macOS 26 : un panneau sans bordure n'est pas contraint, et
    /// `super` rend déjà `horsChamp` tel quel. Le replacement des écrans passe
    /// donc par un autre chemin, que le filet rattrape ; ceci ne tient la
    /// règle que si AppKit se mettait un jour à contraindre ces panneaux.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        rangee ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// Sans boucle possible : remettre hors champ une barre qui y est déjà ne
    /// la déplace pas.
    @objc private func aBouge() {
        if rangee, frame.origin != Self.horsChamp { setFrameOrigin(Self.horsChamp) }
    }

    /// Au tour suivant : AppKit replace ses fenêtres après avoir dit le
    /// changement, et c'est ce replacement qu'il faut défaire.
    @objc private func ecransChanges() {
        DispatchQueue.main.async { [weak self] in self?.aBouge() }
    }
}

extension RelaisPage {
    // MARK: - Mesures

    static let enVue = NSRect(x: 200, y: 200, width: 980, height: 760)
    /// Juste la pastille de ChatGPT, et rien autour. Plus petite que la barre
    /// de Caspr : la dictée est ce qu'on regarde, le relais n'est qu'un témoin.
    private static let tailleBarre = NSSize(width: 420, height: 62)
    /// Assez d'écart au-dessus de la barre de Caspr pour qu'on lise deux objets
    /// distincts et non un bloc collé.
    private static let hauteurBarre: CGFloat = 218
    /// La page rendue à 65 % : les 420 points de la barre valent alors environ
    /// 650 points CSS. Le dézoom élargit la page que voit ChatGPT, pour qu'il
    /// garde sa mise en page large plutôt que de basculer sur celle des
    /// téléphones, où la pastille se réorganise.
    private static let zoomBarre: CGFloat = 0.65

    // MARK: - Construction

    /// Les deux fenêtres, construites une fois avec la page (cf. `fenetre`
    /// pour ce qui les oppose).
    func construireLesFenetres() {
        fenetre = NSWindow(contentRect: Self.enVue,
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        fenetre.title = "Relais — ChatGPT"
        fenetre.isReleasedWhenClosed = false
        fenetre.delegate = self
        // Pas de `canJoinAllSpaces` ici, délibérément : une fenêtre de réglage
        // qui suit l'utilisateur d'un bureau à l'autre est une fenêtre dont on
        // ne se débarrasse pas.

        barre = BarreRelais(contentRect: NSRect(origin: BarreRelais.horsChamp, size: Self.tailleBarre),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        barre.isReleasedWhenClosed = false
        barre.hidesOnDeactivate = false
        // Un cran **sous** la barre de Caspr, qui vit au niveau `.statusBar`.
        //
        // Au même niveau, celle qui passe devant est la dernière ordonnée : à
        // l'ouverture initiale Caspr gagnait, à l'ouverture en cours de dictée
        // le relais gagnait et recouvrait les pastilles — on ne pouvait plus
        // changer de mode. Un niveau règle l'ordre une fois pour toutes, là où
        // une course le rejoue à chaque fois.
        //
        // La barre de Caspr est celle qu'on manipule ; celle du relais n'est
        // qu'un témoin. Le témoin passe derrière.
        barre.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        barre.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// Barre de navigation au-dessus de la page.
    ///
    /// Elle n'existe pas pour le confort : sans elle, une connexion qui part de
    /// travers — un fournisseur tiers qui refuse, une page de conditions —
    /// laisse l'utilisateur dans un cul-de-sac, sans retour ni rechargement,
    /// et la seule issue est de tuer l'application.
    private func pileAvecBarre() -> NSView {
        func bouton(_ symbole: String, _ titre: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: "", target: self, action: action)
            b.image = NSImage(systemSymbolName: symbole, accessibilityDescription: titre)
            b.bezelStyle = .texturedRounded
            b.toolTip = titre
            return b
        }

        etiquette = NSTextField(labelWithString: "…")
        etiquette.font = .systemFont(ofSize: 11)
        etiquette.textColor = .secondaryLabelColor

        barreNav = NSStackView(views: [
            bouton("chevron.left", "Retour", #selector(retour)),
            bouton("chevron.right", "Suivant", #selector(suivant)),
            bouton("arrow.clockwise", "Recharger", #selector(recharger)),
            bouton("house", "Revenir à ChatGPT", #selector(revenirAccueil)),
            etiquette,
        ])
        barreNav.orientation = .horizontal
        barreNav.spacing = 6
        barreNav.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let pile = NSStackView(views: [barreNav, webView])
        pile.orientation = .vertical
        pile.spacing = 0
        pile.alignment = .width
        barreNav.setContentHuggingPriority(.defaultHigh, for: .vertical)
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return pile
    }

    @objc private func retour() { webView.goBack() }
    @objc private func suivant() { webView.goForward() }
    @objc private func recharger() { webView.reload() }
    @objc private func revenirAccueil() { webView.load(URLRequest(url: Self.accueil)) }

    // MARK: - Montrer, ranger

    /// La grande fenêtre : se connecter, calibrer, récupérer un texte à la main.
    ///
    /// Elle active l'application et devient fenêtre clé, sans quoi ni la saisie
    /// d'un mot de passe ni le copier-coller ne fonctionnent.
    func montrer() {
        webView.removeFromSuperview()
        webView.pageZoom = 1
        Task { _ = await sonder { try await self.compacter(false, sel: self.selecteurs.composeur) } }
        fenetre.contentView = pileAvecBarre()
        barre.orderOut(nil)
        fenetre.setFrame(Self.enVue, display: true)
        fenetre.makeKeyAndOrderFront(nil)
        fenetreCleRetiree = false
        NSApp.activate(ignoringOtherApps: true)
        // Et la vue web reçoit les touches.
        //
        // Rendre la fenêtre active ne suffit pas : sans premier répondant, le
        // curseur clignote dans la page — WebKit le dessine — mais chaque
        // frappe est refusée par la chaîne de réponse, et macOS émet un bip.
        // On voyait donc un champ qui semblait prêt et qui ne l'était pas.
        fenetre.makeFirstResponder(webView)
        Task { await rafraichirEtiquette() }
        surAffichage?()
    }

    /// Ce qu'on montre pendant la dictée, selon le réglage.
    ///
    /// Les trois passent par la **fenêtre de la barre**, jamais par celle des
    /// réglages : quelle que soit sa taille, elle ne doit pas pouvoir prendre
    /// le clavier. Une fenêtre clé ferait écrire la dictée dans la page au lieu
    /// de l'éditeur — c'est le défaut le plus coûteux qu'ait connu ce relais.
    ///
    /// L'afficher, même en barre, règle en prime un défaut ancien : le système
    /// diffère les rendus d'une fenêtre qu'il croit cachée, ce qui retardait
    /// l'apparition du bouton d'arrêt.
    ///
    /// `module` : celui du moment pendant l'écoute — changer de module en
    /// parlant fait suivre son affichage —, le figé ensuite.
    func afficherBarre(module: RelaisModule) {
        let affichage = module.affichageEffectif

        // La grande fenêtre, et pour deux conditions réunies.
        //
        // **Le module ne délivre nulle part** : elle seule peut prendre le
        // clavier, et le clavier ne sert qu'à répondre par écrit dans la
        // conversation. Un module qui écrit au curseur ne doit jamais l'ouvrir
        // — le texte partirait dans ChatGPT.
        //
        // **Et l'affichage demandé est « Page »** : c'était la condition
        // manquante. Une discussion réglée sur « Rien » ouvrait quand même sa
        // fenêtre, alors que ne rien afficher est justement ce qu'on choisit
        // quand la réponse est lue à haute voix — on parle, on écoute, et il
        // n'y a rien à regarder.
        if !module.ecrit, affichage == .page {
            montrer()
            return
        }
        // La grande fenêtre se retire : sans cela elle restait à l'écran,
        // vidée de sa vue web par `rendreLaVueALaBarre`, et l'on voyait un
        // rectangle gris là où l'on attendait sa disparition.
        fenetreCleRetiree = fenetre.isKeyWindow
        fenetre.orderOut(nil)
        rendreLaVueALaBarre()
        // À la fin, une fois la barre posée : Échap lit sa place et sa
        // transparence (cf. `barreEnVue`).
        defer { surAffichage?() }
        let compact = affichage == .barre

        // La page doit être **rendue**, même quand on ne veut rien voir.
        //
        // « Rien » a d'abord été traduit par « fenêtre laissée hors champ ».
        // C'était faux, et du même genre que le défaut qui retardait
        // l'apparition du bouton d'arrêt à la première dictée : le système
        // suspend une page qu'il croit cachée, capture micro comprise. La
        // dictée partait donc sans que rien ne soit enregistré, et ChatGPT
        // répondait n'avoir rien entendu.
        //
        // La fenêtre est donc posée à sa place habituelle et rendue
        // transparente. Elle occupe l'écran sans rien y montrer, et le système
        // n'a plus de raison de la geler.
        webView.pageZoom = compact ? Self.zoomBarre : 1
        // Une page qui se charge encore — le préchauffage du lancement, le fil
        // neuf d'après Réorganiser — n'a ni le pont ni la zone que le
        // compactage vise, et son document neuf n'en garderait rien : la
        // bande montrait le haut de la page pendant toute la dictée. Il
        // attend donc la zone, puis ne s'applique que si la barre est restée
        // compacte entre-temps.
        let chargeait = chargementEnCours || webView.isLoading
        Task {
            if compact, chargeait { _ = await attendreComposeurPret(secondes: 30) }
            guard (webView.pageZoom == Self.zoomBarre) == compact else { return }
            _ = await sonder { try await self.compacter(compact, sel: self.selecteurs.composeur) }
        }

        guard let cadre = NSScreen.main?.visibleFrame else { return }
        // « Barre » et « Rien » à la place de la barre ; « Page » d'un module
        // qui écrit, en grand au milieu — dans la barre tout de même.
        let petite = affichage != .page
        let taille = petite ? Self.tailleBarre : Self.enVue.size
        let y = petite ? cadre.minY + Self.hauteurBarre : cadre.midY - taille.height / 2
        barre.poser(NSRect(origin: NSPoint(x: cadre.midX - taille.width / 2, y: y), size: taille))
        barre.alphaValue = affichage == .rien ? 0 : 1
        barre.ignoresMouseEvents = affichage == .rien
        barre.orderFrontRegardless()
    }

    /// La grande fenêtre est-elle sous les yeux de l'utilisateur ?
    var estVisible: Bool { fenetre.isVisible }

    /// Cette fenêtre est-elle l'une des nôtres — la grande, la barre, ou une
    /// fenêtre que la page a ouverte (une connexion, par exemple) ?
    func possede(_ window: NSWindow) -> Bool {
        window === fenetre || window === barre || annexes.contains { $0 === window }
    }

    /// La barre est-elle sous les yeux — posée sur un écran, et opaque ?
    ///
    /// Elle ne se retire jamais de l'écran (cf. `BarreRelais.horsChamp`) : `isVisible`
    /// vaut vrai rangée comme affichée, et transparente pour « Rien ». Une
    /// discussion réglée sur « Barre » la laisse à l'écran après la dictée,
    /// pendant que la réponse est lue : Échap doit pouvoir la fermer, comme
    /// la grande fenêtre (cf. `Relais.discussionAffichee`).
    var barreEnVue: Bool {
        barre.isVisible && barre.alphaValue > 0
            && NSScreen.screens.contains { $0.frame.intersects(barre.frame) }
    }

    /// Range tout : la grande fenêtre disparaît, la barre repart hors champ.
    ///
    /// Hors champ, et non retirée de l'écran : le système suspend le JavaScript
    /// d'une fenêtre qu'il croit cachée, ce qui suffirait à faire échouer
    /// l'attente d'une transcription.
    func cacher() {
        for annexe in annexes { annexe.close() }
        annexes.removeAll()
        fenetre.orderOut(nil)
        rendreLaVueALaBarre()
        // Rendue opaque avant d'être rangée : la prochaine ouverture part d'une
        // fenêtre normale, et non d'une fenêtre invisible qu'il faudrait penser
        // à rallumer.
        barre.alphaValue = 1
        barre.ignoresMouseEvents = false
        barre.ranger()
        barre.orderFrontRegardless()
        surAffichage?()
    }

    private func rendreLaVueALaBarre() {
        guard webView.superview !== barre.contentView || barre.contentView !== webView else {
            return
        }
        webView.removeFromSuperview()
        fenetre.contentView = nil
        barre.contentView = webView
    }
}

// MARK: - Fermeture

extension RelaisPage: NSWindowDelegate {
    /// Fermer la fenêtre la range, mais ne la retire pas de l'écran.
    ///
    /// `orderOut` ferait ralentir le JavaScript de la WebView par le système,
    /// donc la dictée cesserait de fonctionner après la première fermeture —
    /// une panne d'autant plus déroutante que fermer une fenêtre est le geste
    /// le plus banal qui soit.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Fermer la fenêtre de réglage la range et rend la vue à la barre ;
        // elle ne détruit ni la page ni la session.
        if sender === fenetre {
            surFermeture?()
            cacher()
            NSApp.hide(nil)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let fermee = notification.object as? NSWindow else { return }
        annexes.removeAll { $0 === fermee }
    }
}
