import AppKit
import WebKit
import CasprCore

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
}


@MainActor
final class RelaisPage: NSObject {
    enum Erreur: LocalizedError {
        case introuvable(RelaisCible)
        case pasConnecte
        case pasDeReponse
        /// L'échéance de la dictée est passée (cf. `RelaisAttente`).
        case attenteEpuisee(RelaisAttente.Abandon)
        case consigneNonPosee
        case refusParChatGPT(String)
        /// Le pont n'a pas répondu dans le délai : la page est figée.
        case pontMuet
        /// WebKit a fermé la page pendant la dictée ; elle a été rechargée.
        case pageInterrompue
        /// Personne n'a cliqué pendant qu'un guetteur de calibration attendait.
        case calibrationSansClic(RelaisCible)
        /// Le relais a été éteint pendant la dictée : la page n'existe plus,
        /// et n'est pas reconstruite (cf. `Relais.pageActive`).
        case relaisEteint

        /// Ce que la barre affiche, quand la raison générique mentirait.
        ///
        /// « Réessayer dans le menu » ne veut rien dire pour le relais, qui ne
        /// garde pas d'audio. Pour ces cas-là, la raison elle-même est ce
        /// qu'on a besoin de lire — surtout le texte d'un refus, qui dit
        /// d'emblée si c'est un quota et non une panne.
        var raisonCourte: String? {
            switch self {
            case .refusParChatGPT(let message):
                let court = message.count > 90 ? String(message.prefix(89)) + "…" : message
                return "ChatGPT : \(court)"
            case .attenteEpuisee(let abandon): return abandon.raisonCourte
            case .pontMuet: return "ChatGPT ne répond plus — page rechargée, réessayez"
            case .pageInterrompue: return "La page ChatGPT s'est fermée — dictée perdue"
            case .relaisEteint: return "ChatGPT désactivé pendant la dictée"
            default: return nil
            }
        }

        /// La transcription peut-elle être encore dans la page ?
        ///
        /// Non quand la page est morte : celle qu'on ouvrirait pour l'y
        /// chercher est une page neuve et vide, et promettre le contraire
        /// envoyait fouiller une fenêtre où rien ne subsistait.
        var laissePeutEtreLeTexte: Bool {
            switch self {
            case .pageInterrompue, .relaisEteint: false
            default: true
            }
        }

        var errorDescription: String? {
            switch self {
            case .introuvable(let c):
                "Impossible de trouver \(c.libelle) dans la page. Calibrer à nouveau ?"
            case .pasConnecte:
                "Pas connecté à ChatGPT. Ouvrez la fenêtre du relais et connectez-vous."
            case .pasDeReponse:
                "ChatGPT n'a pas répondu. La transcription brute est dans l'historique."
            case .attenteEpuisee(let abandon):
                abandon.explication
            case .consigneNonPosee:
                "La consigne de reformulation n'a pas pu être ajoutée au texte."
            case .refusParChatGPT(let message):
                "ChatGPT a affiché une erreur : « \(message) »"
            case .pontMuet:
                "La page ChatGPT ne répond plus. Elle est rechargée — réessayez dans "
                + "un instant."
            case .pageInterrompue:
                "WebKit a fermé la page ChatGPT pendant la dictée. Elle a été rechargée, "
                + "mais ce qui avait été dit est perdu."
            case .calibrationSansClic(let c):
                "Aucun clic sur \(c.libelle) en trois minutes : la calibration est "
                + "abandonnée. Relancez-la quand vous serez prêt."
            case .relaisEteint:
                "ChatGPT Web Preview a été désactivé pendant la dictée : elle est "
                + "abandonnée, et la page ChatGPT fermée."
            }
        }
    }

    /// Ce que le relais sait de la session, à un instant donné.
    enum Connexion { case connecte, deconnecte, inconnu }

    private static let cleDepart = "relais.pointDeDepart"

    /// La page d'où part chaque conversation.
    ///
    /// Par défaut chatgpt.com, qui ouvre un fil neuf. Mais on peut lui
    /// substituer n'importe quelle page de ChatGPT — typiquement un projet
    /// dédié : les conversations qu'y crée Caspr s'y rangent alors, groupées et
    /// à l'écart des vraies. Une dictée par conversation, c'est vite un
    /// historique noyé.
    ///
    /// Une URL et non un bouton à calibrer, et c'est ce qui la rend solide :
    /// elle ne dépend d'aucun élément de la page, donc rien ne casse au
    /// prochain remaniement de ChatGPT.
    ///
    /// L'hôte est vérifié à la lecture comme à l'écriture. Une adresse
    /// enregistrée est rechargée à chaque dictée sans que personne ne la
    /// relise : elle doit rester ce qu'elle prétend être.
    static var depart: URL {
        get {
            guard let s = UserDefaults.standard.string(forKey: cleDepart),
                  let url = URL(string: s), estChatGPT(url) else { return accueil }
            return url
        }
        set {
            guard estChatGPT(newValue) else { return }
            UserDefaults.standard.set(newValue.absoluteString, forKey: cleDepart)
        }
    }

    static var departEstPersonnalise: Bool { depart != accueil }

    static func reinitialiserDepart() {
        UserDefaults.standard.removeObject(forKey: cleDepart)
    }

    static func estChatGPT(_ url: URL) -> Bool {
        guard let hote = url.host() else { return false }
        return hote == "chatgpt.com" || hote.hasSuffix(".chatgpt.com")
    }

    static let accueil = URL(string: "https://chatgpt.com/")!

