import AppKit
import CasprCore
import WebKit

/// Le relais : dicter par le transcripteur de ChatGPT, sur la touche de dictée
/// habituelle.
///
/// C'est un **mode exclusif**, pas un moteur de plus. Allumé, ChatGPT écrit et
/// les moteurs de Caspr sont arrêtés ; éteint, Caspr redevient exactement ce
/// qu'il était. L'exclusion n'est pas une préférence de présentation : les deux
/// ne peuvent pas ouvrir le micro en même temps — mesuré au niveau crête de
/// l'enregistrement, 0,072 avant tout usage du relais, 0,000 après.
///
/// **Cette fonctionnalité est destinée à être retirée.** Elle est personnelle,
/// elle dépend d'un service tiers piloté par sa page web, et elle n'a pas sa
/// place dans un produit vendu. Tout ce qui la concerne vit donc dans ce
/// dossier, et les points d'accroche dans le reste de l'application sont
/// marqués `RELAIS —` pour être retrouvés d'un `grep`. La marche à suivre est
/// dans `RELAIS.md`.
///
/// Trois règles tenues pour que ce retrait reste trivial :
///
/// 1. **Rien n'entre dans `CasprCore`.** Pas de cas `.relais` dans
///    `EngineChoice` : il faudrait le traiter dans les réglages, le
///    gestionnaire de sécurité, le corpus, les statistiques — autant d'endroits
///    à défaire ensuite.
/// 2. **Rien n'entre dans `Preferences`.** Les réglages du relais sont dans
///    `UserDefaults` sous le préfixe `relais.`, lus ici seulement.
/// 3. **Rien n'est construit tant que ce n'est pas activé.** La WKWebView et la
///    session ChatGPT n'existent pas pour qui n'a jamais coché la case.
@MainActor
final class Relais {
    static let partage = Relais()

    private static let cleActif = "relais.actif"

