import AppKit
import WebKit

/// La fenêtre du relais, incapable de prendre le clavier hors des moments où
/// l'utilisateur s'en sert lui-même.
///
/// Une fenêtre ordinaire peut devenir la fenêtre clé dès qu'un élément
/// réclame le focus — et le pont en réclame un à chaque dictée, pour vider la
/// zone de saisie. Le curseur système partait alors dans la page ChatGPT :
/// l'insertion par accessibilité écrivait dans son composeur au lieu de
/// l'application de l'utilisateur, et le texte disparaissait sans erreur. La
/// même bascule expliquait les insertions manquées depuis l'historique.
final class RelaisFenetre: NSPanel {
    /// La fenêtre accepte-t-elle le clavier ?
    ///
    /// C'est **la** question dont tout dépendait sans qu'on le voie. L'insertion
    /// par accessibilité vise l'élément focalisé de l'application au premier
    /// plan. Or le pont focalise la zone de saisie de ChatGPT pour la vider :
    /// si cette fenêtre peut prendre le clavier, Caspr devient l'application qui
    /// détient le champ focalisé, et le texte dicté s'écrit dans la page au lieu
    /// de l'éditeur. L'insertion depuis l'historique tombait dans le même piège,
    /// non parce qu'elle aurait un lien avec ChatGPT, mais parce qu'elle emprunte
    /// le même chemin système.
    ///
    /// Trois états, trois endroits seulement : `montrer()` l'ouvre pour la
    /// connexion, la calibration ou la récupération après un échec ;
    /// `afficherBarre()` et `cacher()` le referment. Le faux est le défaut.
    var accepteLeClavier = false
    override var canBecomeKey: Bool { accepteLeClavier }
    override var canBecomeMain: Bool { accepteLeClavier }
}

/// La page ChatGPT, hébergée par le relais plutôt que par un navigateur.
///
/// Piloter le Chrome de l'utilisateur était l'autre option. Elle a été écartée
/// pour trois raisons concrètes : il faut activer « Autoriser JavaScript depuis
/// les Apple Events » dans le menu Développement, il faut qu'un onglet ChatGPT
/// reste ouvert en permanence, et le texte dicté transiterait par la vraie
/// session de navigation de l'utilisateur — donc dans son historique et dans
/// ses brouillons. Une WKWebView à nous n'a aucun de ces défauts : session
/// isolée, fenêtre invisible, rien à configurer dans Chrome.
///
/// Le prix : il faut se connecter une fois à ChatGPT dedans. Les cookies sont
/// persistés par `WKWebsiteDataStore.default()`, donc une seule fois.
@MainActor
final class RelaisPage: NSObject {
    enum Erreur: LocalizedError {
        case introuvable(RelaisCible)
        case pasDeTexte
        case zoneJamaisRevenue
        case pasConnecte
        case refusParChatGPT(String)

        var errorDescription: String? {
            switch self {
            case .introuvable(let c):
                "Impossible de trouver \(c.libelle) dans la page. Calibrer à nouveau ?"
            case .pasDeTexte:
                "ChatGPT n'a rien transcrit."
            case .zoneJamaisRevenue:
                "ChatGPT n'a pas rendu la transcription. Le texte est peut-être "
                + "encore dans la fenêtre du relais — rien n'a été rechargé."
            case .pasConnecte:
                "Pas connecté à ChatGPT. Ouvrez la fenêtre du relais et connectez-vous."
            case .refusParChatGPT(let message):
                "ChatGPT a refusé la dictée : \(message)"
            }
        }
    }

    /// Ce que le relais sait de la session, à un instant donné.
    enum Connexion { case connecte, deconnecte, inconnu }

    static let accueil = URL(string: "https://chatgpt.com/")!

    private var webView: WKWebView!
    private var fenetre: RelaisFenetre!
    private var etiquette: NSTextField!
    /// La rangée de navigation, masquée quand la fenêtre se réduit à sa barre.
    private var barreNav: NSStackView!
    /// Les fenêtres de connexion ouvertes par la page (OAuth, conditions).
    /// Retenues pour ne pas être libérées pendant que l'utilisateur s'en sert.
    private var annexes: [NSWindow] = []
    var selecteurs = RelaisSelecteurs.charger()

