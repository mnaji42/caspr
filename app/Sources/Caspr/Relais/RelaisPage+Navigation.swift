import AppKit
import WebKit

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
    ///
    /// Sauf quand elle meurt encore dans les cinq minutes. Une cause qui se
    /// répète — une pression mémoire qui dure, une page qui fait tomber
    /// WebKit — rechargeait alors chatgpt.com en boucle, hors champ, des
    /// semaines durant. La page reste morte, et le premier usage la recharge
    /// (cf. `appeler`) : la dictée suivante n'y perd rien.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else {
            Log.error("relais : le processus d'une fenêtre de connexion s'est arrêté")
            return
        }
        morts += 1
        // Un appel en suspens sur le processus mort peut ne jamais revenir,
        // et plus aucun délai ne le rattrape : rendu ici, l'attente qui le
        // porte reprend la main et lit la mort au tour suivant.
        rendreLesAppelsEnSuspens(Erreur.pageInterrompue)
        let recidive = derniereMort.map { Date.now.timeIntervalSince($0) < 300 } ?? false
        derniereMort = .now
        if recidive {
            Log.error("relais : WebKit a encore arrêté le processus de la page — "
                      + "rechargement au prochain usage")
            // Aucune page n'arrive : les attentes ne doivent pas en guetter une.
            chargementEnCours = false
            rechargementRetenu = true
        } else {
            Log.error("relais : WebKit a arrêté le processus de la page — rechargement")
            charger()
        }
        surMort?()
    }
}