    private var webView: WKWebView!
    /// Les deux fenêtres, et pourquoi elles ne peuvent pas n'en faire qu'une.
    ///
    /// Leurs exigences sont opposées, point par point. La grande sert à se
    /// connecter et à calibrer : elle doit prendre le clavier — sans quoi ni
    /// saisie ni copier-coller — activer l'application, et rester sur le bureau
    /// où on l'a ouverte. La barre sert à regarder une dictée : elle ne doit
    /// jamais prendre le clavier, ne jamais activer l'application, et suivre
    /// les bureaux.
    ///
    /// Une seule fenêtre qui changeait de costume ne pouvait pas satisfaire les
    /// deux. En particulier `.nonactivatingPanel`, nécessaire à la barre, rend
    /// le copier-coller impossible dans l'autre rôle : cliquer une telle
    /// fenêtre ne rend pas l'application active, et ⌘C part alors vers celle
    /// qui l'est.
    ///
    /// La vue web passe de l'une à l'autre. Elle vit dans la barre par défaut,
    /// rangée hors champ quand personne ne dicte — jamais retirée de l'écran,
    /// puisque le système suspend une fenêtre qu'il croit cachée.
    private var fenetre: NSWindow!
    private var barre: BarreRelais!
    private var etiquette: NSTextField!
    /// La rangée de navigation, masquée quand la fenêtre se réduit à sa barre.
    private var barreNav: NSStackView!
    /// Les fenêtres de connexion ouvertes par la page (OAuth, conditions).
    /// Retenues pour ne pas être libérées pendant que l'utilisateur s'en sert.
    private var annexes: [NSWindow] = []
    /// Vrai entre l'ordre de chargement et la fin de la navigation.
    ///
    /// Sans ce drapeau, attendre « la zone de saisie » revenait à interroger la
    /// **page précédente** : elle est encore là quelques centaines de
    /// millisecondes après l'ordre de rechargement, et la réponse arrivait donc
    /// tout de suite, sur le mauvais document. On écrivait le prompt dans une
    /// page qui allait disparaître.
    private var chargementEnCours = false
    /// Combien de fois WebKit a tué le processus de contenu de la page.
    ///
    /// La page reste ouverte d'une dictée à l'autre, des semaines durant : sous
    /// pression mémoire, le système finit par tuer son processus. Elle est
    /// alors rechargée — mais une dictée qui attendait sa transcription
    /// continuerait d'interroger la page neuve, qui n'en sait rien, jusqu'à
    /// l'expiration de sa patience. Le compteur, relevé au départ de la dictée,
    /// lui dit que la page qu'elle attend n'existe plus.
    private var morts = 0
    private var mortsAuDepart = 0
    /// Les alertes que la page affichait avant qu'on lui demande quelque chose.
    ///
    /// Une bannière déjà là n'est pas une réponse à notre demande — celle d'un
    /// quota « bientôt atteint » reste affichée des jours. Seule une alerte
    /// apparue depuis peut en être une.
    private var alertesAvant: [String] = []
    /// Le nombre de réponses de ChatGPT dans la page au moment d'envoyer.
    ///
    /// C'est ce qui distingue la réponse attendue de la précédente : dans une
    /// discussion, le fil en porte déjà une, finie et immobile, qui passerait
    /// sinon pour celle qu'on attend.
    private var reponsesAvantEnvoi = 0
    var selecteurs = RelaisSelecteurs.charger()

    /// Appelé quand l'utilisateur ferme la grande fenêtre.
    ///
    /// Fermer une fenêtre est le geste par lequel on dit « j'arrête ». Une
    /// calibration qui continuerait derrière attendrait un clic dans une
    /// fenêtre qu'on vient de faire disparaître.
    var surFermeture: (() -> Void)?

    /// Appelé quand WebKit a tué la page, après l'ordre de rechargement.
    ///
    /// Les attentes de la transcription l'apprennent seules, à leur tour
    /// suivant. Mais pendant l'écoute, aucune n'est en cours : sans cet
    /// avertissement, on continuait de parler devant une page morte jusqu'à
    /// l'appui d'arrêt, et tout ce qui avait été dit entre-temps était perdu
    /// sans que rien ne le dise.
    var surMort: (() -> Void)?

    /// Appelé quand une fenêtre du relais apparaît ou se range.
    ///
    /// Échap en dépend : il n'est pris, hors enregistrement, que devant une
    /// fenêtre à fermer (cf. `Relais.discussionAffichee`). La fermeture
    /// passe par des chemins que le cycle de dictée ne voit pas — le bouton
    /// rouge, une calibration qui s'achève — et c'est donc la fenêtre qui le
    /// dit.
    var surAffichage: (() -> Void)?

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
    /// assez pour que ChatGPT garde sa mise en page large plutôt que de basculer
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