    /// ChatGPT écrit-il à la place des moteurs de Caspr ?
    ///
    /// Éteint, le relais ne coûte rien : la page n'est pas construite et aucune
    /// requête n'est faite. Allumé, elle est chargée tout de suite, pour que la
    /// première dictée ne paie pas l'ouverture de chatgpt.com.
    var actif: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cleActif) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.cleActif)
            guard !newValue else {
                // Allumé, on charge tout de suite : la première dictée ne doit
                // pas payer le chargement de chatgpt.com. C'est possible parce
                // que Caspr n'ouvrira plus le micro tant que ce mode dure.
                _ = pageActive()
                return
            }
            // Rendre le micro avant de lâcher la page : décocher la case doit
            // rendre Caspr exactement à l'état d'avant, y compris pour la
            // dictée sur la touche principale. C'est la porte de sortie, elle
            // doit être sans reste.
            Task { await libererPage() }
        }
    }

    /// Vrai pendant le parcours de configuration, pour ne pas en lancer deux.
    private var configurationEnCours = false

    /// Construite à la première utilisation, jamais avant.
    private var page: RelaisPage?

    private func pageActive() -> RelaisPage {
        if let page { return page }
        let neuve = RelaisPage()
        page = neuve
        return neuve
    }

    var estCalibre: Bool { RelaisSelecteurs.charger().estCalibre }
    /// Les deux sélecteurs supplémentaires de l'aller-retour sont-ils connus ?
    var saitDialoguer: Bool { RelaisSelecteurs.charger().saitDialoguer }

    /// Charge la page au lancement quand le mode est déjà actif.
    ///
    /// Sans elle, la toute première dictée d'une session crée la vue, lance le
    /// chargement de chatgpt.com, puis interroge une session qui n'existe pas
    /// encore : elle ouvrait la barre sans jamais écouter, et il fallait
    /// appuyer une seconde fois.
    ///
    /// Ce préchargement avait été retiré parce qu'une page ChatGPT vivante
    /// privait de son le micro de Caspr. Les deux modes s'excluant désormais,
    /// Caspr n'ouvre plus le micro du tout dans ce mode : la raison a disparu.
    func prechauffer() {
        guard actif, estCalibre else { return }
        _ = pageActive()
    }

    // MARK: - Cycle de dictée

    private var debut = Date()
    var secondesEcoulees: Double { Date().timeIntervalSince(debut) }

    func demarrer() async throws {
        debut = Date()
        try await pageActive().demarrer()
    }

    func arreterEtLire(secondesDictees: Double) async throws -> String {
        try await pageActive().arreterEtLire(secondesDictees: secondesDictees)
    }

    func annuler() async {
        await page?.annuler()
        await page?.rendreLeMicro()
    }

    /// Détruit la page, à l'extinction du mode.
    ///
    /// Le processus de contenu de WebKit part avec elle, et c'est lui qui tient
    /// le micro de la machine. Tant qu'une page ChatGPT vit, l'enregistrement
    /// de Caspr ne capte que du silence : décocher la case doit donc rendre
    /// l'appareil, pas seulement cesser de s'en servir.
    ///
    /// Appelée à l'extinction seulement, jamais entre deux dictées : les deux
    /// modes s'excluant, personne ne dispute le micro à la page tant que le
    /// relais est allumé, et la garder ouverte rend le raccourci instantané.
    func libererPage() async {
        guard let ancienne = page else { return }
        page = nil
        await ancienne.rendreLeMicro()
        ancienne.detruire()
        Log.info("relais : page libérée")
    }

    /// Efface la session ChatGPT — cookies, stockage local, caches.
    ///
    /// Par l'API de WebKit, et non en supprimant des fichiers. Le magasin d'une
    /// `WKWebsiteDataStore` n'a pas d'emplacement contractuel : il a changé
    /// entre les versions de macOS, et une partie vit dans des processus
    /// annexes qui réécrivent ce qu'on croit avoir effacé. Chercher le bon
    /// dossier, c'est parier sur un détail d'implémentation d'Apple ; lui
    /// demander d'effacer, c'est utiliser la seule voie qu'il garantit.
    ///
    /// La page est détruite ensuite : celle qui tourne garde sa session en
    /// mémoire et la réécrirait à la première occasion.
    func deconnecter() async {
        await libererPage()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await WKWebsiteDataStore.default().removeData(ofTypes: types,
                                                      modifiedSince: .distantPast)
        Log.info("relais : session ChatGPT effacée")
    }

    /// Renvoie le texte à ChatGPT et rend ce qu'il répond.
    ///
    /// **En cas d'échec, la transcription brute est rendue telle quelle.** Une
    /// dictée de dix minutes ne doit pas se perdre parce que la seconde passe
    /// n'a pas abouti : cette application s'interdit partout ailleurs de faire
    /// tout redire, et ce n'est pas ici qu'elle commencerait. La raison part
    /// dans le journal, et la conversation reste ouverte dans la fenêtre du
    /// relais pour qu'on puisse voir ce qui s'est passé.
    func transformer(_ brut: String, mode: RelaisMode) async -> String {
        guard mode.demandeUnAllerRetour, saitDialoguer, !brut.isEmpty else { return brut }
        // La patience suit la longueur du texte : une page se réorganise en
        // quelques secondes, dix minutes de monologue demandent bien plus.
        // Trois minutes de plancher, une seconde par vingt caractères.
        let patience = max(180.0, Double(brut.count) / 20)
        do {
            let texte = try await pageActive()
                .demanderA(RelaisPrompt.envelopper(brut, mode: mode),
                           patienceSecondes: patience)
            guard !texte.isEmpty else {
                Log.error("relais : réponse vide, transcription brute conservée")
                return brut
            }
            Log.info("relais : \(mode.rawValue) — \(brut.count) → \(texte.count) caractères")
            return texte
        } catch {
            Log.error("relais : \(mode.rawValue) a échoué (\(error.localizedDescription)) "
                      + "— transcription brute conservée")
            return brut
        }
    }

    // MARK: - Réglages

    func ouvrirFenetre() { pageActive().montrer() }

    /// La petite fenêtre pendant la dictée, et son retrait après.
    func afficherBarre() { pageActive().afficherBarre() }
    func masquerBarre() { page?.cacher() }

    /// Tout arrêter proprement, dans l'ordre.
    ///
    /// La barre se referme **après** l'arrêt et non avant : rangée hors champ,
    /// la page est suspendue par le système, et le clic sur le bouton d'arrêt
    /// n'aboutirait pas. ChatGPT continuerait d'écouter, invisible.
    func interrompre() async {
        await annuler()
        masquerBarre()
    }

    /// Le parcours complet : se connecter, puis calibrer.
    ///
    /// Les deux étapes ne sont pas de même rang et l'ordre n'est pas
    /// négociable : les trois boutons à désigner n'existent que dans une
    /// conversation, donc calibrer sans session revient à montrer des boutons
    /// absents. La première version sautait pourtant droit au calibrage et
    /// laissait l'utilisateur devant un refus, là où il attendait une consigne.
    ///
    /// L'attente de la connexion est active plutôt que de rendre la main :
    /// personne ne devrait avoir à rouvrir un menu pour signaler qu'il vient de
    /// se connecter.
    func configurer(_ termine: (() -> Void)? = nil) {
        guard !configurationEnCours else { ouvrirFenetre(); termine?(); return }
        configurationEnCours = true
        let page = pageActive()
        page.montrer()
        Task {
            // `termine` dans le `defer` : elle rafraîchit l'écran de réglages,
            // qui doit refléter l'état réel même quand la configuration est
            // abandonnée — attente de connexion expirée, calibration
            // interrompue par une erreur.
            defer { configurationEnCours = false; termine?() }

            if await page.etatConnexion() != .connecte {
                Self.alerter("Étape 1 sur 2 — se connecter à ChatGPT", """
                    La fenêtre ChatGPT est ouverte derrière ce message. Créez un compte \
                    ou connectez-vous : c'est votre session, Caspr ne fait que l'héberger.

                    À savoir : « Continuer avec Google » ne fonctionne pas ici. Google \
                    refuse volontairement ses connexions dans une fenêtre embarquée, \
                    quelle que soit l'application. Une adresse e-mail et un mot de passe \
                    fonctionnent — un compte dédié convient très bien.

                    Le calibrage démarrera tout seul dès que la conversation s'affichera. \
                    Rien d'autre à faire.
                    """)

                // Dix minutes : le temps d'une création de compte, vérification
                // de l'adresse comprise. Passé ce délai on renonce en silence
                // plutôt que d'interrompre quelqu'un qui est passé à autre
                // chose ; « Terminer la configuration… » reste dans le menu.
                var connecte = false
                for _ in 0..<600 {
                    try? await Task.sleep(for: .seconds(1))
                    guard actif else { return }
                    if await page.etatConnexion(patience: 1) == .connecte {
                        connecte = true
                        break
                    }
                }
                guard connecte else { return }
            }

            Self.alerter("Étape 2 sur 2 — montrer les boutons", """
                Vous êtes connecté. Il reste à montrer à Caspr où sont les trois \
                boutons de la dictée, en les cliquant une fois chacun.

                Ils ne sont pas devinés une fois pour toutes : ChatGPT remanie sa page \
                sans prévenir, et les redésigner prend dix secondes là où un réglage \
                figé demanderait une mise à jour de l'application.
                """)
            await calibrationGuidee(page)
        }
    }

    /// Les trois clics.
    private func calibrationGuidee(_ page: RelaisPage) async {
        let etapes: [(RelaisCible, String)] = [
            (.micro, "Bouton 1 sur 3 — après avoir fermé ce message, cliquez le bouton "
                   + "micro dans la page. L'enregistrement va démarrer, c'est normal : "
                   + "il faut qu'il tourne pour que le bouton d'arrêt existe."),
            (.stop, "Bouton 2 sur 3 — cliquez maintenant le bouton d'arrêt, le carré, "
                  + "pas la flèche bleue d'envoi."),
            (.composeur, "Bouton 3 sur 3 — cliquez la zone de texte, celle où le texte "
                       + "transcrit vient d'apparaître."),
        ]
        for (cible, consigne) in etapes {
            Self.alerter("Calibration du relais", consigne)
            do { _ = try await page.calibrer(cible) }
            catch { Self.alerter("Relais", error.localizedDescription); return }
        }
        await page.annuler()
        page.cacher()
        NSApp.hide(nil)
        Self.alerter("C'est prêt",
                     "La touche de dictée écrit maintenant par ChatGPT. "
                     + "Pour revenir aux moteurs de Caspr, éteignez "
                     + "« ChatGPT Web Preview » dans Réglages › Moteur IA.")
    }

    /// Calibre les deux boutons de l'aller-retour, en deux temps guidés.
    ///
    /// Ils n'existent qu'après coup : le bouton d'envoi tant que la zone est
    /// vide, la réponse tant que rien n'a été envoyé. La calibration les fait
    /// donc apparaître — elle écrit un message d'essai, puis attend la réponse.
    /// C'est plus long que trois clics, et c'est pourquoi elle n'est demandée
    /// qu'à qui choisit un mode qui en a besoin.
    func calibrerDialogue(_ termine: (() -> Void)? = nil) {
        guard !configurationEnCours else { ouvrirFenetre(); termine?(); return }
        configurationEnCours = true
        let page = pageActive()
        page.montrer()
        Task {
            defer { configurationEnCours = false; termine?() }
            guard await page.etatConnexion() == .connecte else {
                Self.alerter("Pas connecté",
                             "Connectez-vous à ChatGPT avant de calibrer l'aller-retour.")
                return
            }
            // Les trois boutons de l'étape 1 ne sont pas redemandés : ils sont
            // déjà connus, et refaire ce qui est fait n'apprend rien.
            let ecrit = await page.preparerCalibrationEnvoi()
            Self.alerter("Bouton 1 sur 2 — l'envoi", ecrit ? """
                Un message d'essai vient d'être écrit dans la page. Après avoir fermé \
                ce message, cliquez le bouton d'envoi — la flèche bleue, à droite de la \
                zone de texte.

                Il partira réellement dans votre conversation : c'est nécessaire pour \
                qu'une réponse existe et qu'on puisse la désigner à l'étape suivante.
                """ : """
                Le message d'essai n'a pas pu être écrit tout seul dans la page.

                Tapez donc n'importe quoi dans la zone de texte — un simple « bonjour » \
                suffit — puis cliquez le bouton d'envoi, la flèche bleue à droite.

                Le bouton d'envoi n'apparaît qu'une fois la zone remplie : c'est pour \
                ça qu'il faut écrire quelque chose. Le message partira réellement, afin \
                qu'une réponse existe et qu'on puisse la désigner ensuite.
                """)
            do { _ = try await page.calibrer(.envoi) }
            catch { Self.alerter("Relais", error.localizedDescription); return }

            Self.alerter("Bouton 2 sur 2 — la réponse", """
                Attendez que ChatGPT ait fini de répondre, puis cliquez sur sa réponse.

                Sur le texte lui-même, pas sur les icônes en dessous.
                """)
            do { _ = try await page.calibrer(.reponse) }
            catch { Self.alerter("Relais", error.localizedDescription); return }

            page.charger()
            page.cacher()
            NSApp.hide(nil)
            Self.alerter("C'est prêt",
                         "Le mode « Réorganiser » est utilisable. Il se choisit sur la "
                         + "barre de dictée, à côté de « Brut ».")
        }
    }

    /// Ce que le relais voit de la page, en clair.
    ///
    /// Quand un clic ne prend pas, la seule question utile est « sur quoi
    /// as-tu cliqué ? ». Sans cet écran, il n'y a aucun moyen de distinguer un
    /// sélecteur devenu caduc d'un bouton qui refuse de répondre, et le seul
    /// recours est de tout recalibrer en espérant.
    func diagnostic() {
        let page = pageActive()
        let sel = RelaisSelecteurs.charger()
        Task {
            let connexion = await page.etatConnexion(patience: 2)
            let ecoute = await page.estEnEnregistrement()
            let micro = page.microOuvert
            func ligne(_ nom: String, _ valeur: String) -> String {
                valeur.isEmpty ? "\(nom) : (non calibré — heuristique)" : "\(nom) : \(valeur)"
            }
            Self.alerter("Diagnostic du relais", """
                Session : \(connexion == .connecte ? "connectée" : "pas connectée")
                Page : \(ecoute ? "en train d'écouter" : "au repos")
                Micro tenu par la page : \(micro ? "oui" : "non")

                \(ligne("Micro", sel.micro))
                \(ligne("Arrêt", sel.stop))
                \(ligne("Zone de texte", sel.composeur))
                """)
        }
    }

    private static func alerter(_ titre: String, _ texte: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = titre
        a.informativeText = texte
        a.runModal()
    }
}

