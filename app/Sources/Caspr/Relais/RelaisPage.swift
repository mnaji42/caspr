import AppKit
import WebKit
import CasprCore

@MainActor
final class RelaisPage: NSObject {

    /// Ce que le relais sait de la session, à un instant donné.
    enum Connexion { case connecte, deconnecte, inconnu }

    static func estChatGPT(_ url: URL) -> Bool { url.host().map(estChatGPT(hote:)) ?? false }

    /// La seule définition de « chez ChatGPT » : le point de départ, le micro
    /// accordé et l'écho la lisent tous trois, et trois copies d'une règle
    /// de sécurité finissent par ne plus dire la même chose.
    static func estChatGPT(hote: String) -> Bool { hote == "chatgpt.com" || hote.hasSuffix(".chatgpt.com") }

    static let accueil = URL(string: "https://chatgpt.com/")!

    /// Le monde du pont : le DOM de la page, mais pas ses variables.
    ///
    /// `window.__relais` y est invisible et intouchable depuis chatgpt.com :
    /// aucune trace d'automate que la page puisse relever, aucun script à
    /// elle qui puisse l'écraser ou le faire passer pour installé. Depuis ce
    /// monde, `click`, `execCommand('insertText')` et son événement `input`,
    /// `localStorage` agissent sur la page comme depuis le sien (mesuré).
    /// Éprouvé fonction par fonction, dans ce monde et dans celui de la page,
    /// sur chatgpt.com déconnecté et sur un vrai ProseMirror : mêmes
    /// résultats, à la seule visibilité du pont près — ProseMirror voit
    /// l'écriture et l'encadrement, « copier » remplit le presse-papiers, un
    /// clic de Caspr n'est pas retenu par la calibration, un clic réel l'est.
    ///
    /// Celui du relais de l'écho, qui y vit déjà. Revenir au monde de la
    /// page, si ChatGPT cessait d'y répondre : `.page`, ici, et rien d'autre —
    /// l'écho reste où il est.
    static let monde: WKContentWorld = RelaisEcho.monde

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
    var fenetre: NSWindow!
    var barre: BarreRelais!
    var etiquette: NSTextField!
    /// La rangée de navigation, masquée quand la fenêtre se réduit à sa barre.
    var barreNav: NSStackView!
    /// Les fenêtres de connexion ouvertes par la page (OAuth, conditions).
    /// Retenues pour ne pas être libérées pendant que l'utilisateur s'en sert.
    var annexes: [NSWindow] = []
    /// La grande fenêtre avait le clavier quand la dictée l'a retirée pour
    /// sa barre (cf. `afficherBarre`).
    ///
    /// Caspr reste alors devant sans elle, et si une autre de ses fenêtres
    /// était ouverte derrière, c'est elle qui reçoit le clavier : sans ce
    /// souvenir, on la croirait celle où l'on dicte, et le texte s'y
    /// écrirait (cf. `Relais.rendreLeClavier`).
    var fenetreCleRetiree = false
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
    /// continuerait d'interroger sans fin la page neuve, qui n'en sait rien.
    /// L'époque, relevée à l'ouverture de l'écoute, lui dit que la page
    /// qu'elle attend n'existe plus (cf. `RelaisDictee.pageMorte`).
    var epoque = 0
    /// La dernière mort, pour ne pas recharger en boucle une page qui meurt à
    /// répétition (cf. `webViewWebContentProcessDidTerminate`).
    var derniereMort: Date?
    /// La page est morte et n'a pas été rechargée : le prochain appel au pont
    /// la recharge.
    var rechargementRetenu = false
    /// La marque de la dictée en cours (cf. `marquer`) ; `nil` tant qu'elle
    /// n'est pas posée, et chaque relevé tait alors réponse et échec.
    var marque: RelaisMarque?
    /// Ceux du magasin, toujours à jour : la page n'en garde pas de copie.
    var selecteurs: RelaisSelecteurs { RelaisMagasin.partage.selecteurs }
    /// Les appels au pont qui attendent leur réponse, pour que `detruire` les
    /// rende : sur une vue détruite, aucun ne reviendrait jamais.
    var enSuspens: [AppelAnnulable<String?>] = []
    /// La copie du son que la page capte (cf. `RelaisEcho`).
    let echo = RelaisEcho()

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
        // Sans quoi le contexte audio de l'écho, créé hors d'un geste de
        // l'utilisateur, peut rester suspendu (mesuré).
        config.mediaTypesRequiringUserActionForPlayback = []
        echo.installer(dans: config.userContentController)
        config.userContentController.addUserScript(
            WKUserScript(source: RelaisScripts.pont,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true, in: Self.monde))

