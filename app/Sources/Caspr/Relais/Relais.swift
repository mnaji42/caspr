import AppKit
import CasprCore
import SwiftUI
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
final class Relais: ObservableObject {
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

    /// Ce que le relais est en train de faire — la seule source de vérité.
    ///
    /// Deux flux pilotent la même page : la dictée et la calibration. Rien ne
    /// les empêchait de tourner ensemble, et c'était une bombe à retardement.
    /// Appuyer sur la touche de dictée pendant une calibration lançait un cycle
    /// qui cliquait le micro par programme — et le guetteur de la calibration
    /// interceptait ce clic-là, prenant la commande de Caspr pour un geste de
    /// l'utilisateur. Tout ce qui suivait était faux.
    ///
    /// Une occupation unique, consultée aux quelques endroits qui commencent
    /// quelque chose, vaut mieux qu'une forêt de conditions dispersées : elle
    /// dit *ce qui a lieu*, et chaque action en déduit si elle a le droit de
    /// commencer.
    enum Occupation: Equatable {
        case libre
        case calibration
        case dictee

        var raison: String? {
            switch self {
            case .libre: nil
            case .calibration: "Une calibration est en cours."
            case .dictee: "Une dictée est en cours."
            }
        }
    }

    /// Publiée, pour que l'écran de réglages ne montre jamais un état périmé.
    ///
    /// Il lisait l'occupation une fois, à sa création, et gardait ce qu'il avait
    /// vu : le message « une dictée est en cours » restait affiché après la fin
    /// de la dictée, et seul un aller-retour vers un autre onglet le remettait
    /// d'aplomb. C'est la troisième fois que cet écran affiche un état figé —
    /// le publier supprime la classe entière plutôt que le symptôme.
    @Published private(set) var occupation: Occupation = .libre

    /// Marque le début d'une dictée, ou refuse si la place est prise.
    func prendreLaMainPourDictee() -> Bool {
        guard occupation == .libre else { return false }
        occupation = .dictee
        return true
    }

    /// Rend la main à la fin d'un cycle de dictée, quelle qu'en soit l'issue.
    func rendreLaMain() {
        guard occupation == .dictee else { return }
        occupation = .libre
    }

    /// Le parcours de calibration en cours, retenu pour pouvoir y renoncer.
    ///
    /// Un drapeau ne suffisait pas : fermer la fenêtre en pleine calibration
    /// laissait la tâche attendre un clic qui ne viendrait jamais, le drapeau
    /// restait levé, et plus rien ne repartait jusqu'au redémarrage de
    /// l'application. Une étape d'accueil doit toujours pouvoir être
    /// abandonnée — c'est même là qu'on en a le plus besoin.
    private var calibration: Task<Void, Never>?
    var calibrationEnCours: Bool { occupation == .calibration }

    /// Met fin à la calibration, d'où qu'on le demande.
    func abandonnerCalibration() {
        guard calibration != nil else { return }
        calibration?.cancel()
        calibration = nil
        occupation = .libre
        Task {
            await page?.abandonnerCalibration()
            page?.cacher()
        }
        Log.info("relais : calibration abandonnée")
    }

    /// Construite à la première utilisation, jamais avant.
    private var page: RelaisPage?

    private func pageActive() -> RelaisPage {
        if let page { return page }
        let neuve = RelaisPage()
        neuve.surFermeture = { [weak self] in self?.abandonnerCalibration() }
        page = neuve
        return neuve
    }

    var estCalibre: Bool { RelaisSelecteurs.charger().estCalibre }
    /// Les deux sélecteurs supplémentaires de l'aller-retour sont-ils connus ?
    var saitDialoguer: Bool { RelaisSelecteurs.charger().saitDialoguer }
    /// Vrai quand la réponse est récupérée par le bouton de ChatGPT.
    var saitCopier: Bool { RelaisSelecteurs.charger().saitCopier }

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
    /// Le mode est lu **ici**, une fois la transcription obtenue, et non au
    /// début de la dictée. C'est ce que la pastille promet : comme pour
    /// « Curseur | Notes », le choix qui compte est le dernier fait, y compris
    /// pendant qu'on parle.
    ///
    /// **En cas d'échec, la transcription brute est rendue telle quelle.** Une
    /// dictée de dix minutes ne doit pas se perdre parce que la seconde passe
    /// n'a pas abouti : cette application s'interdit partout ailleurs de faire
    /// tout redire, et ce n'est pas ici qu'elle commencerait. La raison part
    /// dans le journal, et la conversation reste ouverte dans la fenêtre du
    /// relais pour qu'on puisse voir ce qui s'est passé.
    func transformer(_ brut: String, module: RelaisModule) async throws -> String {
        // Ce que le module exige, et non un drapeau global : c'est lui qui
        // sait de quoi il a besoin, et lui seul.
        guard module.demandeUnAllerRetour,
              module.estUtilisable(RelaisSelecteurs.charger()),
              !brut.isEmpty
        else { return brut }
        // La patience suit la longueur du texte : une page se réorganise en
        // quelques secondes, dix minutes de monologue demandent bien plus.
        // Trois minutes de plancher, une seconde par vingt caractères.
        let patience = max(180.0, Double(brut.count) / 20)
        do {
            let texte = try await pageActive()
                .reorganiserSurPlace((avant: module.avant, apres: module.apres),
                                     patienceSecondes: patience)
            guard !texte.isEmpty else {
                Log.error("relais : réponse vide, transcription brute conservée")
                return brut
            }
            Log.info("relais : \(module.identifiant) — \(brut.count) → \(texte.count) caractères")
            return texte
        } catch is CancellationError {
            // Annuler veut dire annuler. Rendre le brut ici insérerait un texte
            // dont on vient de demander l'abandon.
            throw CancellationError()
        } catch {
            Log.error("relais : \(module.identifiant) a échoué (\(error.localizedDescription)) "
                      + "— transcription brute conservée")
            return brut
        }
    }

