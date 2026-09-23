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

    var webView: WKWebView!
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
    var annexes: [NSWindow] = []
    /// Vrai entre l'ordre de chargement et la fin de la navigation.
    ///
    /// Sans ce drapeau, attendre « la zone de saisie » revenait à interroger la
    /// **page précédente** : elle est encore là quelques centaines de
    /// millisecondes après l'ordre de rechargement, et la réponse arrivait donc
    /// tout de suite, sur le mauvais document. On écrivait le prompt dans une
    /// page qui allait disparaître.
    var chargementEnCours = false
    /// Combien de fois WebKit a tué le processus de contenu de la page.
    ///
    /// La page reste ouverte d'une dictée à l'autre, des semaines durant : sous
    /// pression mémoire, le système finit par tuer son processus. Elle est
    /// alors rechargée — mais une dictée qui attendait sa transcription
    /// continuerait d'interroger la page neuve, qui n'en sait rien, jusqu'à
    /// l'expiration de sa patience. Le compteur, relevé au départ de la dictée,
    /// lui dit que la page qu'elle attend n'existe plus.
    var morts = 0
    var mortsAuDepart = 0
    /// Les alertes que la page affichait avant qu'on lui demande quelque chose.
    ///
    /// Une bannière déjà là n'est pas une réponse à notre demande — celle d'un
    /// quota « bientôt atteint » reste affichée des jours. Seule une alerte
    /// apparue depuis peut en être une.
    var alertesAvant: [String] = []
    /// Le nombre de réponses de ChatGPT dans la page au moment d'envoyer.
    ///
    /// C'est ce qui distingue la réponse attendue de la précédente : dans une
    /// discussion, le fil en porte déjà une, finie et immobile, qui passerait
    /// sinon pour celle qu'on attend.
    var reponsesAvantEnvoi = 0
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

    /// Appelé quand la page a **montré** si la session est ouverte : la zone
    /// de saisie de l'application, ou l'écran de connexion. Jamais sur un
    /// silence du pont, ni sur une patience épuisée — une page qui se charge
    /// n'est pas une session fermée.
    ///
    /// La garde de l'accueil lit ce qu'on a vu en dernier : elle est
    /// synchrone, et interroger la page ne l'est pas.
    var surConnexion: ((Connexion) -> Void)?

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
    /// La page rendue à 65 % : les 420 points de la barre valent alors environ
    /// 650 points CSS. Le dézoom élargit la page que voit ChatGPT, pour qu'il
    /// garde sa mise en page large plutôt que de basculer sur celle des
    /// téléphones, où la pastille se réorganise.
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
                if r["connecte"] as? Bool == true {
                    surConnexion?(.connecte)
                    return .connecte
                }
                if r["authentification"] as? Bool == true {
                    surConnexion?(.deconnecte)
                    return .deconnecte
                }
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

    /// La session telle que la calibration automatique doit la juger :
    /// `.deconnecte` seulement quand la page l'a **dit**.
    ///
    /// Deux différences avec `etatConnexion`, et chacune a coûté un faux
    /// « D'abord, se connecter » :
    ///
    /// - **Les repères du filet, pas le calibrage.** Celui-ci est peut-être
    ///   faux — c'est souvent pour cela qu'on recalibre —, et un calibrage qui
    ///   ne trouve plus la zone de texte ni le micro faisait passer une session
    ///   ouverte pour fermée : l'automate refusait alors de réparer justement
    ///   ce qu'on lui demandait de réparer.
    /// - **L'attente jusqu'à ce que la page se prononce.** Choisir ChatGPT
    ///   construit la page et lance la calibration dans le même geste ;
    ///   chatgpt.com, chargé à froid puis hydraté, dépasse souvent les cinq
    ///   secondes d'`etatConnexion`, qui conclut alors « déconnecté » faute
    ///   d'avoir vu la zone de texte. Ici, seul un signe de connexion
    ///   (`authentification`) le fait conclure ; une page qui ne dit rien avant
    ///   la borne est `.inconnu` — à recharger, pas à reconnecter.
    func connexionObservee(secondes: Double) async -> Connexion {
        let limite = Date.now.addingTimeInterval(secondes)
        while Date.now < limite {
            if Task.isCancelled { return .inconnu }
            // Une zone de texte vue pendant la navigation est celle de la page
            // qu'on quitte.
            if !chargementEnCours {
                do {
                    let r = try await appeler(
                        "return window.__relais.etat(micro, stop, composeur);",
                        ["micro": "", "stop": "", "composeur": ""])
                    if r["connecte"] as? Bool == true {
                        surConnexion?(.connecte)
                        return .connecte
                    }
                    if r["authentification"] as? Bool == true {
                        surConnexion?(.deconnecte)
                        return .deconnecte
                    }
                } catch Erreur.pontMuet {
                    return .inconnu
                } catch is CancellationError {
                    return .inconnu
                } catch {
                    // Le pont n'est pas encore injecté : la page se charge.
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return .inconnu
    }

    func rafraichirEtiquette() async {
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
    ///
    /// Ouvert au reste du module pour la calibration automatique, qui a son
    /// fichier (cf. `RelaisCalibrationAuto`) : ses appels passent par ce même
    /// délai.
    @discardableResult
    func appeler(_ corps: String, _ args: [String: Any] = [:],
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
    func verifierLaPage() throws {
        guard morts == mortsAuDepart else { throw Erreur.pageInterrompue }
    }

    /// Ce que la page affiche à cet instant — ses alertes, et combien de
    /// réponses de ChatGPT elle porte — pour ne compter ensuite que ce qui est
    /// apparu depuis.
    func relever() async -> (alertes: [String], reponses: Int) {
        let r = try? await appeler("return window.__relais.releve();")
        return ((r?["alertes"] as? [String]) ?? [], (r?["reponses"] as? Int) ?? 0)
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