        webView = WKWebView(frame: Self.enVue, configuration: config)
        echo.relier(webView)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // On garde l'agent utilisateur par défaut de WebKit, qui est celui de
        // Safari. En inventer un attirerait exactement l'attention qu'on ne
        // veut pas.

        construireLesFenetres()

        cacher()
        if Self.cacheDisqueVide {
            charger()
        } else {
            viderLeCacheDisquePuisCharger()
        }
    }

    /// Vrai dès que le cache disque de WebKit a été vidé, pour ce lancement.
    ///
    /// Statique : la page est détruite quand on choisit macOS, et reconstruite
    /// quand on revient à ChatGPT. Une seule purge par lancement suffit, et la
    /// refaire à chaque bascule rechargerait tout chatgpt.com pour rien.
    private static var cacheDisqueVide = false

    /// Vide le cache HTTP de la page, puis la charge.
    ///
    /// La page reste ouverte des semaines, et WebKit y garde tout ce que
    /// chatgpt.com télécharge — scripts, images, versions successives de
    /// l'application. Mesuré chez le propriétaire : 942 Mo dans
    /// `~/Library/Caches/fr.lyriastudio.caspr/WebKit/NetworkCache`, sans
    /// plafond visible. Ce cache ne sert qu'à aller plus vite ; le vider au
    /// premier montage de chaque lancement le borne à ce qu'une session
    /// télécharge.
    ///
    /// **Le cache disque, et rien d'autre.** Les cookies, le stockage local,
    /// IndexedDB et les service workers portent la session ChatGPT : les
    /// effacer déconnecterait l'utilisateur à chaque lancement. Le cache des
    /// service workers (`WKWebsiteDataTypeFetchCache`) est laissé aussi : il
    /// pesait 4 Ko, et il appartient à la page plus qu'au navigateur.
    ///
    /// Le chargement attend la purge, pour ne pas remplir le cache pendant
    /// qu'on le vide. `chargementEnCours` est levé dès maintenant : les
    /// attentes de la zone de saisie savent ainsi qu'une page arrive.
    private func viderLeCacheDisquePuisCharger() {
        Self.cacheDisqueVide = true
        chargementEnCours = true
        let debut = Date.now
        Task { [weak self] in
            await WKWebsiteDataStore.default().removeData(
                ofTypes: [WKWebsiteDataTypeDiskCache], modifiedSince: .distantPast)
            let ms = Int(Date.now.timeIntervalSince(debut) * 1000)
            Log.info("relais : cache disque de WebKit vidé (\(ms) ms)")
            // Une page qui a déjà une adresse a été chargée entre-temps — ou
            // détruite, ce qui y pose `about:blank`. La charger ici en
            // relancerait la navigation par-dessus.
            guard let self, self.webView.url == nil else { return }
            self.charger()
        }
    }

    func charger() {
        rechargementRetenu = false
        chargementEnCours = true
        webView.load(URLRequest(url: RelaisMagasin.partage.depart))
    }

    /// L'adresse affichée, pour que les réglages puissent l'adopter.
    var adresseCourante: URL? { webView.url }

    // MARK: - État de la session

    /// Connecté ou non, vu depuis la page — **au repos** : l'étiquette de la
    /// fenêtre, la calibration, le diagnostic. La dictée attend la session à
    /// sa façon, sans borne (cf. `RelaisDictee.ouvrirLEcoute`).
    ///
    /// `.deconnecte` seulement quand la page l'a **dit** : un écran ou une
    /// invite de connexion (cf. `RelaisVeille.session`). Une page qui ne dit
    /// rien avant la borne est `.inconnu` — à recharger, pas à reconnecter.
    /// Conclure « déconnecté » faute d'avoir vu la zone de texte a coûté
    /// plusieurs faux « D'abord, se connecter » : chatgpt.com, chargé à froid
    /// puis hydraté, dépasse souvent cinq secondes, et un calibrage faux — on
    /// recalibre souvent pour cela — ne trouve plus la zone du tout.
    ///
    /// On réinterroge jusqu'à la borne parce que ChatGPT est une application
    /// monopage : au retour de `didFinish`, le composeur n'est pas encore
    /// monté. `reperes` : le calibrage par défaut ; vides, le filet — celui
    /// que suit la calibration, qui remplace peut-être un calibrage faux.
    func connexion(secondes: Double = 5, reperes: RelaisSelecteurs? = nil) async -> Connexion {
        var vue = Connexion.inconnu
        _ = try? await observer(auPlus: .seconds(secondes), toutes: .milliseconds(400)) {
            // Une zone de texte vue pendant la navigation est celle de la page
            // qu'on quitte. Un silence ne conclut rien : la borne s'en charge.
            guard !chargementEnCours, let vu = await sonder({ try await self.instantane(reperes: reperes) }),
                  let connexion = session(vu) else { return false }
            vue = connexion
            return true
        }
        return vue
    }

    func rafraichirEtiquette() async {
        etiquette?.stringValue = "vérification…"
        switch await connexion() {
        case .connecte:
            etiquette?.stringValue = selecteurs.estCalibre
                ? "Connecté et calibré — la touche de dictée écrit par ChatGPT."
                : "Connecté. Reste à calibrer les boutons."
        case .deconnecte:
            etiquette?.stringValue = "Pas encore connecté."
        case .inconnu:
            etiquette?.stringValue = "La page ne dit pas si vous êtes connecté — rechargez-la."
        }
    }

    /// La session que montre ce relevé (cf. `RelaisVeille.session`), dite à
    /// `surConnexion` ; `nil` quand la page n'a rien dit.
    func session(_ vu: RelaisInstantane) -> Connexion? {
        guard let connectee = RelaisVeille.session(vu) else { return nil }
        let connexion: Connexion = connectee ? .connecte : .deconnecte
        surConnexion?(connexion)
        return connexion
    }

    /// Rend sur-le-champ chaque appel au pont resté en suspens : l'attente
    /// qui le porte reprend la main et juge elle-même la suite.
    func rendreLesAppelsEnSuspens(_ erreur: Error) {
        let suspendus = enSuspens
        enSuspens.removeAll()
        for appel in suspendus { appel.rendre(.failure(erreur)) }
    }

    /// Ferme tout : la vue, ses fenêtres annexes, et le processus de contenu
    /// qui va avec. C'est lui qui garde le micro de la machine.
    ///
    /// Les appels en suspens sont rendus : sur une vue détruite, ils ne
    /// reviendraient jamais (mesuré), et l'attente qui les porte non plus.
    func detruire() {
        rendreLesAppelsEnSuspens(RelaisErreur.pageInterrompue)
        // Le contrôleur retient son gestionnaire, et la page avec lui ; les
        // scripts retirés, la page vide qui suit ne les reçoit pas.
        echo.desarmer()
        let controleur = webView.configuration.userContentController
        controleur.removeScriptMessageHandler(forName: RelaisEcho.gestionnaire,
                                              contentWorld: RelaisEcho.monde)
        controleur.removeAllUserScripts()
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
    ///
    /// Une seconde au plus : sur une page au fil JavaScript bloqué, WebKit ne
    /// rend jamais la main (mesuré), et c'est justement la page qu'on
    /// s'apprête à détruire — ce qui rend le micro de toute façon.
    func rendreLeMicro() async {
        guard microOuvert else { return }
        let vue: WKWebView = webView
        let rendu: Void? = try? await auPlus(.seconds(1)) {
            let appel = AppelAnnulable<Void>()
            Task {
                await vue.setMicrophoneCaptureState(.none)
                appel.rendre(.success(()))
            }
            try await appel.attendre()
        }
        if rendu == nil {
            Log.error("relais : WebKit n'a pas rendu le micro en 1 s")
        } else {
            Log.info("relais : micro rendu")
        }
    }
}

/// Une valeur que Swift ne sait pas transmissible, passée d'une tâche à
/// l'autre du même acteur (cf. `RelaisPage.auPlus`).
struct Colis<T>: @unchecked Sendable {
    let valeur: T
}