/// Adaptateur vers le protocole des moteurs.
///
/// Il ignore `request.samples`, qui est vide par construction : Caspr
/// n'enregistre pas pendant une dictée relais, puisque le son appartient au
/// micro ouvert par la page. C'est aussi ce qui rend l'aperçu en direct
/// impossible ici — il faudrait un second flux, celui-là même qui prive de son
/// la capture de Caspr.
///
/// Se conformer à `SpeechEngine` plutôt qu'inventer un chemin parallèle a une
/// vertu précise : `transcribeAndInject` n'a rien à savoir du relais, donc
/// l'insertion, l'historique, les échecs et la barre marchent sans une ligne
/// de plus.
@MainActor
struct RelaisEngine: SpeechEngine {
    var displayName: String { "ChatGPT (relais)" }

    var identity: EngineIdentity { EngineIdentity(engine: "relais", model: "chatgpt-web") }

    func isReady() async -> Bool { Relais.partage.estCalibre }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let debut = Date()
        // Les échantillons sont vides par construction : Caspr n'enregistre
        // pas pendant une dictée relais. La durée vient de l'horloge.
        let secondes = Relais.partage.secondesEcoulees
        let texte: String
        // La page reste ouverte d'une dictée à l'autre. Elle était détruite à
        // chaque cycle tant que Caspr enregistrait en parallèle — il fallait
        // bien lui rendre le micro. Les deux modes s'excluant désormais, plus
        // personne ne le lui dispute, et le raccourci redevient instantané.
        texte = try await Relais.partage.arreterEtLire(secondesDictees: secondes)
        // La seconde passe, quand le mode la demande. Elle rend le brut si
        // elle échoue : rien de ce qui a été dit ne se perd.
        let rendu = await Relais.partage.transformer(texte, mode: RelaisMode.courant)
        let ms = Date().timeIntervalSince(debut) * 1000
        return TranscriptionResult(
            text: rendu,
            mode: request.mode,
            windowSeconds: secondes,
            truncated: false,
            // Le relais ne distingue ni mel, ni encodeur, ni décodeur : le
            // contrat prévoit ce cas, et demande de tout mettre dans un poste
            // plutôt que d'inventer une répartition.
            latency: .init(melMs: 0, encoderMs: 0, decoderMs: ms, wallMs: ms))
    }
}
