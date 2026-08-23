import AppKit
import WebKit

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
        case pasDeTexte
        case zoneJamaisRevenue
        case pasConnecte
        case pasDeReponse
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
            case .pasDeReponse:
                "ChatGPT n'a pas répondu. La transcription brute est dans l'historique."
            case .refusParChatGPT(let message):
                "ChatGPT a refusé la dictée : \(message)"
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
        barre.level = .statusBar
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
        Task { await rafraichirEtiquette() }
    }

    /// La barre pendant la dictée : la pastille de ChatGPT, et rien d'autre.
    ///
    /// L'afficher règle aussi un défaut ancien : le système diffère les rendus
    /// d'une fenêtre qu'il croit cachée, ce qui retardait l'apparition du bouton
    /// d'arrêt et faisait échouer la première dictée de chaque session.
    func afficherBarre() {
        rendreLaVueALaBarre()
        webView.pageZoom = Self.zoomBarre
        Task { _ = try? await appeler("return window.__relais.compacter(true, sel);",
                                      ["sel": selecteurs.composeur]) }
        guard let ecran = NSScreen.main else { return }
        let cadre = ecran.visibleFrame
        barre.setFrame(NSRect(x: cadre.midX - Self.tailleBarre.width / 2,
                              y: cadre.minY + Self.hauteurBarre,
                              width: Self.tailleBarre.width,
                              height: Self.tailleBarre.height),
                       display: true)
        barre.orderFrontRegardless()
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
        barre.setFrameOrigin(Self.horsChamp)
        barre.orderFrontRegardless()
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
    func preparerCalibrationEnvoi() async -> Bool {
        charger()
        guard await attendreComposeur(secondes: 30) else { return false }
        for essai in 0..<12 {                                   // jusqu'à 6 s
            _ = try? await appeler("return window.__relais.ecrire(sel, texte);",
                                   ["sel": selecteurs.composeur, "texte": Self.essai])
            try? await Task.sleep(for: .milliseconds(500))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            if let texte = lu?["texte"] as? String, !texte.isEmpty {
                if essai > 0 { Log.info("relais : message d'essai écrit au \(essai + 1)e essai") }
                return true
            }
        }
        return false
    }

    /// Envoie un texte et rend la réponse.
    ///
    /// Un fil neuf à chaque fois, par rechargement de la page plutôt que par un
    /// clic sur « Nouveau chat ». Deux raisons : c'est un sélecteur de moins à
    /// calibrer, et le rechargement garantit un état propre là où un bouton
    /// laisse ce que la page avait en tête. Sans fil neuf, la note d'avant
    /// oriente la suivante — on demanderait une réorganisation et on
    /// obtiendrait une réponse tenant compte d'un monologue d'il y a une heure.
    func demanderA(_ texte: String, patienceSecondes: Double) async throws -> String {
        charger()
        guard await attendreComposeur(secondes: 30) else { throw Erreur.zoneJamaisRevenue }

        let ecrit = try await appeler("return window.__relais.ecrire(sel, texte);",
                                      ["sel": selecteurs.composeur, "texte": texte])
        guard ecrit["ok"] as? Bool == true else { throw Erreur.introuvable(.composeur) }

        guard try await cliquerQuandDisponible(.envoi, selecteurs.envoi, secondes: 10) else {
            throw Erreur.introuvable(.envoi)
        }
        return try await attendreReponse(patienceSecondes: patienceSecondes)
    }

    /// Attend que la zone de saisie soit là et lisible.
    private func attendreComposeur(secondes: Double) async -> Bool {
        for _ in 0..<Int(secondes * 4) {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            if lu?["ok"] as? Bool == true { return true }
        }
        return false
    }

    /// Attend que la réponse apparaisse, puis cesse de grandir.
    ///
    /// ChatGPT écrit par flux : le texte s'allonge mot à mot. On attend donc
    /// deux secondes et demie sans changement, et non une — les pauses entre
    /// deux fragments d'une longue réponse dépassent régulièrement la seconde,
    /// et un seuil trop court rendrait un texte coupé au milieu, ce qui est
    /// pire que pas de texte du tout : rien ne signale la coupure.
    private func attendreReponse(patienceSecondes: Double) async throws -> String {
        var precedent = ""
        var stable = 0
        for tour in 0..<Int(patienceSecondes * 4) {
            try Task.checkCancellation()
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
            if tour % 8 == 7, let message = await erreurAffichee() {
                throw Erreur.refusParChatGPT(message)
            }
        }
        throw Erreur.pasDeReponse
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
        // Fermer la fenêtre de réglage la range et rend la vue à la barre ;
        // elle ne détruit ni la page ni la session.
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