    /// Adopte la page ouverte dans la fenêtre comme point de départ.
    ///
    /// On lit l'adresse plutôt que de la faire saisir : personne ne recopie à
    /// la main l'URL d'un projet ChatGPT sans se tromper, et elle est sous les
    /// yeux de qui vient d'y naviguer.
    func adopterPageDeDepart() {
        guard let page, let url = page.adresseCourante, RelaisPage.estChatGPT(url) else {
            Self.alerter("Point de départ",
                         "Ouvrez d'abord la fenêtre du relais et allez sur la page "
                         + "ChatGPT que vous voulez utiliser — un projet dédié, par "
                         + "exemple.")
            return
        }
        RelaisPage.depart = url
        Self.alerter("Point de départ enregistré", """
            Les conversations créées par Caspr partiront désormais de cette page :

            \(url.absoluteString)

            Une dictée « Réorganiser » ouvre une conversation neuve à chaque fois — \
            sans quoi la note précédente orienterait la suivante. Les regrouper dans un \
            projet dédié évite qu'elles se mêlent à vos vraies conversations.
            """)
    }

    func oublierPageDeDepart() {
        RelaisPage.reinitialiserDepart()
        Self.alerter("Point de départ",
                     "Retour à la page d'accueil de ChatGPT.")
    }

    var departPersonnalise: Bool { RelaisPage.departEstPersonnalise }

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