    /// Position hors champ de la fenêtre quand le relais travaille en silence.
    ///
    /// La fenêtre reste « devant » du point de vue du serveur de fenêtres,
    /// simplement à des coordonnées que personne ne regarde. C'est délibéré :
    /// une WKWebView dont la fenêtre est retirée de l'écran (`orderOut`) voit
    /// son JavaScript ralenti par le système, ce qui suffirait à faire échouer
    /// l'attente de la transcription.
    private static let horsChamp = NSPoint(x: -19_000, y: -20_000)
    private static let enVue = NSRect(x: 200, y: 200, width: 980, height: 760)
    /// Juste la pastille de ChatGPT, et rien autour. Plus petite que la barre
    /// de Caspr : la dictée est ce qu'on regarde, le relais n'est qu'un témoin.
    private static let tailleBarre = NSSize(width: 420, height: 62)
    /// Assez d'écart au-dessus de la barre de Caspr pour qu'on lise deux objets
    /// distincts et non un bloc collé.
    private static let hauteurBarre: CGFloat = 218
    /// La page rendue à 55 % : 500 points d'écran valent alors 900 points CSS,
    /// assez pour quJe réduis le zoom, je peux réduire la width. Je vais réduire la width.e ChatGPT garde sa mise en page large plutôt que de basculer
    /// sur celle des téléphones, où la pastille se réorganise.
    private static let zoomBarre: CGFloat = 0.65

    override init() {
        super.init()
        construire()
    }

    // MARK: - Construction