        fenetre = NSWindow(contentRect: Self.enVue,
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        fenetre.title = "Relais — ChatGPT"
        fenetre.isReleasedWhenClosed = false
        fenetre.delegate = self
        // Pas de `canJoinAllSpaces` ici, délibérément : une fenêtre de réglage
        // qui suit l'utilisateur d'un bureau à l'autre est une fenêtre dont on
        // ne se débarrasse pas.

        barre = BarreRelais(contentRect: NSRect(origin: Self.horsChamp, size: Self.tailleBarre),
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
    @objc private func revenirAccueil() { webView.load(URLRequest(url: Self.accueil)) }

    func charger() {
        chargementEnCours = true
        webView.load(URLRequest(url: Self.depart))
    }

    /// L'adresse affichée, pour que les réglages puissent l'adopter.
    var adresseCourante: URL? { webView.url }

    // MARK: - Fenêtre

    /// La grande fenêtre : se connecter, calibrer, récupérer un texte à la main.
    ///
    /// Elle active l'application et devient fenêtre clé, sans quoi ni la saisie
    /// d'un mot de passe ni le copier-coller ne fonctionnent.
    func montrer() {
        webView.removeFromSuperview()
        webView.pageZoom = 1
        Task { _ = try? await appeler("return window.__relais.compacter(false, sel);",
                                      ["sel": selecteurs.composeur]) }
        fenetre.contentView = pileAvecBarre()
        barre.orderOut(nil)
        fenetre.setFrame(Self.enVue, display: true)
        fenetre.makeKeyAndOrderFront(nil)
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
    func afficherBarre() {
        let module = RelaisCatalogue.courant
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
        if module.sortieParDefaut == .aucune, affichage == .page {
            montrer()
            return
        }
        // La grande fenêtre se retire : sans cela elle restait à l'écran,
        // vidée de sa vue web par `rendreLaVueALaBarre`, et l'on voyait un
        // rectangle gris là où l'on attendait sa disparition.
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
        Task { _ = try? await appeler("return window.__relais.compacter(actif, sel);",
                                      ["actif": compact, "sel": selecteurs.composeur]) }

        guard let ecran = NSScreen.main else { return }
        let cadre = ecran.visibleFrame
        let taille = compact || affichage == .rien ? Self.tailleBarre : Self.enVue.size
        barre.setFrame(NSRect(x: cadre.midX - taille.width / 2,
                              y: compact || affichage == .rien
                                 ? cadre.minY + Self.hauteurBarre
                                 : cadre.midY - taille.height / 2,
                              width: taille.width,
                              height: taille.height),
                       display: true)
        barre.alphaValue = affichage == .rien ? 0 : 1
        barre.ignoresMouseEvents = affichage == .rien
        barre.orderFrontRegardless()
    }

    /// La grande fenêtre est-elle sous les yeux de l'utilisateur ?
    var estVisible: Bool { fenetre.isVisible }

    /// La barre est-elle sous les yeux — posée sur un écran, et opaque ?
    ///
    /// Elle ne se retire jamais de l'écran (cf. `horsChamp`) : `isVisible`
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
        barre.setFrameOrigin(Self.horsChamp)
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
    ///
    /// `.inconnu` quand la page ne répond pas du tout : ce n'est pas une
    /// session fermée, et le dire ferait chercher un mot de passe là où il
    /// faut recharger.
    func etatConnexion(patience: Int = 12) async -> Connexion {
        for essai in 0..<max(patience, 1) {
            do {
                let r = try await appeler(
                    "return window.__relais.etat(micro, stop, composeur);",
                    ["micro": selecteurs.micro, "stop": selecteurs.stop,
                     "composeur": selecteurs.composeur])
                if r["connecte"] as? Bool == true { return .connecte }
                if r["authentification"] as? Bool == true { return .deconnecte }
            } catch Erreur.pontMuet {
                return .inconnu
            } catch is CancellationError {
                return .inconnu
            } catch {
                // Le pont n'est pas encore injecté — la page se charge. On
                // réinterroge, c'est l'objet de la patience.
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
            etiquette?.stringValue = "La page ne répond pas — rechargez-la."
        }
    }

    // MARK: - Appels au pont

    /// Le délai d'un appel ordinaire au pont.
    ///
    /// Toutes ses fonctions sont synchrones côté page — lire, cliquer, vider —
    /// et répondent en quelques millisecondes. Un appel muet cinq secondes ne
    /// répondra plus : la page est figée, et c'est ce qu'il faut dire.
    nonisolated static let delaiPont: Duration = .seconds(5)
    /// Le délai des guetteurs de calibration, qui attendent une main humaine :
    /// le temps de lire la consigne, de trouver le bouton, d'hésiter.
    nonisolated static let delaiClic: Duration = .seconds(180)

    /// Un appel au pont, qui rend toujours la main.
    ///
    /// C'était la seule attente réellement infinie du relais. Chaque boucle
    /// d'attente est bâtie autour de cet appel : un appel qui ne revient
    /// jamais empêche la boucle de tourner, donc son compteur d'expirer — et
    /// la préparation de la page, franchie avant chaque enregistrement, en
    /// fait quatre. Un seul suffisait à geler la dictée avant même que la
    /// barre n'affiche l'écoute.
    ///
    /// `callAsyncJavaScript` ne s'annule pas : le délai n'arrête rien dans la
    /// page, il fait seulement cesser d'attendre ici. L'annulation de la tâche
    /// appelante produit le même effet, pour que la touche de dictée
    /// interrompe aussi un appel resté en suspens.
    @discardableResult
    private func appeler(_ corps: String, _ args: [String: Any] = [:],
                         delai: Duration = RelaisPage.delaiPont) async throws -> [String: Any] {
        // Une tâche déjà annulée ne touche plus à la page : le clic qu'elle
        // demandait n'est plus voulu par personne.
        try Task.checkCancellation()
        let vue: WKWebView = webView
        let attente = AttenteDuPont()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { suite in
                attente.attacher(suite)
                attente.minuteur = Task { [weak attente] in
                    do { try await Task.sleep(for: delai) } catch { return }
                    attente?.rendre(.failure(Erreur.pontMuet))
                }
                Task {
                    do {
                        let brut = try await vue.callAsyncJavaScript(
                            corps, arguments: args, in: nil, contentWorld: .page)
                        attente.rendre(.success((brut as? [String: Any]) ?? [:]))
                    } catch {
                        attente.rendre(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in attente.rendre(.failure(CancellationError())) }
        }
    }

    /// Lève `pageInterrompue` si la page que la dictée attend n'existe plus.
    private func verifierLaPage() throws {
        guard morts == mortsAuDepart else { throw Erreur.pageInterrompue }
    }

    /// Ce que la page affiche à cet instant — ses alertes, et combien de
    /// réponses de ChatGPT elle porte — pour ne compter ensuite que ce qui est
    /// apparu depuis.
    private func relever() async -> (alertes: [String], reponses: Int) {
        let r = try? await appeler("return window.__relais.releve();")
        return ((r?["alertes"] as? [String]) ?? [], (r?["reponses"] as? Int) ?? 0)
    }

    /// La page est-elle en train d'écouter ?
    ///
    /// C'est la page qui fait foi, pas un drapeau tenu de notre côté. Un
    /// drapeau local se désynchronise à la première erreur — et il l'a fait :
    /// après un échec, l'application se croyait au repos pendant que ChatGPT
    /// enregistrait toujours, si bien que le geste suivant relançait une
    /// dictée par-dessus au lieu de l'arrêter.
    func estEnEnregistrement() async -> Bool {
        let r = try? await appeler("return window.__relais.etat(micro, stop, composeur);",
                                   ["micro": selecteurs.micro, "stop": selecteurs.stop,
                                    "composeur": selecteurs.composeur])
        return r?["enregistrement"] as? Bool == true
    }

    /// La page porte-t-elle une conversation ?
    ///
    /// Posée à la page, et non déduite du module qui vient de tourner : une
    /// réorganisation qui échoue à mi-chemin a tout de même envoyé son message,
    /// et c'est la page qui le sait.
    ///
    /// `nil` quand la page ne répond pas : ni oui ni non, et la seule
    /// préparation qui vaille alors est de la recharger.
    func tientUneConversation() async -> Bool? {
        guard let r = try? await appeler("return window.__relais.etat(micro, stop, composeur);",
                                         ["micro": selecteurs.micro, "stop": selecteurs.stop,
                                          "composeur": selecteurs.composeur])
        else { return nil }
        return r["conversation"] as? Bool == true
    }

    /// Clique le micro. La page commence à écouter.
    func demarrer() async throws {
        // La page que cette dictée va attendre est celle d'aujourd'hui.
        mortsAuDepart = morts
        // Vingt secondes, et non huit dixièmes : au tout premier appui d'une
        // session, la page peut encore être en train de se charger. Conclure
        // « pas connecté » à cet instant-là revenait à demander un second appui.
        switch await etatConnexion(patience: 50) {
        case .connecte:
            break
        case .inconnu:
            try Task.checkCancellation()
            throw Erreur.pontMuet
        case .deconnecte:
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
        alertesAvant = await relever().alertes
        guard try await cliquerQuandDisponible(.micro, selecteurs.micro,
                                               jusqua: .now.addingTimeInterval(8)) else {
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
    ///
    /// Les deux attentes vont jusqu'à l'échéance de la dictée, et plus
    /// jusqu'à un budget chacune : la stabilisation avait sa minute à elle,
    /// qui s'ajoutait à celle de la transcription.
    func arreterEtLire(_ attente: RelaisAttente) async throws -> String {
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
        guard try await cliquerQuandDisponible(.stop, selecteurs.stop,
                                               jusqua: attente.limite(dans: 15)) else {
            try attente.verifier()
            throw Erreur.introuvable(.stop)
        }

        // L'échéance de la dictée, qui suit sa durée avec un plancher large.
        // Une transcription ne doit jamais être abandonnée parce qu'un chiffre
        // écrit d'avance la jugeait trop lente.
        //
        // Une échéance plutôt qu'un nombre de tours : chaque tour interroge la
        // page, et un tour dont l'appel attend son délai n'aurait plus duré un
        // quart de seconde. Compter les tours laissait donc une page figée
        // multiplier la patience par vingt.
        var revenue = false
        var tour = 0
        while !attente.expiree {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            if lu?["ok"] as? Bool == true { revenue = true; break }
            // Une fois par seconde : la page dit parfois elle-même qu'elle a
            // échoué, et l'attendre trois minutes de plus n'apprend rien.
            if tour % 4 == 3, let message = await erreurAffichee(nouvelles: false) {
                throw Erreur.refusParChatGPT(message)
            }
            tour += 1
        }
        guard revenue else {
            // Une alerte apparue pendant l'attente est la meilleure explication
            // qu'on ait. Elle n'interrompt pas l'attente — une bannière sans
            // rapport aurait sinon fait jeter une transcription qui aboutissait
            // — mais elle dit pourquoi l'attente a échoué.
            if let message = await erreurAffichee(nouvelles: true) {
                throw Erreur.refusParChatGPT(message)
            }
            throw attente.epuisee()
        }

        // Phase 2 : la stabilisation. Une seconde pleine sans changement, et
        // non 500 ms : le flux marque entre deux fragments des pauses plus
        // longues qu'on ne l'imagine, et c'est précisément là que le seuil
        // précédent coupait la phrase.
        var precedent = ""
        var stable = 0
        var vide = 0
        while !attente.expiree {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            // Un appel resté sans réponse ne dit rien du texte : le compter
            // comme une zone vide finirait par conclure « rien n'a été dit »
            // devant une page simplement lente.
            guard let lu = try? await appeler("return window.__relais.lire(sel);",
                                              ["sel": selecteurs.composeur])
            else { continue }
            let texte = (lu["texte"] as? String) ?? ""

            // La zone est revenue et reste vide : il n'y avait rien à
            // transcrire. Appuyer sur la touche sans parler est un geste
            // ordinaire — on se ravise, on est interrompu — et il laissait la
            // barre sur « Transcription… » jusqu'à l'expiration d'une minute,
            // sans autre issue qu'Échap.
            //
            // Quatre secondes, et non une : dans le cas normal, la zone
            // revient déjà remplie, mais rien ne garantit que les deux
            // arrivent au même instant. Attendre un peu coûte moins qu'un faux
            // « rien entendu » sur une dictée réelle.
            if texte.isEmpty {
                vide += 1
                if vide >= 16 {
                    // Sauf si la page dit pourquoi : un refus — un quota
                    // atteint, par exemple — rend lui aussi la zone vide, et
                    // « avez-vous parlé ? » ferait chercher la panne au micro.
                    if let message = await erreurAffichee(nouvelles: true) {
                        throw Erreur.refusParChatGPT(message)
                    }
                    Log.info("relais : la zone est revenue vide — rien n'a été dicté")
                    return ""
                }
            } else {
                vide = 0
            }

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
        throw attente.epuisee()
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
    ///
    /// Une date de fin et non une durée : après l'arrêt de l'écoute, la borne
    /// propre au bouton ne doit jamais dépasser l'échéance de la dictée (cf.
    /// `RelaisAttente.limite`).
    private func cliquerQuandDisponible(_ cible: RelaisCible, _ selecteur: String,
                                        jusqua limite: Date) async throws -> Bool {
        var essai = 0
        repeat {
            try Task.checkCancellation()
            try verifierLaPage()
            let r = try await appeler("return window.__relais.cliquer(cible, sel);",
                                      ["cible": cible.rawValue, "sel": selecteur])
            if r["ok"] as? Bool == true {
                if essai > 0 { Log.info("relais : \(cible.rawValue) trouvé après \(essai) essais") }
                return true
            }
            essai += 1
            try? await Task.sleep(for: .milliseconds(250))
        } while Date.now < limite
        return false
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
        barre.contentView = nil
        barre.close()
    }

    /// Le message d'essai de la calibration.
    ///
    /// Court et explicite : il part réellement dans la conversation de
    /// l'utilisateur, et il vaut mieux qu'on comprenne pourquoi en le relisant
    /// six mois plus tard.
    static let essai = "Bonjour — message d'essai envoyé par Caspr pour repérer les "
                     + "boutons de la page. Réponds simplement « c'est noté »."

    /// Écrit un message d'essai, pour que le bouton d'envoi apparaisse.
    ///
    /// Il n'existe pas tant que la zone est vide — ChatGPT y met son bouton de
    /// dictée à la place. On ne peut donc pas le désigner sans lui donner une
    /// raison d'être là.
    ///
    /// L'écriture est **vérifiée**, et c'est tout l'objet de cette méthode. La
    /// version précédente écrivait une fois et considérait l'affaire close.
    /// Or la zone de saisie existe dans le DOM avant que ChatGPT n'en ait
    /// repris le contrôle : le texte y était bien déposé, puis effacé par le
    /// rendu qui suivait. L'utilisateur se retrouvait devant une zone vide,
    /// sans bouton d'envoi à désigner, et sans rien qui explique pourquoi.
    ///
    /// Par les heuristiques, et non par le repère qu'on vient d'apprendre : on
    /// est au milieu d'une calibration, et s'appuyer sur ce qu'elle est en
    /// train de remplacer est précisément ce qui a produit le message « le
    /// message d'essai n'a pas pu être écrit » devant une zone où il était
    /// pourtant écrit. Le repère désignait le bloc autour de la zone ; on
    /// relisait donc un conteneur, qui n'a pas de texte à lui.
    func preparerCalibrationEnvoi() async -> Bool {
        charger()
        guard await attendreComposeur(secondes: 30, selecteur: "") else { return false }
        let limite = Date.now.addingTimeInterval(6)
        var essai = 0
        while Date.now < limite {
            if Task.isCancelled { return false }
            _ = try? await appeler("return window.__relais.ecrire(sel, texte);",
                                   ["sel": "", "texte": Self.essai])
            try? await Task.sleep(for: .milliseconds(500))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": ""])
            if let texte = lu?["texte"] as? String, !texte.isEmpty {
                if essai > 0 { Log.info("relais : message d'essai écrit au \(essai + 1)e essai") }
                return true
            }
            essai += 1
        }
        return false
    }

    /// Encadre la transcription déjà présente, l'envoie, et rend la réponse.
    ///
    /// Aucun rechargement au milieu du chemin, et c'est le changement de fond.
    /// La version précédente rechargeait la page pour ouvrir un fil neuf, puis
    /// réécrivait la transcription entière avec la consigne devant. Trois
    /// défauts d'un coup : on interrogeait la page qu'on était en train de
    /// quitter, on demandait à un éditeur ProseMirror d'avaler dix minutes de
    /// texte d'un coup, et le moindre accroc laissait la zone dans un état
    /// qu'on ne savait plus nommer.
    ///
    /// Le texte est déjà là. On n'ajoute que la consigne, à ses deux bouts.
    ///
    /// Le fil neuf, lui, est ouvert **après** — quand la réponse est lue et que
    /// plus rien n'est en jeu. La page est alors prête pour la dictée suivante,
    /// et le contexte ne s'accumule pas d'une note à l'autre.
    /// Envoie sans rien rapatrier, et **sans ouvrir de fil neuf**.
    ///
    /// Le pendant de `reorganiserSurPlace` pour une sortie qui n'écrit nulle
    /// part. Deux différences, et toutes deux découlent de la sortie : on ne
    /// clique pas « copier » puisque rien n'est à insérer, et on ne recharge
    /// pas puisque le contexte de la conversation est précisément ce qu'on veut
    /// garder. Recharger ici détruirait ce que le module existe pour offrir.
    func envoyerSansAttendre(_ encadrement: (avant: String, apres: String),
                             attente: RelaisAttente) async throws {
        attente.entrer(.envoi)
        // Une transcription qui a pris tout le temps de la dictée ne laisse
        // rien pour la suite : on n'entame pas un envoi qu'on abandonnerait à
        // mi-chemin, consigne posée dans la zone.
        try attente.verifier()
        if !encadrement.avant.isEmpty || !encadrement.apres.isEmpty {
            let r = try await appeler("return window.__relais.encadrer(sel, avant, apres);",
                                      ["sel": selecteurs.composeur,
                                       "avant": encadrement.avant,
                                       "apres": encadrement.apres])
            guard r["ok"] as? Bool == true else { throw Erreur.introuvable(.composeur) }
            guard try await attendreEncadrement(empreinte(encadrement.avant), attente) else {
                throw Erreur.consigneNonPosee
            }
        }
        (alertesAvant, reponsesAvantEnvoi) = await relever()
        guard try await cliquerQuandDisponible(.envoi, selecteurs.envoi,
                                               jusqua: attente.limite(dans: 10)) else {
            try attente.verifier()
            throw Erreur.introuvable(.envoi)
        }
    }

    func reorganiserSurPlace(_ encadrement: (avant: String, apres: String),
                             attente: RelaisAttente) async throws -> String {
        attente.entrer(.envoi)
        try attente.verifier()                     // cf. `envoyerSansAttendre`
        let r = try await appeler("return window.__relais.encadrer(sel, avant, apres);",
                                  ["sel": selecteurs.composeur,
                                   "avant": encadrement.avant,
                                   "apres": encadrement.apres])
        guard r["ok"] as? Bool == true else { throw Erreur.introuvable(.composeur) }

        // Attendre que l'insertion ait pris, et non une demi-seconde décidée
        // d'avance. L'envoi partait avant que l'éditeur n'ait validé le texte
        // ajouté : seule la transcription brute était expédiée, sans la
        // consigne qui lui donne son sens. Un délai fixe marcherait jusqu'au
        // jour où la machine rame ; une relecture, non.
        guard try await attendreEncadrement(empreinte(encadrement.avant), attente) else {
            throw Erreur.consigneNonPosee
        }

        (alertesAvant, reponsesAvantEnvoi) = await relever()
        guard try await cliquerQuandDisponible(.envoi, selecteurs.envoi,
                                               jusqua: attente.limite(dans: 10)) else {
            try attente.verifier()
            throw Erreur.introuvable(.envoi)
        }
        attente.entrer(.reponse)
        // Le bouton de ChatGPT quand on sait où il est, la lecture du DOM
        // sinon — pour ne pas casser une configuration antérieure.
        let reponse = selecteurs.saitCopier
            ? try await copierReponse(attente: attente,
                                      empreinteEnvoyee: empreinte(encadrement.avant))
            : try await attendreReponse(attente: attente)
        // Pas de rechargement ici : la page neuve est ouverte à l'appui
        // suivant, pour toutes les dictées et au même endroit. En recharger une
        // seconde fois depuis ce chemin-ci, c'était une deuxième politique de
        // fil neuf — celle qui ne s'appliquait qu'aux réorganisations réussies,
        // et laissait donc la conversation en place quand elles échouaient.
        return reponse
    }

    /// La dernière ligne non vide de la consigne — le délimiteur.
    ///
    /// Meilleure empreinte que le début du texte : elle est courte, très
    /// distinctive, et elle ne souffre pas de la façon dont la page replie les
    /// espaces d'un long paragraphe.
    private func empreinte(_ avant: String) -> String {
        avant.split(separator: "\n").last.map(String.init) ?? avant
    }

    /// Attend que la consigne soit réellement dans la zone de saisie.
    private func attendreEncadrement(_ empreinte: String,
                                     _ attente: RelaisAttente) async throws -> Bool {
        guard !empreinte.isEmpty else { return true }
        let limite = attente.limite(dans: 6)
        while Date.now < limite {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            if let texte = lu?["texte"] as? String, texte.contains(empreinte) { return true }
        }
        try attente.verifier()
        Log.error("relais : la consigne n'a pas tenu dans la zone de saisie")
        return false
    }

    /// Attend que la page rechargée soit prête, zone de saisie comprise.
    ///
    /// **Sans se fier au calibrage.** C'est le point qui manquait : une
    /// calibration s'appuyait sur les repères qu'elle allait remplacer, et
    /// ceux-ci peuvent être absents — c'est le premier lancement — ou faux,
    /// c'est-à-dire exactement la raison pour laquelle on recalibre. On a ainsi
    /// « vidé » un bouton micro que le calibrage désignait comme la zone de
    /// texte, avant de conclure que la zone était vide parce qu'un bouton n'a
    /// pas de contenu. Les heuristiques du pont, elles, ne dépendent de rien.
    func attendreComposeurPret(secondes: Double) async -> Bool {
        let limite = Date.now.addingTimeInterval(secondes)
        while Date.now < limite {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
            guard !chargementEnCours else { continue }
            let lu = try? await appeler("return window.__relais.lire(sel);", ["sel": ""])
            if lu?["ok"] as? Bool == true { return true }
        }
        return false
    }

    /// Calibre « Lire à haute voix », menu compris s'il y en a un.
    func calibrerLecture() async throws {
        let r = try await guetter("return await window.__relais.calibrerAvecMenu();", [:],
                                  .lecture)
        guard r["ok"] as? Bool == true else { throw CancellationError() }
        guard let sel = r["selecteur"] as? String, !sel.isEmpty else {
            throw Erreur.introuvable(.lecture)
        }
        selecteurs.lecture = sel
        selecteurs.lectureParent = (r["parent"] as? String) ?? ""
        selecteurs.lectureMenu = (r["menu"] as? String) ?? ""
        selecteurs.lectureMenuParent = (r["menuParent"] as? String) ?? ""
        selecteurs.enregistrer()
    }

    /// Attend que la réponse soit terminée, puis la fait lire à haute voix.
    ///
    /// Deux temps, parce que le bouton se cache parfois derrière un menu — la
    /// calibration a retenu le chemin complet, on le refait. Un module de
    /// traduction peut ainsi parler : on dicte en français, l'interlocuteur
    /// entend la réponse.
    ///
    /// La fin de la génération ne se lit plus au bloc du bouton « copier ».
    /// Ce repère est facultatif de bout en bout — la calibration l'enregistre
    /// vide quand aucun ancêtre n'est retrouvable — et, vide, il faisait
    /// attendre trois minutes à chaque dictée pour rien. Deux signaux qui ne
    /// demandent aucune calibration le remplacent : une réponse **nouvelle**
    /// existe, le bouton qui arrête la génération a disparu, et son texte ne
    /// bouge plus depuis deux secondes. Le premier écarte la réponse
    /// précédente, finie et immobile, qu'une discussion porte déjà.
    ///
    /// Un échec n'interrompt rien : la réponse est à l'écran, seul le son
    /// manque. Faire échouer la dictée entière pour un haut-parleur muet serait
    /// disproportionné.
    ///
    /// Sauf un refus : un quota atteint, et aucune réponse ne viendra. Le
    /// guetter comme `copierReponse`, une fois par seconde, évite d'attendre
    /// l'échéance pour rien ; il est rendu pour que la barre le montre, comme
    /// l'échéance elle-même quand elle passe sans réponse.
    ///
    /// - Parameter auPlus: une borne plus courte que l'échéance, quand la
    ///   réponse est déjà connue pour finie — après une copie, il ne reste
    ///   qu'à la voir immobile, et le texte attend pour s'insérer.
    @discardableResult
    func faireLireLaReponse(attente: RelaisAttente,
                            auPlus: TimeInterval? = nil) async -> Erreur? {
        guard selecteurs.saitLire else { return nil }
        attente.entrer(.reponse)
        let limite = auPlus.map { attente.limite(dans: $0) } ?? attente.echeance
        var precedent = ""
        var stable = 0
        var prete = false
        var tour = 0
        var silences = 0
        while Date.now < limite {
            defer { tour += 1 }
            if Task.isCancelled || morts != mortsAuDepart { return nil }
            try? await Task.sleep(for: .milliseconds(250))
            if tour % 4 == 3, let message = await refusPendantLAttente(silences: &silences) {
                Log.error("relais : ChatGPT a refusé (« \(message) »), lecture abandonnée")
                return .refusParChatGPT(message)
            }
            guard let r = try? await appeler("return window.__relais.etatReponse(avant);",
                                             ["avant": reponsesAvantEnvoi]),
                  r["nouvelle"] as? Bool == true
            else { stable = 0; continue }
            let texte = (r["texte"] as? String) ?? ""
            if r["enCours"] as? Bool != true, !texte.isEmpty, texte == precedent {
                stable += 1
                if stable >= 8 { prete = true; break }      // ~2 s sans changement
            } else {
                stable = 0
            }
            precedent = texte
        }
        guard prete else {
            Log.error("relais : réponse jamais prête, lecture à haute voix abandonnée")
            // L'attente a expiré : une alerte apparue depuis l'envoi est la
            // meilleure explication qu'on ait. À défaut, l'échéance passée
            // en est une, et elle se dit.
            if let message = await erreurAffichee(nouvelles: true) {
                return .refusParChatGPT(message)
            }
            return attente.expiree ? attente.epuisee() : nil
        }

        attente.entrer(.lecture)
        // Le clic lui-même, répété quelques secondes : la barre d'actions de
        // la réponse s'affiche juste après la fin de la génération, pas au
        // même instant. Sa borne propre, même au-delà de l'échéance : la
        // réponse est là, ce clic n'attend plus ChatGPT.
        func cliquer(_ parent: String, _ bouton: String) async -> Bool {
            let fin = Date.now.addingTimeInterval(5)
            repeat {
                if Task.isCancelled { return false }
                let r = try? await appeler("return window.__relais.cliquerBouton(parent, bouton);",
                                           ["parent": parent, "bouton": bouton])
                if r?["ok"] as? Bool == true { return true }
                try? await Task.sleep(for: .milliseconds(300))
            } while Date.now < fin
            return false
        }
        if !selecteurs.lectureMenu.isEmpty {
            guard await cliquer(selecteurs.lectureMenuParent, selecteurs.lectureMenu) else {
                Log.error("relais : menu de la lecture à haute voix introuvable")
                return nil
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        // Sans cadrage quand un menu l'a ouvert : la page pose ses éléments de
        // menu ailleurs dans le document, hors du bloc de la réponse.
        let lancee = await cliquer(selecteurs.lectureMenu.isEmpty ? selecteurs.lectureParent : "",
                                   selecteurs.lecture)
        Log.info("relais : lecture à haute voix \(lancee ? "lancée" : "refusée")")
        return nil
    }

    /// Vide la zone de saisie, et s'assure qu'elle l'est restée.
    ///
    /// ChatGPT réinstalle le brouillon non envoyé après un rechargement, et
    /// parfois après qu'on l'a effacé : vider une fois ne suffit pas. On relit
    /// donc, et on recommence — la même précaution que pour l'écriture, et pour
    /// la même raison.
    @discardableResult
    func viderComposeur(selecteur: String? = nil) async -> Bool {
        let sel = selecteur ?? selecteurs.composeur
        // Le brouillon vit aussi dans le stockage de la page : l'effacer de la
        // zone ne suffit pas, ChatGPT le réinstalle depuis là.
        _ = try? await appeler("return window.__relais.oublierBrouillon();")
        let limite = Date.now.addingTimeInterval(6)
        while Date.now < limite {
            if Task.isCancelled { return false }
            _ = try? await appeler("return window.__relais.vider(sel);", ["sel": sel])
            try? await Task.sleep(for: .milliseconds(500))
            let lu = try? await appeler("return window.__relais.lire(sel);", ["sel": sel])
            if let texte = lu?["texte"] as? String, texte.isEmpty { return true }
        }
        Log.error("relais : la zone de saisie n'a pas voulu se vider")
        return false
    }

    /// Fait renoncer une calibration qui attend un clic.
    func abandonnerCalibration() async {
        _ = try? await appeler("return window.__relais.abandonnerCalibration();")
    }

    /// Attend que la zone de saisie soit là et lisible.
    private func attendreComposeur(secondes: Double,
                                   selecteur: String? = nil) async -> Bool {
        let limite = Date.now.addingTimeInterval(secondes)
        while Date.now < limite {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
            // La navigation d'abord : une zone de saisie trouvée pendant le
            // chargement est celle de la page qu'on est en train de quitter.
            guard !chargementEnCours else { continue }
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteur ?? selecteurs.composeur])
            if lu?["ok"] as? Bool == true { return true }
        }
        return false
    }

    /// Attend la fin de la réponse, puis la récupère par le bouton de ChatGPT.
    ///
    /// Le bouton « copier » n'apparaît qu'une fois la génération terminée : sa
    /// présence est donc à la fois le signal de fin — qu'on devinait
    /// jusqu'ici en chronométrant l'arrêt du texte — et le moyen d'extraction.
    ///
    /// Extraction bien meilleure que la lecture du DOM, qui dépend du nœud
    /// désigné à la calibration : cliquer sur un paragraphe de la réponse
    /// faisait rendre ce seul paragraphe, sans que rien ne signale l'amputation.
    /// Le bouton, lui, rend la réponse entière, dans la mise en forme voulue
    /// par ChatGPT.
    ///
    /// Le presse-papiers est rendu tel qu'on l'a trouvé : il appartient à
    /// l'utilisateur, et une dictée n'a pas à lui faire perdre ce qu'il y
    /// gardait.
    private func copierReponse(attente: RelaisAttente,
                               empreinteEnvoyee: String) async throws -> String {
        let presse = NSPasteboard.general
        let avant = presse.changeCount
        let sauvegarde = presse.string(forType: .string)

        var clique = false
        var tour = 0
        var silences = 0
        while !attente.expiree {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            let r = try? await appeler(
                "return window.__relais.copierLaReponse(selParent, selCopier, selRepli);",
                ["selParent": selecteurs.copierParent,
                 "selCopier": selecteurs.copier,
                 "selRepli": selecteurs.reponse])
            if r?["ok"] as? Bool == true {
                // Le niveau et le nombre de candidats, pour que le prochain
                // défaut se lise dans le journal plutôt que dans une capture.
                Log.info("relais : copier cliqué (\(r?["voie"] ?? "?"))")
                clique = true
                break
            }
            // Une fois par seconde, comme ailleurs. À chaque tour, la sonde
            // relisait le texte de centaines d'éléments quatre fois par
            // seconde — `innerText` force la page à recalculer sa disposition
            // — au risque de ralentir la génération même qu'on attendait.
            if tour % 4 == 3, let message = await refusPendantLAttente(silences: &silences) {
                throw Erreur.refusParChatGPT(message)
            }
            tour += 1
        }
        guard clique else {
            if let message = await erreurAffichee(nouvelles: true) {
                throw Erreur.refusParChatGPT(message)
            }
            throw attente.epuisee()
        }

        // Le clic est asynchrone côté page : on attend que le presse-papiers
        // change plutôt que de le lire aussitôt.
        //
        // Dix secondes à elle, même au-delà de l'échéance : la réponse est
        // finie et copiée, il ne reste qu'à la ramasser. Couper ici jetterait
        // un texte obtenu, et laisserait la copie écraser le presse-papiers
        // sans qu'on le rende.
        //
        // Sauf l'abandon, relevé en tête de chaque tour : il ne rend jamais de
        // texte. Sans ce contrôle, une tâche annulée tournait ici dix secondes
        // (le sommeil lève aussitôt, et `try?` l'avalait), puis rendait un
        // texte qui s'insérait. Mais il ne sort pas sur-le-champ : le clic est
        // parti, et la copie qu'il déclenche atterrit quand même, une fraction
        // de seconde plus tard. Sortir avant, c'était la laisser écraser le
        // presse-papiers sans plus personne pour le rendre. Il attend donc
        // cette copie une seconde encore, la défait, et seulement alors lève.
        let finCopie = Date.now.addingTimeInterval(10)
        var finAbandon: Date?
        while Date.now < (finAbandon ?? finCopie) {
            if finAbandon == nil, Task.isCancelled {
                finAbandon = min(finCopie, Date.now.addingTimeInterval(1))
            }
            if finAbandon == nil {
                try? await Task.sleep(for: .milliseconds(250))
            } else {
                // Le sommeil d'une tâche annulée rend la main aussitôt : on
                // dort dans une tâche à part, que l'annulation n'atteint pas.
                await Task { try? await Task.sleep(for: .milliseconds(100)) }.value
            }
            guard presse.changeCount != avant else { continue }
            let texte = presse.string(forType: .string) ?? ""
            presse.clearContents()
            if let sauvegarde { presse.setString(sauvegarde, forType: .string) }
            try Task.checkCancellation()
            guard !texte.isEmpty else { throw Erreur.pasDeReponse }
            // Garde-fou : ce qu'on vient de copier ne doit pas être ce qu'on
            // vient d'envoyer. Le délimiteur de la consigne ne figure jamais
            // dans une réponse, et sa présence signe un bouton « copier » pris
            // sous le mauvais message. Un texte arrivait alors bien au curseur,
            // ce qui rendait la méprise invisible — c'est le prompt lui-même
            // qui s'écrivait dans l'éditeur.
            if !empreinteEnvoyee.isEmpty, texte.contains(empreinteEnvoyee) {
                Log.error("relais : copie de la demande au lieu de la réponse")
                throw Erreur.pasDeReponse
            }
            return texte
        }
        try Task.checkCancellation()
        throw Erreur.pasDeReponse
    }

    /// Attend que la réponse apparaisse, puis cesse de grandir.
    ///
    /// ChatGPT écrit par flux : le texte s'allonge mot à mot. On attend donc
    /// deux secondes et demie sans changement, et non une — les pauses entre
    /// deux fragments d'une longue réponse dépassent régulièrement la seconde,
    /// et un seuil trop court rendrait un texte coupé au milieu, ce qui est
    /// pire que pas de texte du tout : rien ne signale la coupure.
    private func attendreReponse(attente: RelaisAttente) async throws -> String {
        var precedent = ""
        var stable = 0
        var tour = 0
        var silences = 0
        while !attente.expiree {
            defer { tour += 1 }
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lireReponse(sel);",
                                        ["sel": selecteurs.reponse])
            let texte = (lu?["texte"] as? String) ?? ""
            if !texte.isEmpty && texte == precedent {
                stable += 1
                if stable >= 10 { return texte }          // ~2,5 s sans changement
            } else {
                stable = 0
            }
            precedent = texte
            if tour % 4 == 3, let message = await refusPendantLAttente(silences: &silences) {
                throw Erreur.refusParChatGPT(message)
            }
        }
        if let message = await erreurAffichee(nouvelles: true) {
            throw Erreur.refusParChatGPT(message)
        }
        throw attente.epuisee()
    }

    /// Le message d'échec que ChatGPT affiche, s'il est apparu depuis le
    /// dernier relevé.
    ///
    /// Les motifs d'échec restent étroits, délibérément (cf. `erreur()` dans
    /// le pont). `nouvelles` y ajoute toute alerte apparue depuis le relevé,
    /// quelle que soit sa formulation — mais pour **expliquer** un échec déjà
    /// constaté seulement : l'attente a expiré, la zone est revenue vide. Elle
    /// n'interrompt alors plus rien. Pendant l'attente d'une réponse, c'est
    /// `refusPendantLAttente` qui décide.
    private func erreurAffichee(nouvelles: Bool) async -> String? {
        let r = try? await appeler("return window.__relais.erreur(connues, nouvelles, -1);",
                                   ["connues": alertesAvant, "nouvelles": nouvelles])
        let message = (r?["message"] as? String) ?? ""
        return message.isEmpty ? nil : message
    }

    /// Un refus de ChatGPT, pendant qu'on attend sa réponse.
    ///
    /// Un échec reconnu par ses motifs interrompt l'attente sur-le-champ. Une
    /// alerte nouvelle qu'aucun motif ne connaît — un quota atteint à
    /// l'instant — ne compte, elle, que tant que ChatGPT ne répond pas :
    /// aucune réponse nouvelle, aucune génération en cours (cf. `erreur()`).
    /// Sans cette condition, une bannière « limite bientôt atteinte » apparue
    /// à l'envoi faisait jeter la réponse que ChatGPT était en train d'écrire.
    ///
    /// Et ce silence doit durer trois relevés d'affilée : juste après l'envoi,
    /// la réponse met un instant à paraître, et une bannière tombée dans ce
    /// creux passerait sinon pour un refus.
    private func refusPendantLAttente(silences: inout Int) async -> String? {
        guard let r = try? await appeler(
            "return window.__relais.erreur(connues, true, avant);",
            ["connues": alertesAvant, "avant": reponsesAvantEnvoi])
        else { return nil }
        let message = (r["message"] as? String) ?? ""
        guard !message.isEmpty else { silences = 0; return nil }
        if r["reconnue"] as? Bool == true { return message }
        silences += 1
        return silences >= 3 ? message : nil
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
        let r = try await guetter("return await window.__relais.calibrer(genre);",
                                  ["genre": cible.genre], cible)
        guard r["ok"] as? Bool == true else { throw CancellationError() }
        guard let sel = r["selecteur"] as? String, !sel.isEmpty else {
            throw Erreur.introuvable(cible)
        }
        selecteurs[cible] = sel
        // Le bloc qui porte l'élément, retenu avec lui pour le bouton
        // « copier » : c'est la paire qui lève l'ambiguïté, pas le bouton seul.
        // Le bloc qui porte l'élément, retenu avec lui pour les boutons des
        // barres d'actions : la page en pose une sous chaque message, et seul
        // le couple dit de laquelle il s'agit.
        switch cible {
        case .copier: selecteurs.copierParent = (r["parent"] as? String) ?? ""
        case .lecture: selecteurs.lectureParent = (r["parent"] as? String) ?? ""
        default: break
        }
        selecteurs.enregistrer()
        return sel
    }

    /// Attend le clic qu'un guetteur de calibration espère, trois minutes au
    /// plus.
    ///
    /// C'est la seule attente du pont qui doit être longue — une main humaine
    /// lit la consigne, cherche le bouton, hésite — et elle n'en est pas moins
    /// bornée : une consigne oubliée derrière une autre fenêtre laissait la
    /// promesse attendre pour toujours, et le parcours avec elle. À
    /// l'échéance, le guetteur est retiré de la page, sans quoi il retiendrait
    /// comme repère le prochain clic de l'utilisateur, n'importe où dans
    /// ChatGPT.
    private func guetter(_ corps: String, _ args: [String: Any],
                         _ cible: RelaisCible) async throws -> [String: Any] {
        do {
            return try await appeler(corps, args, delai: Self.delaiClic)
        } catch Erreur.pontMuet {
            _ = try? await appeler("return window.__relais.abandonnerCalibration();")
            throw Erreur.calibrationSansClic(cible)
        }
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
        if webView === self.webView { chargementEnCours = false }
        guard webView === self.webView else {
            // Un popup a fini de naviguer : la connexion a pu aboutir dans la
            // fenêtre principale sans qu'elle en soit informée.
            Task { await rafraichirEtiquette() }
            return
        }
        Task { await rafraichirEtiquette() }
    }

    /// Une navigation qui échoue — hors ligne, un serveur qui refuse.
    ///
    /// Sans ce délégué, `chargementEnCours` restait levé jusqu'au prochain
    /// chargement : toute attente de la zone de saisie tournait à vide, en se
    /// croyant devant une page qui arrive.
    ///
    /// Sauf l'annulation : c'est une navigation remplacée par une autre, qui
    /// est justement en cours. Baisser le drapeau ferait interroger la page
    /// qu'on est en train de quitter.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        navigationEchouee(webView, error, provisoire: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationEchouee(webView, error, provisoire: true)
    }

    private func navigationEchouee(_ vue: WKWebView, _ error: Error, provisoire: Bool) {
        guard vue === webView else { return }
        let e = error as NSError
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return }
        Log.error("relais : navigation \(provisoire ? "refusée" : "interrompue") "
                  + "(\(e.domain) \(e.code) — \(e.localizedDescription))")
        chargementEnCours = false
        Task { await rafraichirEtiquette() }
    }

    /// WebKit a tué le processus de la page — pression mémoire, le plus
    /// souvent.
    ///
    /// La page reste ouverte des semaines d'une dictée à l'autre : cette mort
    /// finit par arriver, et il n'y avait aucun autre remède que de quitter
    /// l'application. La page est rechargée sur-le-champ ; une dictée qui
    /// attend sa transcription l'apprend au tour suivant de son attente, et
    /// une dictée qui écoute l'apprend par `surMort`.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else {
            Log.error("relais : le processus d'une fenêtre de connexion s'est arrêté")
            return
        }
        Log.error("relais : WebKit a arrêté le processus de la page — rechargement")
        morts += 1
        charger()
        surMort?()
    }
}

/// L'issue d'un appel au pont : la réponse de la page, l'échéance, ou
/// l'annulation — la première arrivée, et elle seule.
///
/// Une continuation ne se reprend qu'une fois. Trois concurrents s'y disputent
/// la reprise ; celui qui arrive après les autres est simplement ignoré, et
/// l'appel JavaScript resté en suspens finit dans le vide.
@MainActor
private final class AttenteDuPont {
    private var suite: CheckedContinuation<[String: Any], Error>?
    private var issue: Result<[String: Any], Error>?
    var minuteur: Task<Void, Never>?

    func attacher(_ suite: CheckedContinuation<[String: Any], Error>) {
        // L'annulation a pu arriver avant : la tâche l'était déjà à l'appel.
        if let issue { suite.resume(with: issue) } else { self.suite = suite }
    }

    func rendre(_ resultat: Result<[String: Any], Error>) {
        guard issue == nil else { return }
        issue = resultat
        minuteur?.cancel()
        suite?.resume(with: resultat)
        suite = nil
    }
}