    /// Apprendre à Caspr tout ce que la page sait faire, d'un seul parcours.
    ///
    /// Une seule calibration, et non plus une par fonctionnalité. Les
    /// découper en étapes numérotées suggérait un escalier, alors que ce sont
    /// des capacités indépendantes : « Discuter » exige d'envoyer sans jamais
    /// récupérer, donc moins que « Réorganiser » qui venait pourtant avant lui.
    /// Et pour l'utilisateur, apprendre six boutons d'affilée coûte une minute
    /// une fois, là où revenir trois fois coûte la surprise à chaque fois.
    ///
    /// Les boutons n'existent pas tous au même moment : celui d'envoi réclame
    /// un texte dans la zone, ceux de la barre d'actions réclament une réponse.
    /// Le parcours les fait donc apparaître, en écrivant puis en envoyant un
    /// message d'essai.
    func calibrerTout(_ termine: (() -> Void)? = nil) {
        guard occupation == .libre else {
            Self.alerter("Pas maintenant",
                         (occupation.raison ?? "") + " Terminez-la avant de calibrer.")
            termine?()
            return
        }
        occupation = .calibration
        let page = pageActive()
        page.montrer()
        calibration = Task {
            defer { calibration = nil; occupation = .libre; termine?() }

            guard await attendreConnexion(page) else { return }

            // Une conversation neuve pour calibrer.
            //
            // La page ouverte porte peut-être une discussion en cours, et son
            // texte dans la zone de saisie : on désignerait alors des boutons
            // dans un état qui n'est pas celui d'un départ, et le message
            // d'essai s'ajouterait à ce qui traînait. Recharger coûte deux
            // secondes et supprime toute la classe de surprises.
            page.charger()
            guard await page.attendreComposeurPret(secondes: 30) else {
                Self.alerter("Relais", "La page ChatGPT n'a pas fini de se charger.")
                return
            }
            // Vider la zone avant de commencer.
            //
            // ChatGPT conserve le brouillon non envoyé et le réinstalle au
            // rechargement : on demandait donc de cliquer le micro devant un
            // texte laissé là par une tentative précédente, que la dictée
            // serait venue rallonger.
            // Par les heuristiques, sans se fier au calibrage en place : il est
            // peut-être absent, et s'il est là c'est peut-être lui qu'on
            // remplace parce qu'il est faux.
            await page.viderComposeur(selecteur: "")

            // 1 — la dictée. Les trois repères du socle.
            let socle: [(RelaisCible, String)] = [
                (.micro, "Cliquez le bouton micro dans la page. L'enregistrement va "
                       + "démarrer, c'est normal : il faut qu'il tourne pour que le "
                       + "bouton d'arrêt existe."),
                (.stop, "Cliquez maintenant le bouton d'arrêt — le carré, pas la flèche "
                      + "bleue d'envoi."),
                (.composeur, "Cliquez la zone de texte, celle où le texte transcrit vient "
                           + "d'apparaître."),
            ]
            for (rang, (cible, consigne)) in socle.enumerated() {
                guard Self.demander("Repère \(rang + 1) sur 6 — \(cible.libelle)", consigne)
                else { abandonnerCalibration(); return }
                guard await calibrerUn(page, cible) else { return }
            }

            // 2 — l'envoi. Le bouton n'existe qu'une fois la zone remplie.
            let ecrit = await page.preparerCalibrationEnvoi()
            let suite = Self.demander("Repère 4 sur 6 — le bouton d'envoi", ecrit ? """
                Un message d'essai vient d'être écrit dans la page. Cliquez le bouton \
                d'envoi — la flèche bleue, à droite de la zone de texte.

                Il partira réellement dans votre conversation : c'est nécessaire pour \
                qu'une réponse existe et qu'on puisse désigner ses boutons ensuite.
                """ : """
                Le message d'essai n'a pas pu être écrit tout seul.

                Tapez n'importe quoi dans la zone de texte — un « bonjour » suffit — puis \
                cliquez le bouton d'envoi, la flèche bleue à droite. Il n'apparaît qu'une \
                fois la zone remplie, et le message doit partir pour qu'une réponse \
                existe.
                """)
            guard suite else { abandonnerCalibration(); return }
            guard await calibrerUn(page, .envoi) else { return }

            // 3 — la barre d'actions de la réponse.
            guard Self.demander("Repère 5 sur 6 — copier la réponse", """
                Attendez que ChatGPT ait fini de répondre, puis cliquez l'icône \
                « copier » sous **sa** réponse — deux carrés superposés.

                Sous la réponse, pas sous votre propre message : la page en porte une par \
                message, et Caspr retient au passage le bloc qui l'entoure pour ne jamais \
                confondre les deux.
                """) else { abandonnerCalibration(); return }
            guard await calibrerUn(page, .copier) else { return }

            guard Self.demander("Repère 6 sur 6 — lire à haute voix", """
                Cliquez « Lire à haute voix » sous la même réponse — le petit \
                haut-parleur.

                S'il n'apparaît pas directement, ouvrez d'abord le menu « … » : Caspr \
                retient le chemin complet et le refera pour vous. Deux clics, donc, si \
                votre interface les demande.

                Cette capacité sert aux modules qui doivent parler — une traduction \
                qu'on fait entendre à quelqu'un, par exemple. Elle est facultative : \
                abandonnez maintenant si elle ne vous sert pas, le reste est déjà appris.
                """) else { abandonnerCalibration(); return }
            do { try await page.calibrerLecture() }
            catch is CancellationError { return }
            catch { Self.alerter("Relais", error.localizedDescription) }

            page.charger()
            page.cacher()
            NSApp.hide(nil)
            Self.alerter("C'est appris",
                         "Caspr sait dicter, envoyer, récupérer une réponse et la faire "
                         + "lire à haute voix. Les modules qui en ont besoin sont "
                         + "désormais utilisables.")
        }
    }

    /// Attend la connexion, en l'expliquant si elle manque.
    private func attendreConnexion(_ page: RelaisPage) async -> Bool {
        if await page.etatConnexion() == .connecte { return true }
        Self.alerter("D'abord, se connecter à ChatGPT", """
            La fenêtre ChatGPT est ouverte derrière ce message. Créez un compte ou \
            connectez-vous : c'est votre session, Caspr ne fait que l'héberger.

            À savoir : « Continuer avec Google » ne fonctionne pas ici. Google refuse \
            volontairement ses connexions dans une fenêtre embarquée, quelle que soit \
            l'application. Une adresse e-mail et un mot de passe fonctionnent — un \
            compte dédié convient très bien.

            La suite démarrera toute seule dès que la conversation s'affichera.
            """)
        for _ in 0..<600 {                                  // dix minutes
            try? await Task.sleep(for: .seconds(1))
            guard actif else { return false }
            if await page.etatConnexion(patience: 1) == .connecte { return true }
        }
        return false
    }

    private func calibrerUn(_ page: RelaisPage, _ cible: RelaisCible) async -> Bool {
        do { _ = try await page.calibrer(cible); return true }
        catch is CancellationError { return false }
        catch { Self.alerter("Relais", error.localizedDescription); return false }
    }

    /// Une consigne, avec une porte de sortie.
    ///
    /// Un dialogue à un seul bouton force à aller au bout de ce qu'on a
    /// commencé. Pour un parcours de six étapes qui pilote une page web, c'est
    /// la garantie qu'un imprévu — une page qui ne réagit pas, un bouton
    /// introuvable — laisse quelqu'un coincé.
    @discardableResult
    private static func demander(_ titre: String, _ texte: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = titre
        a.informativeText = texte
        a.addButton(withTitle: "Continuer")
        a.addButton(withTitle: "Abandonner")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Ce que le relais voit de la page, en clair.    /// Ce que le relais voit de la page, en clair.
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
        let rendu = try await Relais.partage.transformer(texte, module: RelaisCatalogue.courant)
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