    private func construire() {
        let config = WKWebViewConfiguration()
        // Store par défaut, donc persistant : la connexion à ChatGPT survit au
        // redémarrage. Un store non persistant obligerait à se reconnecter à
        // chaque lancement, ce qui condamnerait l'usage.
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.pont,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))

        webView = WKWebView(frame: Self.enVue, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // On garde l'agent utilisateur par défaut de WebKit, qui est celui de
        // Safari. En inventer un attirerait exactement l'attention qu'on ne
        // veut pas.

        fenetre = RelaisFenetre(contentRect: Self.enVue,
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        fenetre.title = "Relais — ChatGPT"
        fenetre.contentView = pileAvecBarre()
        fenetre.isReleasedWhenClosed = false
        fenetre.hidesOnDeactivate = false
        // Le même comportement que la barre de Caspr, et pour une raison plus
        // forte que la symétrie : sans `canJoinAllSpaces`, la fenêtre reste sur
        // le bureau où elle est née. Changer de bureau la laissait derrière,
        // macOS la comptait alors comme invisible, et WebKit suspendait la page
        // — capture micro comprise. ChatGPT répondait « je n'ai pas compris »,
        // et plus aucun de nos clics n'aboutissait.
        //
        // C'est exactement la différence qui faisait que Caspr suivait d'un
        // écran à l'autre et que le relais non.
        fenetre.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        fenetre.delegate = self
        cacher()
        charger()
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
    @objc private func revenirAccueil() { charger() }

    func charger() {
        webView.load(URLRequest(url: Self.accueil))
    }

    // MARK: - Fenêtre

    /// Montre la fenêtre en grand, et lui rend le clavier — pour se connecter,
    /// calibrer, ou récupérer à la main un texte qu'on n'a pas su lire.
    func montrer() {
        fenetre.accepteLeClavier = true
        fenetre.level = .normal
        barreNav.isHidden = false
        fenetre.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        fenetre.title = "Relais — ChatGPT"
        // La page reprend sa taille et son décor : c'est ici qu'on se connecte,
        // qu'on calibre, et qu'on récupère un texte à la main.
        webView.pageZoom = 1
        Task { _ = try? await appeler("return window.__relais.compacter(false, sel);",
                                      ["sel": selecteurs.composeur]) }
        fenetre.setFrame(Self.enVue, display: true)
        fenetre.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await rafraichirEtiquette() }
    }

    /// Repousse la fenêtre hors champ sans la retirer de l'écran.
    func cacher() {
        fenetre.accepteLeClavier = false
        fenetre.level = .normal
        // Rendue à son état complet avant d'être rangée : la prochaine
        // ouverture en grand part d'une fenêtre normale, pas d'une barre sans
        // bord qu'il faudrait penser à rhabiller.
        barreNav.isHidden = false
        fenetre.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        fenetre.title = "Relais — ChatGPT"
        webView.pageZoom = 1
        for annexe in annexes { annexe.close() }
        annexes.removeAll()
        fenetre.setFrameOrigin(Self.horsChamp)
        fenetre.orderFrontRegardless()
    }

    // MARK: - État de la session

    /// Connecté ou non, vu depuis la page.
    ///
    /// Le critère est la présence de la zone de saisie : elle n'existe que dans
    /// l'application, jamais sur les écrans de connexion. Plus fiable qu'un
    /// cookie, dont le nom est un détail d'implémentation d'OpenAI.
    ///
    /// On réinterroge pendant quelques secondes parce que ChatGPT est une
    /// application monopage : au retour de `didFinish`, le composeur n'est pas
    /// encore monté, et un relevé unique conclurait « déconnecté » à tort.
    func etatConnexion(patience: Int = 12) async -> Connexion {
        for essai in 0..<max(patience, 1) {
            let r = try? await appeler(
                "return window.__relais.etat(micro, stop);",
                ["micro": selecteurs.micro, "stop": selecteurs.stop])
            if let r {
                if r["connecte"] as? Bool == true { return .connecte }
                if r["authentification"] as? Bool == true { return .deconnecte }
            }
            if essai < patience - 1 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        return .deconnecte
    }

    private func rafraichirEtiquette() async {
        etiquette?.stringValue = "vérification…"
        switch await etatConnexion() {
        case .connecte:
            etiquette?.stringValue = selecteurs.estCalibre
                ? "Connecté et calibré — la touche de dictée écrit par ChatGPT."
                : "Connecté. Reste à calibrer les boutons."
        case .deconnecte:
            etiquette?.stringValue = "Pas encore connecté."
        case .inconnu:
            etiquette?.stringValue = ""
        }
    }

    // MARK: - Appels au pont

    @discardableResult
    private func appeler(_ corps: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let brut = try await webView.callAsyncJavaScript(
            corps, arguments: args, in: nil, contentWorld: .page)
        return (brut as? [String: Any]) ?? [:]
    }

    /// La page est-elle en train d'écouter ?
    ///
    /// C'est la page qui fait foi, pas un drapeau tenu de notre côté. Un
    /// drapeau local se désynchronise à la première erreur — et il l'a fait :
    /// après un échec, l'application se croyait au repos pendant que ChatGPT
    /// enregistrait toujours, si bien que le geste suivant relançait une
    /// dictée par-dessus au lieu de l'arrêter.
    func estEnEnregistrement() async -> Bool {
        let r = try? await appeler("return window.__relais.etat(micro, stop);",
                                   ["micro": selecteurs.micro, "stop": selecteurs.stop])
        return r?["enregistrement"] as? Bool == true
    }

    /// Clique le micro. La page commence à écouter.
    func demarrer() async throws {
        // Vingt secondes, et non huit dixièmes : au tout premier appui d'une
        // session, la page peut encore être en train de se charger. Conclure
        // « pas connecté » à cet instant-là revenait à demander un second appui.
        guard await etatConnexion(patience: 50) == .connecte else {
            montrer()
            throw Erreur.pasConnecte
        }
        // Vider la zone **avant** d'écouter. Une dictée dont la lecture a
        // échoué laisse son texte dans la page — délibérément, pour qu'il reste
        // récupérable à la main. Mais ChatGPT ajoute la dictée suivante à la
        // suite au lieu de remplacer, si bien que le texte suivant arrivait
        // collé au précédent, et le suivant encore aux deux.
        _ = try? await appeler("return window.__relais.vider(sel);",
                               ["sel": selecteurs.composeur])
        guard try await cliquerQuandDisponible(.micro, selecteurs.micro, secondes: 8) else {
            throw Erreur.introuvable(.micro)
        }
    }

    /// Clique l'arrêt, puis attend que le texte apparaisse et se stabilise.
    ///
    /// Deux attentes distinctes, et c'est tout l'objet de cette méthode.
    ///
    /// **La zone de saisie doit d'abord revenir.** Pendant la dictée, ChatGPT
    /// la retire du DOM au profit de la barre d'onde. Au moment où l'on clique
    /// l'arrêt, elle n'existe donc pas — et la première version en concluait
    /// « introuvable » sur-le-champ, ce qui échouait à tous les coups.
    ///
    /// **Le texte doit ensuite cesser de bouger.** Il arrive par fragments :
    /// lire au premier caractère rendrait une phrase tronquée.
    func arreterEtLire(secondesDictees: Double) async throws -> String {
        // Après l'arrêt, ChatGPT passe par un état intermédiaire — le mot
        // « Transcription » et une roue — pendant lequel la zone de saisie
        // n'est toujours pas là. Sa durée suit celle de la dictée : quelques
        // secondes pour trente secondes de parole, bien plus pour dix minutes.
        //
        // C'est ce que la version précédente n'avait pas vu. Elle vérifiait
        // « la page a-t-elle cessé d'écouter ? » en regardant si le bouton
        // d'arrêt avait disparu — or il ne disparaît pas tout de suite. Sur une
        // dictée courte la transcription arrivait dans les deux secondes
        // d'observation et tout allait bien ; sur une dictée longue, elle
        // concluait que l'arrêt n'avait pas répondu, rechargeait la page, et
        // détruisait une transcription qui était en train d'aboutir. D'où la
        // corrélation avec la longueur, qui n'en était pas une avec la taille
        // du texte mais avec le temps d'attente.
        //
        // On n'essaie plus de distinguer « écoute encore » de « transcrit » :
        // le seul signal fiable est le retour de la zone de saisie, et il
        // signifie exactement ce qu'on attend.
        guard try await cliquerQuandDisponible(.stop, selecteurs.stop, secondes: 15) else {
            throw Erreur.introuvable(.stop)
        }

        // Le budget suit la dictée, avec un plancher large. Une transcription
        // ne doit jamais être abandonnée parce qu'un chiffre écrit d'avance la
        // jugeait trop lente.
        let budget = max(180.0, secondesDictees * 4)
        var revenue = false
        for tour in 0..<Int(budget * 4) {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            if lu?["ok"] as? Bool == true { revenue = true; break }
            // Une fois par seconde : la page dit parfois elle-même qu'elle a
            // échoué, et l'attendre trois minutes de plus n'apprend rien.
            if tour % 4 == 3, let message = await erreurAffichee() {
                throw Erreur.refusParChatGPT(message)
            }
        }
        guard revenue else { throw Erreur.zoneJamaisRevenue }

        // Phase 2 : la stabilisation. Une seconde pleine sans changement, et
        // non 500 ms : le flux marque entre deux fragments des pauses plus
        // longues qu'on ne l'imagine, et c'est précisément là que le seuil
        // précédent coupait la phrase.
        var precedent = ""
        var stable = 0
        for _ in 0..<240 {                                  // 60 s
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            let texte = (lu?["texte"] as? String) ?? ""
            if !texte.isEmpty && texte == precedent {
                stable += 1
                if stable >= 4 {                            // ~1 s sans changement
                    // On ne vide pas ici. `demarrer()` le fait avant chaque
                    // dictée, ce qui suffit à empêcher toute concaténation, et
                    // vider exige de focaliser la zone — l'opération même qui
                    // détournait le curseur système. La faire à l'instant
                    // précis où Caspr s'apprête à insérer au curseur serait le
                    // pire moment possible. Le texte laissé dans la page est
                    // en prime un filet : il reste copiable si l'insertion
                    // échoue.
                    return texte
                }
            } else {
                stable = 0
            }
            precedent = texte
        }
        throw Erreur.pasDeTexte
    }

    /// Clique un bouton, en lui laissant le temps d'exister.
    ///
    /// Un relevé unique supposait que la page ait fini de se remettre à jour à
    /// l'instant où on l'interroge. Elle ne l'a pas toujours fait : sa fenêtre
    /// vit hors champ, donc le système la considère cachée et diffère ses
    /// rendus. Le bouton d'arrêt, qui n'apparaît qu'en réaction au clic sur le
    /// micro, arrivait après notre question — d'où l'échec de la première
    /// dictée de chaque session, et le succès de toutes les suivantes, la
    /// fenêtre ayant entre-temps été affichée à la main.
    ///
    /// Attendre coûte quelques centaines de millisecondes dans le cas normal,
    /// où le bouton est là au premier essai.
    private func cliquerQuandDisponible(_ cible: RelaisCible, _ selecteur: String,
                                        secondes: Double) async throws -> Bool {
        for essai in 0..<Int(secondes * 4) {
            try Task.checkCancellation()
            let r = try await appeler("return window.__relais.cliquer(cible, sel);",
                                      ["cible": cible.rawValue, "sel": selecteur])
            if r["ok"] as? Bool == true {
                if essai > 0 { Log.info("relais : \(cible.rawValue) trouvé après \(essai) essais") }
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// La barre : juste assez de page pour voir ChatGPT écouter, posée
    /// au-dessus de celle de Caspr.
    ///
    /// Elle ne prend jamais le clavier — c'est sa raison d'être autant que son
    /// utilité. Et l'afficher pendant la dictée règle au passage un défaut
    /// ancien : le système diffère les rendus d'une fenêtre qu'il croit cachée,
    /// ce qui retardait l'apparition du bouton d'arrêt et faisait échouer la
    /// première dictée de chaque session.
    func afficherBarre() {
        fenetre.accepteLeClavier = false
        fenetre.level = .statusBar
        // Ni titre ni navigation : ils servent à se connecter et à se dépanner,
        // pas à regarder une dictée en cours, et ils faisaient à eux seuls la
        // moitié de la hauteur.
        barreNav.isHidden = true
        fenetre.styleMask = [.borderless, .nonactivatingPanel]
        webView.pageZoom = Self.zoomBarre
        Task { _ = try? await appeler("return window.__relais.compacter(true, sel);",
                                      ["sel": selecteurs.composeur]) }
        guard let ecran = NSScreen.main else { return }
        let cadre = ecran.visibleFrame
        // Juste au-dessus de la barre de Caspr, qui vit à +90 du bas.
        fenetre.setFrame(NSRect(x: cadre.midX - Self.tailleBarre.width / 2,
                                y: cadre.minY + Self.hauteurBarre,
                                width: Self.tailleBarre.width,
                                height: Self.tailleBarre.height),
                         display: true)
        fenetre.orderFrontRegardless()
    }

    /// Ferme tout : la vue, ses fenêtres annexes, et le processus de contenu
    /// qui va avec. C'est lui qui garde le micro de la machine.
    func detruire() {
        for annexe in annexes { annexe.close() }
        annexes.removeAll()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        fenetre.delegate = nil
        fenetre.contentView = nil
        fenetre.close()
    }

    /// Le message d'échec que ChatGPT affiche, s'il y en a un.
    private func erreurAffichee() async -> String? {
        let r = try? await appeler("return window.__relais.erreur();")
        let message = (r?["message"] as? String) ?? ""
        return message.isEmpty ? nil : message
    }

    /// La page tient-elle le micro en ce moment ?
    var microOuvert: Bool { webView.microphoneCaptureState != WKMediaCaptureState.none }

    /// Rend le micro que la page tenait.
    ///
    /// C'est la régression la plus grave qu'ait causée le relais : après une
    /// dictée ChatGPT, la page gardait le flux ouvert, et la dictée suivante
    /// sur la touche principale n'enregistrait que du silence. Le moteur
    /// répondait « rien n'a été entendu », et rien ne désignait le relais —
    /// dont l'utilisateur avait toute raison de croire qu'il ne servait que sur
    /// l'autre touche.
    ///
    /// WebKit expose exactement ce qu'il faut : couper la capture au niveau de
    /// la vue, sans toucher à la page ni à la session.
    func rendreLeMicro() async {
        guard webView.microphoneCaptureState != WKMediaCaptureState.none else { return }
        await webView.setMicrophoneCaptureState(.none)
        Log.info("relais : micro rendu")
    }

    /// Remet la page à plat après un échec.
    ///
    /// Recharger est brutal mais sûr : une dictée interrompue laisse la page
    /// dans un état qu'on ne sait pas nommer, et sans issue l'utilisateur reste
    /// enfermé dans la barre d'onde — ce qui est arrivé.

    /// Annule une dictée en cours sans rien récupérer.
    func annuler() async {
        _ = try? await appeler("return window.__relais.cliquer('stop', sel);",
                               ["sel": selecteurs.stop])
        _ = try? await appeler("return window.__relais.vider(sel);",
                               ["sel": selecteurs.composeur])
    }

    /// Attend que l'utilisateur clique un élément, et en retient un sélecteur.
    ///
    /// Le clic n'est pas intercepté : il atteint la page normalement. C'est
    /// nécessaire — le bouton d'arrêt n'existe dans le DOM que pendant
    /// l'enregistrement, donc il faut que le clic sur le micro ait réellement
    /// démarré l'écoute pour pouvoir désigner l'arrêt juste après.
    func calibrer(_ cible: RelaisCible) async throws -> String {
        let r = try await appeler("return await window.__relais.calibrer();")
        guard let sel = r["selecteur"] as? String, !sel.isEmpty else {
            throw Erreur.introuvable(cible)
        }
        selecteurs[cible] = sel
        selecteurs.enregistrer()
        return sel
    }
}

// MARK: - Fenêtre

extension RelaisPage: NSWindowDelegate {
    /// Fermer la fenêtre la range, mais ne la retire pas de l'écran.
    ///
    /// `orderOut` ferait ralentir le JavaScript de la WebView par le système,
    /// donc la dictée cesserait de fonctionner après la première fermeture —
    /// une panne d'autant plus déroutante que fermer une fenêtre est le geste
    /// le plus banal qui soit.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === fenetre {
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

// MARK: - Micro, popups, navigation

extension RelaisPage: WKUIDelegate, WKNavigationDelegate {
    /// Sans cette réponse, `getUserMedia` est refusé en silence dans une
    /// WKWebView : le bouton micro semble ne rien faire, aucune erreur
    /// n'apparaît, et il n'y a rien à voir dans la console de la page.
    ///
    /// L'autorisation est restreinte aux hôtes attendus. Une WebView qui
    /// accorderait le micro à n'importe quelle origine deviendrait un micro
    /// ouvert pour n'importe quelle page où une redirection l'emmènerait.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let hote = origin.host
        let autorise = hote == "chatgpt.com" || hote.hasSuffix(".chatgpt.com")
                    || hote == "openai.com"  || hote.hasSuffix(".openai.com")
        decisionHandler(autorise ? .grant : .deny)
    }

    /// Une fenêtre séparée pour ce que la page ouvre en popup.
    ///
    /// La première version chargeait ces URL dans la vue principale. C'était un
    /// piège : le popup de connexion remplaçait la page ChatGPT, et comme il
    /// n'a par construction ni barre d'adresse ni bouton retour, l'utilisateur
    /// se retrouvait enfermé dans un formulaire tiers sans aucune issue.
    ///
    /// La configuration reçue en paramètre doit être réutilisée telle quelle :
    /// c'est elle qui rattache la nouvelle vue à la même session, donc au même
    /// jeu de cookies. En construire une autre ferait échouer la connexion.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let cadre = NSRect(x: 0, y: 0, width: 560, height: 720)
        let vue = WKWebView(frame: cadre, configuration: configuration)
        vue.uiDelegate = self
        vue.navigationDelegate = self

        let panneau = NSPanel(contentRect: cadre,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        panneau.title = "Connexion"
        panneau.contentView = vue
        panneau.isReleasedWhenClosed = false
        panneau.delegate = self
        panneau.center()
        panneau.makeKeyAndOrderFront(nil)
        annexes.append(panneau)
        return vue
    }

    /// La page demande la fermeture de son propre popup — typiquement à la fin
    /// d'une connexion réussie.
    func webViewDidClose(_ webView: WKWebView) {
        guard let panneau = annexes.first(where: { $0.contentView === webView }) else { return }
        panneau.close()
        Task { await rafraichirEtiquette() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else {
            // Un popup a fini de naviguer : la connexion a pu aboutir dans la
            // fenêtre principale sans qu'elle en soit informée.
            Task { await rafraichirEtiquette() }
            return
        }
        Task { await rafraichirEtiquette() }
    }
}
