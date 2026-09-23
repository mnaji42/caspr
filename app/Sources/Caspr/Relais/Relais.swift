import AppKit
import CasprCore
import SwiftUI
import WebKit

/// Le relais : dicter par le transcripteur de ChatGPT, sur la touche de dictée
/// habituelle.
///
/// C'est **l'une des deux voies** de Caspr, pas un moteur de plus. Sur la voie
/// ChatGPT, la page écoute et Caspr n'ouvre jamais son micro ; sur la voie
/// macOS, la page n'existe pas. L'exclusion n'est pas une préférence de
/// présentation : les deux ne peuvent pas ouvrir le micro en même temps —
/// mesuré au niveau crête de l'enregistrement, 0,072 avant tout usage du
/// relais, 0,000 après. C'est pourquoi elle est la forme d'un type,
/// `VoieDeDictee`, et non un interrupteur que le relais tiendrait seul.
///
/// **Rien n'est construit tant que la voie n'est pas ChatGPT.** La WKWebView et
/// la session ChatGPT n'existent pas pour qui dicte par macOS.
@MainActor
final class Relais: ObservableObject {
    static let partage = Relais()

    /// La voie retenue est-elle ChatGPT ?
    ///
    /// Relue à chaque fois, jamais recopiée : la voie a un seul endroit où
    /// vivre, et une copie ici serait une seconde décision à tenir d'accord.
    private var voieChatGPT: Bool {
        switch Preferences.shared.voie {
        case .chatgpt: true
        case .apple: false
        }
    }

    /// Fait exister la page, ou la détruit, selon la voie qu'on vient de
    /// choisir.
    ///
    /// Vers ChatGPT, elle est chargée tout de suite : la première dictée ne
    /// doit pas payer l'ouverture de chatgpt.com. Vers macOS, elle part — son
    /// processus tient le micro de la machine, et le magnétophone de Caspr
    /// n'entendrait que du silence tant qu'elle vit.
    ///
    /// Sauf pendant une dictée, dans un sens comme dans l'autre : la voie est
    /// figée à l'appui, et basculer vaut pour la suivante.
    /// - Une dictée ChatGPT va au bout sur la page qu'elle a prise ; c'est la
    ///   fin du cycle qui la détruit alors (cf. `rendreLaMain`).
    /// - Une dictée macOS garde le micro pour elle : la page n'est construite
    ///   qu'une fois le magnétophone arrêté (cf. `macOSRendLeMicro`).
    func suivreLaVoie() {
        switch Preferences.shared.voie {
        case .chatgpt:
            guard !ecouteMacOS else { return }
            _ = try? pageActive()
        case .apple:
            guard occupation != .dictee else { return }
            quitterLaPage()
        }
    }

    /// La page a-t-elle une raison d'exister ?
    ///
    /// Sur la voie ChatGPT, oui — sauf pendant la dictée macOS commencée avant
    /// qu'on en change, qui garde le micro jusqu'au bout. Sur la voie macOS,
    /// seulement pour la dictée ChatGPT commencée avant qu'on en change : elle
    /// va au bout sur la page qu'elle a prise.
    private var pageVoulue: Bool {
        switch Preferences.shared.voie {
        case .chatgpt: !ecouteMacOS
        case .apple: occupation == .dictee
        }
    }

    /// Le magnétophone de Caspr écoute : une dictée macOS est entre l'appui et
    /// l'arrêt.
    ///
    /// Tenu à part de l'occupation, qui dit ce que fait **la page** : une
    /// dictée macOS ne la pilote pas, elle interdit seulement qu'elle naisse.
    /// Passer à ChatGPT en pleine dictée macOS construisait la page tout de
    /// suite, calibration comprise quand il en manquait une — et une page
    /// ChatGPT qui existe fait tomber la crête de l'enregistrement de 0,072 à
    /// 0,000 (cf. RELAIS.md) : le reste de la dictée s'enregistrait sur du
    /// silence.
    ///
    /// Publié, pour que la carte grise ce qui construirait la page et dise
    /// pourquoi.
    @Published private(set) var ecouteMacOS = false

    /// Une dictée macOS ouvre le micro de Caspr.
    func macOSPrendLeMicro() {
        ecouteMacOS = true
    }

    /// Le magnétophone est arrêté, quelle qu'en soit l'issue : la page que la
    /// voie réclame peut naître.
    func macOSRendLeMicro() {
        guard ecouteMacOS else { return }
        ecouteMacOS = false
        switch Preferences.shared.voie {
        case .chatgpt: suivreLaVoie()
        // Rien n'a été retenu : la voie macOS ne veut pas de page.
        case .apple: break
        }
    }

    /// Détruit la page que la voie macOS ne veut plus.
    private func quitterLaPage() {
        // Tout de suite, sans attendre la libération : ni discussion ni
        // préparation ne doivent survivre à la décision.
        oublierCeQuiVitSurLaPage()
        // Rendre le micro avant de lâcher la page : passer à macOS doit rendre
        // Caspr exactement à l'état d'avant. C'est la porte de sortie, elle
        // doit être sans reste.
        Task { await libererPage() }
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
    ///
    /// C'est aussi là que part la page quand on a choisi macOS pendant la
    /// dictée : elle attendait que celle-ci s'achève (cf. `suivreLaVoie`).
    func rendreLaMain() {
        guard occupation == .dictee else { return }
        occupation = .libre
        switch Preferences.shared.voie {
        case .chatgpt: break
        case .apple: if page != nil { quitterLaPage() }
        }
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
    /// La calibration en cours est-elle le parcours automatique ? Abandonné,
    /// il laisse une page à remettre d'aplomb (cf. `abandonnerCalibration`).
    private var calibrationAutomatique = false
    /// Le numéro du parcours automatique en cours : une fin qui arrive après
    /// un abandon ne rend pas la main à la place de ce qui a commencé depuis.
    private var numeroCalibration = 0

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
        // Le parcours automatique a pu laisser la page en écoute, ou le
        // message d'essai à moitié écrit. Elle est rechargée par la
        // préparation, et non à part : c'est elle que la dictée suivante
        // attend avant de cliquer le micro.
        if calibrationAutomatique {
            calibrationAutomatique = false
            lancerPreparation { page in
                await page.rendreLeMicro()
                page.charger()
                _ = await page.attendreComposeurPret(secondes: 30)
            }
        }
        Log.info("relais : calibration abandonnée")
    }

    /// Construite à la première utilisation, jamais avant.
    private var page: RelaisPage?

    /// La page, construite au besoin — **jamais sur la voie macOS**, hors de la
    /// dictée ChatGPT qui a commencé avant qu'on la choisisse, ni pendant une
    /// dictée macOS (cf. `pageVoulue`).
    ///
    /// Elle se reconstruisait sans rien demander. Éteindre le relais en pleine
    /// dictée détruisait la page, puis l'étape suivante du cycle en faisait
    /// une neuve : chatgpt.com rouvert derrière une case décochée, et le micro
    /// repris par une page que plus personne n'attendait — la dictée macOS
    /// suivante n'enregistrait que du silence. Une dictée en vol garde
    /// désormais sa page jusqu'au bout, et c'est sa fin qui la détruit ; hors
    /// d'elle, rien ne la reconstruit.
    private func pageActive() throws -> RelaisPage {
        if let page { return page }
        guard pageVoulue else { throw RelaisPage.Erreur.relaisEteint }
        let neuve = RelaisPage()
        neuve.surFermeture = { [weak self] in self?.fenetreFermee() }
        neuve.surMort = { [weak self] in self?.surPageInterrompue?() }
        neuve.surAffichage = { [weak self] in self?.surAffichageChange?() }
        neuve.surConnexion = { [weak self] in self?.sessionVue = $0 }
        page = neuve
        return neuve
    }

    var estCalibre: Bool { RelaisSelecteurs.charger().estCalibre }

    /// La session ChatGPT telle que la page l'a montrée en dernier.
    ///
    /// `.inconnu` tant qu'aucune page ne l'a dit depuis le lancement. Ce n'est
    /// pas une mesure fraîche — seule la page en donne une, et pas sans
    /// attendre —, c'est la dernière chose **vue** : l'écran de connexion
    /// d'une session perdue, ou « Se déconnecter ».
    ///
    /// Publiée : les réglages de la voie la montrent, et doivent changer
    /// d'avis quand la page change le sien.
    @Published private(set) var sessionVue: RelaisPage.Connexion = .inconnu

    /// Connecté et calibré, autant qu'on puisse le savoir sans interroger la
    /// page : ce que la voie ChatGPT exige pour dicter.
    ///
    /// Calibré implique connecté une fois — la calibration ne commence pas
    /// sans session (cf. `attendreConnexion`). Reste la session perdue
    /// depuis : elle compte dès que la page l'a montrée.
    var saitDicter: Bool { estCalibre && sessionVue != .deconnecte }

    /// Les deux sélecteurs supplémentaires de l'aller-retour sont-ils connus ?
    var saitDialoguer: Bool { RelaisSelecteurs.charger().saitDialoguer }
    /// Vrai quand la réponse est récupérée par le bouton de ChatGPT.
    var saitCopier: Bool { RelaisSelecteurs.charger().saitCopier }

    /// Charge la page au lancement quand la voie est déjà ChatGPT.
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
        guard voieChatGPT, estCalibre else { return }
        _ = try? pageActive()
    }

    // MARK: - Cycle de dictée

    private var debut = Date()
    var secondesEcoulees: Double { Date().timeIntervalSince(debut) }

    /// L'attente de la dictée qui s'achève, ouverte à l'arrêt de l'écoute.
    ///
    /// Retenue ici pour que la barre la lise : c'est elle qui sait ce qu'on
    /// attend et depuis quand. Oubliée à l'appui suivant, pour qu'une barre
    /// ne montre jamais le chrono de la dictée d'avant.
    private(set) var attente: RelaisAttente?

    /// Le message d'une sortie qui n'écrit nulle part est chez ChatGPT.
    ///
    /// Passé ce point, il n'y a plus rien à abandonner : l'envoi ne se défait
    /// pas, et ChatGPT répond déjà. La touche de dictée cesse alors seulement
    /// d'attendre la lecture à haute voix, et la discussion s'ouvre. Traitée
    /// en abandon, elle laissait la discussion fermée, et la fin du cycle
    /// rechargeait la page — la conversation effacée pendant que ChatGPT y
    /// répondait, au moment même où l'on appuyait pour lui répondre.
    private(set) var messageParti = false

    /// Ce que la barre affiche pendant l'attente, `nil` avant qu'elle ne
    /// commence.
    var avancement: RecordingOverlay.ProcessingProgress? {
        guard let attente else { return nil }
        return .init(label: attente.phase.libelle, elapsed: attente.ecoule,
                     exitHint: messageParti ? "touche de dictée pour ne plus attendre"
                                            : "touche de dictée pour abandonner")
    }

    /// La préparation de la page pour la dictée suivante, s'il y en a une en
    /// cours.
    ///
    /// Retenue pour pouvoir l'attendre : elle tourne au repos, donc elle est
    /// finie depuis longtemps quand on rappuie — mais « longtemps » n'est pas
    /// « toujours », et rappuyer dans la seconde ne doit pas recharger la page
    /// sous une dictée qui commence. Remise à `nil` par la tâche elle-même
    /// quand elle se termine : c'est ce que l'appui observe.
    private var preparation: Task<Void, Never>?
    private var numeroPreparation = 0

    /// Une préparation décidée à la fin d'un échec, et remise à plus tard.
    ///
    /// Un échec de lecture laisse la transcription dans la page et ouvre la
    /// grande fenêtre pour qu'on l'y copie. Préparer tout de suite, c'était
    /// vider ou recharger cette page sous les yeux de qui venait la chercher —
    /// l'inverse de ce que le message d'échec promettait. La préparation
    /// attend donc que l'utilisateur en ait fini : qu'il ferme la fenêtre, ou
    /// qu'il rappuie sur la touche.
    private var preparationDifferee = false {
        // La fenêtre de récupération tient le clavier : Échap y revient au
        // système tant qu'elle attend (cf. `discussionAffichee`).
        didSet { if preparationDifferee != oldValue { surAffichageChange?() } }
    }

    /// L'appui devra-t-il attendre la page ? La barre de Caspr le dit alors,
    /// plutôt que de laisser l'écran muet pendant qu'elle se prépare.
    var preparationEnCours: Bool { preparation != nil || preparationDifferee }

    /// Laisse la page prête pour la prochaine dictée, maintenant qu'on ne s'en
    /// sert plus.
    ///
    /// C'est **la fin d'une dictée qui prépare la suivante**, et non l'appui qui
    /// découvre l'état où la précédente a laissé la page. Deux raisons, et la
    /// seconde vaut la première.
    ///
    /// La latence : recharger prend une seconde ou deux, pendant lesquelles on
    /// parle déjà et le micro n'est pas ouvert. Au repos, cette seconde ne coûte
    /// rien à personne.
    ///
    /// Et surtout, il n'y a plus rien à décider à l'appui. « Est-ce que je
    /// recharge ? » ne se pose plus : la page est prête, quel que soit le module
    /// qu'on choisira en parlant. C'est ce qui rend le changement d'avis en
    /// pleine phrase sans conséquence — il n'y a pas d'état à rattraper.
    ///
    /// Trois cas, une seule question posée à la page :
    ///
    /// - **en discussion** : le fil ouvert *est* la page prête, on n'y touche
    ///   pas ;
    /// - **la page porte une conversation** — un message est parti, que la suite
    ///   ait abouti ou non : on en ouvre une neuve ;
    /// - **sinon** — le cas de « Brut », qui n'envoie rien : il suffit de vider
    ///   la zone de saisie du texte qu'on vient de dicter.
    ///
    /// Et quand la page ne répond plus du tout, on la recharge : une page
    /// figée ne doit pas devenir la panne de la dictée suivante. **Seulement
    /// dans ce cas.** Une zone qui refuse de se vider sur une page qui répond
    /// n'est pas une page à jeter — c'est souvent une transcription encore en
    /// cours, qu'un rechargement détruirait ; `demarrer()` vide de toute façon
    /// la zone avant d'écouter.
    ///
    /// `apresEchec` remet la préparation à plus tard (cf.
    /// `preparationDifferee`).
    ///
    /// Chaque étape est bornée, parce que l'appui attend cette tâche avant
    /// même d'ouvrir l'écoute : une seule attente sans fin ici, et la barre
    /// « chargeait » indéfiniment, avant que rien n'ait été enregistré.
    func preparerLaProchaine(apresEchec: Bool = false) {
        guard !apresEchec else {
            preparation?.cancel()
            preparation = nil
            preparationDifferee = true
            return
        }
        lancerPreparation { [weak self] page in
            await self?.preparer(page)
        }
    }

    /// Le travail de `preparerLaProchaine`, à part pour que l'arrêt d'une
    /// dictée abandonnée le fasse aussi (cf. `interrompre`).
    private func preparer(_ page: RelaisPage) async {
        guard !enDiscussion, !Task.isCancelled else { return }
        switch await page.tientUneConversation() {
        case true?:
            page.charger()
            let prete = await page.attendreComposeurPret(secondes: 30)
            guard !prete, !Task.isCancelled else { return }
            // La page vient d'être rechargée : il n'y a rien à y perdre, et
            // un second essai rattrape un chargement resté en route.
            Log.error("relais : la page rechargée est restée sans zone de saisie — "
                      + "nouveau rechargement")
            page.charger()
            _ = await page.attendreComposeurPret(secondes: 30)
        case false?:
            await page.viderComposeur()
        case nil:
            guard !Task.isCancelled else { return }
            Log.error("relais : la page ne répond plus — rechargement au repos")
            page.charger()
            _ = await page.attendreComposeurPret(secondes: 30)
        }
    }

    /// Recharge la page au repos, discussion ou non.
    ///
    /// Pour une page figée, et pour elle seule : le fil qu'elle portait est
    /// perdu de toute façon, et la garder sous prétexte qu'une discussion est
    /// ouverte condamnait chaque appui au même échec, cinq secondes plus tard,
    /// sous un message qui promettait un rechargement jamais fait.
    private func rechargerAuRepos() {
        lancerPreparation { page in
            Log.error("relais : la page ne répond plus — rechargement au repos")
            page.charger()
            _ = await page.attendreComposeurPret(secondes: 30)
        }
    }

    private func lancerPreparation(_ travail: @escaping @MainActor (RelaisPage) async -> Void) {
        // Remplacer la précédente : deux chemins peuvent demander la
        // préparation à quelques millisecondes d'écart — la fin d'une dictée et
        // la sortie d'une discussion — et la seconde doit simplement prendre la
        // place de la première. L'annulation interrompt aussi un appel au pont
        // resté en suspens.
        preparation?.cancel()
        preparationDifferee = false
        numeroPreparation &+= 1
        let numero = numeroPreparation
        // Voie macOS : il n'y a plus de page à préparer, et surtout pas une
        // neuve à construire (cf. `pageActive`) — ni celle qu'on s'apprête à
        // détruire, que la fin d'une dictée demanderait sinon de préparer.
        guard pageVoulue, let page = try? pageActive() else {
            preparation = nil
            return
        }
        preparation = Task { [weak self] in
            await travail(page)
            guard let self, numeroPreparation == numero else { return }
            preparation = nil
        }
    }

    /// Attend que la page soit prête, sans jamais retenir la touche de dictée.
    ///
    /// `Task.value` ignore l'annulation : attendre la préparation par lui,
    /// c'était laisser l'appui suspendu jusqu'à quarante secondes sur une page
    /// figée, sans que la touche puisse l'interrompre. On observe donc la fin
    /// de la tâche, et l'annulation de l'appui fait cesser l'attente — elle
    /// seule. La préparation, elle, continue : l'appui suivant la trouvera
    /// finie ou l'attendra à son tour.
    ///
    /// Une préparation différée après un échec s'exécute ici : rappuyer, c'est
    /// dire qu'on en a fini avec le texte laissé dans la page.
    private func attendreLaPreparation() async throws {
        if preparationDifferee { preparerLaProchaine() }
        while preparation != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// La grande fenêtre a été fermée par l'utilisateur.
    ///
    /// C'est aussi le moment de faire la préparation remise après un échec :
    /// fermer la fenêtre où l'on venait récupérer son texte, c'est dire qu'on
    /// l'a récupéré.
    private func fenetreFermee() {
        abandonnerCalibration()
        guard preparationDifferee, occupation == .libre else { return }
        preparerLaProchaine()
    }

    /// Appelé chaque fois que ce qui est à l'écran du relais change : une
    /// fenêtre montrée ou rangée, une discussion ouverte ou close, une
    /// récupération commencée ou finie.
    ///
    /// Échap se règle là-dessus (cf. `discussionAffichee`). Il était pris et
    /// rendu au fil des chemins du cycle, et l'un d'eux l'oubliait toujours :
    /// armé après une discussion, il survivait à la fenêtre refermée et
    /// avalait la frappe suivante dans n'importe quelle application — en
    /// fermant le fil au passage.
    var surAffichageChange: (() -> Void)?

    /// Une discussion est-elle ouverte **sous les yeux** ?
    ///
    /// La seule situation, hors enregistrement, où Échap appartient à Caspr :
    /// une fenêtre est là, et c'est elle qu'il ferme. Sans fenêtre — module
    /// qui ne fait que parler, fenêtre fermée à la main — Échap est un
    /// raccourci global qui fermerait un fil qu'on ne voit pas ; la sortie est
    /// alors dans le menu de Caspr. Pendant une récupération non plus : la
    /// fenêtre a le clavier, et Échap y appartient au système.
    ///
    /// La barre compte comme une fenêtre. Une discussion réglée sur
    /// « Barre » la garde à l'écran après la dictée ; ne regarder que la
    /// grande fenêtre rendait Échap au système devant une barre qui flottait
    /// au-dessus du travail, sans autre sortie qu'une entrée du menu. Pas la
    /// barre transparente de « Rien » : il n'y a rien sous les yeux.
    var discussionAffichee: Bool {
        guard enDiscussion, !preparationDifferee, let page else { return false }
        return page.estVisible || page.barreEnVue
    }

    /// Appelé quand la page meurt pendant que la dictée écoute.
    var surPageInterrompue: (() -> Void)?

    func demarrer() async throws {
        // La page a été préparée quand la dictée précédente s'est achevée : il
        // n'y a rien à décider ici, seulement à s'assurer que ce travail est
        // fini. Il l'est, sauf si l'on rappuie dans la seconde.
        try await attendreLaPreparation()
        debut = Date()
        attente = nil
        messageParti = false
        avertissement = nil
        do {
            try await pageActive().demarrer()
        } catch RelaisPage.Erreur.pontMuet {
            // Une page figée au démarrage n'atteint jamais la fin du cycle, où
            // la préparation a lieu : sans ceci, chaque appui retrouverait la
            // même page figée. Elle est rechargée au repos, pour le suivant —
            // en discussion aussi.
            rechargerAuRepos()
            throw RelaisPage.Erreur.pontMuet
        }
    }

    /// Arrête l'écoute et rend la transcription, en ouvrant l'attente que
    /// la suite de la dictée consommera — la transformation comprise.
    ///
    /// L'échéance de toute la suite est fixée ici, sur la durée parlée : la
    /// transcription de ChatGPT dure à proportion de ce qu'on a dit.
    func arreterEtLire(secondesDictees: Double) async throws -> String {
        let attente = RelaisAttente(secondesDictees: secondesDictees)
        self.attente = attente
        Log.info("relais : échéance de la dictée dans \(RelaisAttente.duree(attente.budget))")
        return try await pageActive().arreterEtLire(attente)
    }

    /// Détruit la page, quand on passe à la voie macOS.
    ///
    /// Le processus de contenu de WebKit part avec elle, et c'est lui qui tient
    /// le micro de la machine. Tant qu'une page ChatGPT vit, l'enregistrement
    /// de Caspr ne capte que du silence : choisir macOS doit donc rendre
    /// l'appareil, pas seulement cesser de s'en servir.
    ///
    /// Jamais entre deux dictées : les deux voies s'excluant, personne ne
    /// dispute le micro à la page tant que ChatGPT est retenu, et la garder
    /// ouverte rend le raccourci instantané.
    func libererPage() async {
        guard let ancienne = page else { return }
        page = nil
        // « Se déconnecter » passe aussi par ici, voie ChatGPT : sans cela,
        // une discussion affichée gardait Échap pris après la destruction de
        // sa fenêtre, et avalait la frappe dans n'importe quelle application.
        oublierCeQuiVitSurLaPage()
        surAffichageChange?()
        await ancienne.rendreLeMicro()
        ancienne.detruire()
        Log.info("relais : page libérée")
    }

    /// Ni discussion ni préparation ne survivent à la page : une discussion
    /// restée « ouverte » sur une page détruite gardait sa sortie dans le menu,
    /// et une préparation en vol aurait continué de piloter la page qu'on
    /// libère.
    private func oublierCeQuiVitSurLaPage() {
        preparation?.cancel()
        preparation = nil
        preparationDifferee = false
        enDiscussion = false
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
        sessionVue = .deconnecte
        Log.info("relais : session ChatGPT effacée")
    }

    /// Une conversation est-elle ouverte, en attente d'une suite ?
    ///
    /// Publiée : la barre des menus et les réglages doivent pouvoir le dire, et
    /// c'est un état qui se termine par un geste de l'utilisateur, pas par la
    /// fin d'un cycle.
    @Published private(set) var enDiscussion = false {
        didSet { if enDiscussion != oldValue { surAffichageChange?() } }
    }

    /// La conversation reste sous les yeux, et prend le clavier.
    ///
    /// C'est **ici seulement** que l'état s'ouvre, à la fin d'une dictée que
    /// personne n'est venu chercher. Il était aussi levé à l'appui, dès que le
    /// module du moment ne délivrait nulle part — et il y restait quand on
    /// basculait vers un module qui délivre : la fenêtre disparaissait, mais
    /// Caspr se croyait encore en discussion et poursuivait un fil qu'on ne
    /// voyait plus.
    ///
    /// « Une discussion est ouverte » veut dire une chose et une seule : une
    /// fenêtre attend qu'on en sorte, et la touche de dictée y poursuit le fil.
    /// Échap n'est pas pris ici : il suit la fenêtre (cf. `discussionAffichee`).
    ///
    /// `module` est celui de la dictée qui s'achève, figé à l'arrêt de
    /// l'écoute, et non celui qu'on relirait maintenant.
    func entrerEnDiscussion(_ module: RelaisModule) {
        // Choisir macOS pendant la dictée condamne la page à sa fin : un fil
        // ouvert dessus n'aurait nulle part où continuer.
        guard voieChatGPT else { return }
        enDiscussion = true
        // La fenêtre ne s'ouvre que si le module l'a demandée. « Rien » veut
        // dire rien, ici comme pendant la dictée : on discute à la voix, la
        // réponse est lue à haute voix, et c'est le menu de Caspr qui met fin
        // au fil — Échap n'est pris que devant une fenêtre.
        guard module.affichageEffectif == .page else { return }
        try? pageActive().montrer()
    }

    func terminerDiscussion() {
        guard enDiscussion else { return }
        enDiscussion = false
        // Un échec vient de laisser son texte dans la fenêtre, ouverte pour
        // qu'on l'y copie : ni la cacher, ni la recharger. C'est sa fermeture
        // qui fera la préparation remise (cf. `fenetreFermee`) — la faire ici
        // effaçait le texte que le message d'échec disait récupérable.
        guard !preparationDifferee else {
            Log.info("relais : discussion terminée, page laissée à sa récupération")
            return
        }
        page?.cacher()
        NSApp.hide(nil)
        // Le fil qu'on vient de quitter n'est plus la page prête : il faut en
        // ouvrir une neuve, sans quoi la dictée suivante reprendrait la
        // conversation qu'on vient de fermer.
        preparerLaProchaine()
        Log.info("relais : discussion terminée")
    }

    /// Rend le clavier à l'application où l'on travaille.
    ///
    /// À appeler avant toute insertion au curseur. L'insertion par
    /// accessibilité vise l'élément focalisé de l'application au premier plan :
    /// si c'est la fenêtre du relais — ce qui arrive après une discussion, ou
    /// si l'on bascule vers un module qui écrit en pleine dictée — le texte
    /// partirait dans ChatGPT. Se retirer est le seul geste qui rende la main.
    func rendreLeClavier() async {
        guard page?.estVisible == true else { return }
        page?.cacher()
        NSApp.hide(nil)
        // Le temps que le système redonne le premier plan à l'application
        // précédente : insérer avant qu'elle l'ait repris viserait encore nous.
        try? await Task.sleep(for: .milliseconds(180))
    }

    /// Renvoie le texte à ChatGPT et rend ce qu'il répond, quand le module le
    /// demande.
    ///
    /// Le module est celui de la dictée, figé à l'arrêt de l'écoute : c'est
    /// ce que la pastille promet — comme pour « Curseur | Notes », le choix
    /// qui compte est le dernier fait, y compris pendant qu'on parle.
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
        // L'attente ouverte à l'arrêt de l'écoute, et non une patience de
        // plus : la réponse consomme ce que la transcription a laissé. Chaque
        // phase repartait de trois minutes au moins, et elles s'empilaient.
        let attente = self.attente ?? RelaisAttente(secondesDictees: secondesEcoulees)
        // Une sortie qui n'écrit nulle part n'a rien à rapatrier : on envoie,
        // et l'on s'arrête là. La réponse s'affichera dans la page, que
        // l'utilisateur a sous les yeux.
        if module.sortieParDefaut == .aucune {
            do {
                try await pageActive()
                    .envoyerSansAttendre((avant: module.avant, apres: module.apres),
                                         attente: attente)
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Abandonné avant l'envoi : rien n'est parti, et c'est un
                // abandon, pas un échec à afficher.
                if Task.isCancelled { throw CancellationError() }
                Log.error("relais : \(module.identifiant) n'a pas pu envoyer "
                          + "(\(error.localizedDescription))")
                avertissement = (error as? RelaisPage.Erreur)?.raisonCourte
                    ?? "\(module.nom) n'a pas pu envoyer"
                return ""
            }
            messageParti = true
            Log.info("relais : \(module.identifiant) — envoyé, réponse à l'écran")
            // Un refus — un quota — ou l'échéance passée se dit dans la
            // barre : sans quoi on attend une voix qui ne viendra pas, et
            // l'on redemande.
            if module.ditLaReponse, let page = try? pageActive(),
               let echec = await page.faireLireLaReponse(attente: attente) {
                avertissement = echec.raisonCourte
            }
            // Interrompue, la lecture se tait sans lever, et c'est voulu :
            // le message est parti, l'appui a seulement cessé d'attendre (cf.
            // `messageParti`). Rendre "" ouvre la discussion sur le fil que
            // ChatGPT est en train de remplir.
            if Task.isCancelled {
                Log.info("relais : attente de la lecture interrompue, discussion conservée")
            }
            return ""
        }

        do {
            let texte = try await pageActive()
                .reorganiserSurPlace((avant: module.avant, apres: module.apres),
                                     attente: attente)
            try Task.checkCancellation()
            guard !texte.isEmpty else {
                Log.error("relais : réponse vide, transcription brute conservée")
                avertissement = "ChatGPT a rendu une réponse vide"
                return brut
            }
            if module.ditLaReponse {
                // La réponse est déjà là : ce qui fait défaut ici, c'est le
                // son seul, et le texte remanié s'insère quand même. Trente
                // secondes au plus, et non l'échéance : le texte attend ce
                // clic pour s'insérer.
                await (try? pageActive())?.faireLireLaReponse(attente: attente, auPlus: 30)
                // Interrompue, elle rend la main sans rien dire : sans cette
                // vérification, le texte s'insérait au curseur un instant
                // après l'abandon, et entrait dans l'historique.
                try Task.checkCancellation()
            }
            Log.info("relais : \(module.identifiant) — \(brut.count) → \(texte.count) caractères")
            return texte
        } catch is CancellationError {
            // Annuler veut dire annuler. Rendre le brut ici insérerait un texte
            // dont on vient de demander l'abandon.
            throw CancellationError()
        } catch {
            // Une attente interrompue peut finir sur une autre erreur que
            // l'annulation — un appel au pont coupé, une copie jamais venue.
            // Ce n'est pas un échec de la transformation : le brut ne se
            // rend pas plus ici qu'ailleurs.
            if Task.isCancelled { throw CancellationError() }
            Log.error("relais : \(module.identifiant) a échoué (\(error.localizedDescription)) "
                      + "— transcription brute conservée")
            // Le brut est rendu, mais pas en silence : il s'insère là où l'on
            // attendait un texte remanié, et rien ne distinguait l'un de
            // l'autre. Un quota atteint surtout doit se lire — sans quoi on
            // relance, et le même refus revient. L'échéance passée aussi :
            // « n'a pas abouti » ne dit pas qu'on a attendu trois minutes.
            switch error as? RelaisPage.Erreur {
            case .refusParChatGPT?, .attenteEpuisee?:
                avertissement = (error as? RelaisPage.Erreur)?.raisonCourte
            default:
                avertissement = "\(module.nom) n'a pas abouti"
            }
            return brut
        }
    }

    /// La fin d'une dictée ChatGPT, quelle qu'en soit l'issue — réussite,
    /// texte vide, échec : rendre la page, et la laisser prête pour la
    /// suivante.
    ///
    /// C'est **la fin d'une dictée qui prépare la suivante**, jamais l'appui
    /// (cf. `preparerLaProchaine`) : cette méthode est l'endroit où cette
    /// règle se tient. Un seul appel, à la sortie commune de tous les
    /// chemins : le faire à chaque chemin serait la promesse d'en oublier un,
    /// et un oubli condamne la page jusqu'au redémarrage. Une dictée abandonnée
    /// ne passe pas par ici — l'abandon fait le même travail à sa place (cf.
    /// `interrompre`).
    ///
    /// `module` est celui de la dictée, figé à l'arrêt de l'écoute.
    /// `texteLaisseDansLaPage` : l'échec a laissé la transcription dans la
    /// fenêtre, ouverte pour qu'on l'y récupère.
    func apresLivraison(_ module: RelaisModule, texteLaisseDansLaPage: Bool) {
        rendreLaMain()
        // La page est rendue prête pour la prochaine, pendant qu'on ne s'en
        // sert pas. Sauf si l'on vient d'y laisser un texte à récupérer : la
        // préparer maintenant le détruirait sous les yeux de qui vient le
        // chercher. Elle attend alors qu'on en ait fini.
        //
        // Avant de quitter la discussion, et non après : c'est ce report qui
        // dit à la sortie de la discussion de laisser la fenêtre ouverte sur
        // le texte.
        preparerLaProchaine(apresEchec: texteLaisseDansLaPage)
        // Délivrer ailleurs, c'est quitter la discussion.
        //
        // Basculer de « Discuter » vers un module qui écrit au curseur referme
        // la fenêtre : l'état devait suivre. Il ne suivait pas, et Caspr
        // poursuivait alors un fil que plus personne ne voyait — la dictée
        // suivante arrivait dans la conversation d'avant.
        if module.sortieParDefaut != .aucune {
            terminerDiscussion()
        }
        // La barre de ChatGPT se range à la fin de la dictée, quelle qu'en
        // soit l'issue.
        //
        // Seules la réussite et un échec sur deux la rangeaient : un texte
        // vide la laissait flotter au-dessus du travail, sans rapport avec le
        // message affiché. Deux exceptions, qui sont ce que la dictée laisse
        // délibérément à l'écran — la discussion qui continue, et la fenêtre
        // ouverte pour qu'on y récupère son texte.
        if !texteLaisseDansLaPage, !enDiscussion {
            masquerBarre()
        }
    }

    /// Pourquoi la dernière transformation a rendu le brut, s'il y a lieu.
    private var avertissement: String?

    /// Rend l'avertissement de la dictée qui s'achève, et l'oublie.
    func prendreAvertissement() -> String? {
        defer { avertissement = nil }
        return avertissement
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

    func ouvrirFenetre() { try? pageActive().montrer() }

    /// La petite fenêtre pendant la dictée, et son retrait après.
    func afficherBarre() { try? pageActive().afficherBarre() }
    func masquerBarre() { page?.cacher() }

    /// Range la barre d'une dictée qui s'achève, sauf si la grande fenêtre est
    /// ouverte.
    ///
    /// La grande fenêtre ne s'ouvre à la fin d'une dictée que pour qu'on y
    /// fasse quelque chose : se connecter, récupérer un texte, poursuivre une
    /// discussion. La ranger avec la barre défaisait ce qu'on venait de
    /// montrer.
    func rangerLaBarre() {
        guard let page, !page.estVisible else { return }
        page.cacher()
    }

    /// Tout arrêter proprement, dans l'ordre — puis préparer la suivante.
    ///
    /// La barre se referme **après** l'arrêt et non avant : rangée hors champ,
    /// la page est suspendue par le système, et le clic sur le bouton d'arrêt
    /// n'aboutirait pas. ChatGPT continuerait d'écouter, invisible.
    ///
    /// L'arrêt passe par la préparation, et c'est ce qui le rend sûr contre un
    /// appui immédiat. Détaché, il courait en même temps que la dictée
    /// suivante : le clic sur l'arrêt pouvait couper l'écoute qui venait de
    /// s'ouvrir, et la barre se rangeait sous elle. Devenu une préparation,
    /// l'appui suivant l'attend (cf. `attendreLaPreparation`), comme il attend
    /// n'importe quelle page qu'on remet d'aplomb. Et la page abandonnée est
    /// remise prête — une réorganisation interrompue après l'envoi laisse une
    /// conversation, que la suivante ne doit pas reprendre.
    ///
    /// `quitterLaDiscussion` : la dictée abandonnée devait écrire ailleurs, ce
    /// qui fermait la discussion à la fin de son cycle — l'abandon la ferme à
    /// sa place. Sans quoi la préparation, qui ne touche pas au fil d'une
    /// discussion, laissait la page telle quelle, et la dictée suivante
    /// partait dans l'ancienne conversation, message abandonné compris. Pas
    /// par `terminerDiscussion` : il range la page tout de suite, avant que
    /// l'arrêt n'ait cliqué — ChatGPT aurait continué d'écouter hors champ —
    /// puis lance une préparation que celle-ci remplacerait, arrêt compris.
    func interrompre(quitterLaDiscussion: Bool = false) {
        let rendreLePremierPlan = quitterLaDiscussion && enDiscussion
        if quitterLaDiscussion { enDiscussion = false }
        lancerPreparation { [weak self] page in
            await page.annuler()
            await page.rendreLeMicro()
            // Une dictée a pu commencer entre-temps et afficher sa barre : ce
            // n'est plus à nous de la ranger.
            guard let self else { return }
            if occupation == .libre {
                page.cacher()
                // Comme à la sortie d'une discussion : sa grande fenêtre a pu
                // activer Caspr, et la dictée suivante écrirait chez lui.
                if rendreLePremierPlan { NSApp.hide(nil) }
            }
            await preparer(page)
        }
    }

    /// Apprendre les boutons de la page sans les faire montrer : Caspr les
    /// essaie lui-même, sous les yeux de l'utilisateur, et ne retient que
    /// ceux dont il a vu l'effet (cf. `RelaisCalibrationAuto`).
    ///
    /// Trois limites, qui sont chacune une décision :
    ///
    /// - **La connexion n'est jamais automatisée.** C'est le compte de
    ///   l'utilisateur. Sans session, la fenêtre s'ouvre pour qu'il se
    ///   connecte, et le parcours l'attend — il reprend dès que la page
    ///   montre une conversation.
    /// - **Rien n'est enregistré tant que l'aller-retour entier n'est pas
    ///   prouvé.** Le parcours manuel enregistre repère par repère ; un
    ///   automate qui ferait de même et échouerait à mi-chemin détruirait en
    ///   silence un calibrage qui marchait.
    /// - **Un seul message d'essai, annoncé avant.** Il part réellement dans
    ///   une conversation de l'utilisateur, et compte sur son quota.
    ///
    /// Le parcours manuel reste le repli, proposé dans le rapport quand un
    /// repère manque, et toujours à un bouton dans les réglages.
    func calibrerAutomatiquement(_ termine: (() -> Void)? = nil) {
        guard !ecouteMacOS else {
            Self.alerter("Pas maintenant",
                         "Une dictée macOS est en cours. Terminez-la avant de calibrer.")
            termine?()
            return
        }
        guard occupation == .libre else {
            Self.alerter("Pas maintenant",
                         (occupation.raison ?? "") + " Terminez-la avant de calibrer.")
            termine?()
            return
        }
        guard let page = try? pageActive() else {
            termine?()
            return
        }
        // Le parcours recharge la page : un fil de discussion ou une
        // préparation en cours n'y survivraient pas, et le croire encore
        // ouvert ferait poursuivre une conversation disparue.
        oublierCeQuiVitSurLaPage()
        occupation = .calibration
        calibrationAutomatique = true
        numeroCalibration &+= 1
        let numero = numeroCalibration
        page.montrer()
        calibration = Task {
            let aLaMain = await menerLaCalibrationAutomatique(page)
            // Abandonnée entre-temps : l'abandon a déjà rendu la main, et ce
            // qui a commencé depuis n'est pas à nous.
            guard numeroCalibration == numero, occupation == .calibration else {
                termine?()
                return
            }
            calibration = nil
            calibrationAutomatique = false
            occupation = .libre
            if aLaMain { calibrerTout(termine) } else { termine?() }
        }
    }

    /// Le parcours automatique, de la connexion au rapport. Rend vrai quand
    /// l'utilisateur choisit de finir à la main.
    private func menerLaCalibrationAutomatique(_ page: RelaisPage) async -> Bool {
        // Trente secondes, comme chaque attente de la page dans ce parcours :
        // choisir ChatGPT vient de la construire, et elle se charge encore.
        // Et selon le filet, pas selon le calibrage qu'on vient peut-être
        // remplacer parce qu'il est faux (cf. `connexionObservee`).
        switch await page.connexionObservee(secondes: 30) {
        case .connecte:
            break
        case .inconnu:
            guard !Task.isCancelled else { return false }
            // Ni connectée ni déconnectée : demander un mot de passe ferait
            // chercher au mauvais endroit.
            page.charger()
            Self.alerter("La page ChatGPT ne répond pas", """
                Elle ne s'est pas chargée en trente secondes : Caspr ne peut pas savoir \
                si vous êtes connecté. Elle vient d'être rechargée, dans la fenêtre \
                ouverte derrière ce message.

                Vérifiez votre connexion à Internet. Une fois la conversation affichée, \
                relancez « Calibrer automatiquement » dans Réglages › Voie.
                """)
            return false
        case .deconnecte:
            guard !Task.isCancelled else { return false }
            Self.alerter("D'abord, se connecter à ChatGPT", """
                La fenêtre ChatGPT est ouverte derrière ce message. Connectez-vous : \
                c'est votre compte, et Caspr ne se connecte jamais à votre place.

                À savoir : « Continuer avec Google » ne fonctionne pas ici. Google refuse \
                volontairement ses connexions dans une fenêtre embarquée. Une adresse \
                e-mail et un mot de passe fonctionnent.

                La calibration reprendra d'elle-même dès que la conversation \
                s'affichera. Fermer la fenêtre l'arrête.
                """)
            // Attendre la connexion plutôt que s'arrêter : c'est le parcours
            // de qui choisit ChatGPT pour la première fois, à l'accueil comme
            // dans les réglages, et le renvoyer chercher un bouton une fois
            // connecté lui faisait croire le travail fini.
            guard await attendreLaSession(page) else { return false }
        }
        guard !Task.isCancelled, Self.demander("Calibrer automatiquement", """
            Caspr va apprendre seul les boutons de la page, en les essayant sous vos \
            yeux, dans une conversation neuve :

            • le micro de la page s'ouvre une seconde, puis s'arrête — ce qu'il \
            entend est effacé ;
            • un message d'essai part réellement, un seul : « \(RelaisPage.essai) » ;
            • le bouton « copier » de la réponse est essayé, et votre presse-papiers \
            vous est rendu tel quel.

            Rien n'est enregistré tant que tout n'a pas marché : votre calibrage \
            actuel ne peut pas être abîmé. Comptez une demi-minute ; fermer la \
            fenêtre arrête tout.
            """)
        else {
            page.cacher()
            NSApp.hide(nil)
            return false
        }

        let ancien = RelaisSelecteurs.charger()
        let issue: RelaisCalibrationAuto.Issue
        do {
            issue = try await RelaisCalibrationAuto(page: page, ancien: ancien).mener()
        } catch {
            // Abandonné : l'abandon remet la page d'aplomb (cf.
            // `abandonnerCalibration`).
            return false
        }
        await page.rendreLeMicro()
        // Fermer la fenêtre arrête tout, comme l'annonce l'a promis — y
        // compris l'écriture d'un parcours qui venait d'aboutir.
        guard !Task.isCancelled else { return false }

        guard let nouveau = issue.preuves.calibrage(remplacant: ancien) else {
            Log.error("relais : calibration automatique incomplète — manquent "
                      + issue.preuves.manquants.map(\.rawValue).joined(separator: ", "))
            page.charger()
            let rapport = Self.rapport(issue, ancien: ancien, enregistre: false)
            let aLaMain = Self.choisir("Calibration automatique inachevée", rapport,
                                       ["Montrer les boutons à la main…", "Fermer"]) == 0
            if !aLaMain {
                page.cacher()
                NSApp.hide(nil)
            }
            return aLaMain
        }
        // La seule écriture du parcours automatique, une fois l'aller-retour
        // entier prouvé.
        page.selecteurs = nouveau
        nouveau.enregistrer()
        Log.info("relais : calibration automatique enregistrée — "
                 + RelaisPreuves.parcours.map { "\($0.rawValue) \(nouveau[$0])" }
                    .joined(separator: ", "))

        // La réponse au message d'essai est encore à l'écran : c'est le
        // moment de montrer « Lire à haute voix », s'il sert. Deux clics au
        // plus, et le seul que l'automate ne fera pas.
        let rapport = Self.rapport(issue, ancien: ancien, enregistre: true)
        if Self.choisir("C'est appris", rapport,
                        ["Terminé", "Montrer « Lire à haute voix »…"]) == 1,
           Self.demander("Lire à haute voix", """
               Cliquez « Lire à haute voix » sous la réponse — le petit haut-parleur.

               S'il n'apparaît pas directement, ouvrez d'abord le menu « … » : Caspr \
               retient le chemin complet et le refera pour vous.
               """) {
            do { try await page.calibrerLecture() }
            catch is CancellationError { return false }
            catch { Self.alerter("Relais", error.localizedDescription) }
        }
        page.charger()
        page.cacher()
        NSApp.hide(nil)
        return false
    }

    /// Attend qu'on se connecte, jugé comme le parcours automatique juge la
    /// session : par le filet, pas par un calibrage peut-être faux (cf.
    /// `connexionObservee`).
    ///
    /// Dix minutes, comme le parcours manuel (`attendreConnexion`) : le temps
    /// de retrouver un mot de passe, ou de créer un compte. Fermer la fenêtre
    /// annule la calibration, et l'attente avec elle.
    private func attendreLaSession(_ page: RelaisPage) async -> Bool {
        let limite = Date.now.addingTimeInterval(600)
        while Date.now < limite {
            try? await Task.sleep(for: .seconds(1))
            guard voieChatGPT, !Task.isCancelled else { return false }
            if await page.connexionObservee(secondes: 2) == .connecte { return true }
        }
        return false
    }

    /// Ce que le parcours a trouvé et ce qui lui manque, repère par repère.
    private static func rapport(_ issue: RelaisCalibrationAuto.Issue,
                                ancien: RelaisSelecteurs, enregistre: Bool) -> String {
        func nom(_ cible: RelaisCible) -> String {
            switch cible {
            case .composeur: "la zone de texte"
            case .micro: "le micro"
            case .stop: "l'arrêt"
            case .envoi: "l'envoi"
            case .copier: "« copier » sous la réponse"
            case .reponse: "la réponse"
            case .lecture: "« Lire à haute voix »"
            }
        }
        var lignes = RelaisPreuves.parcours.map { cible -> String in
            if issue.preuves.selecteurs[cible] != nil { return "✓ \(nom(cible))" }
            let raison = issue.preuves.raisons[cible]
                ?? "pas essayé : une étape précédente a échoué"
            return "✗ \(nom(cible)) — \(raison)"
        }
        lignes.append(ancien.saitLire && enregistre
            ? "✓ « Lire à haute voix » — gardé tel que vous l'aviez montré"
            : "– « Lire à haute voix » — facultatif, à montrer à la main")
        lignes.append("")
        lignes.append(issue.messageEnvoye
            ? "Un message d'essai est parti dans une conversation neuve."
            : "Aucun message n'a été envoyé.")
        if !enregistre {
            lignes.append(ancien.estCalibre
                ? "Rien n'a été enregistré : votre calibrage précédent est intact."
                : "Rien n'a été enregistré.")
            lignes.append("")
            lignes.append("Vous pouvez montrer les boutons à la main : c'est le même "
                          + "apprentissage, clic par clic.")
        }
        return lignes.joined(separator: "\n")
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
        guard !ecouteMacOS else {
            Self.alerter("Pas maintenant",
                         "Une dictée macOS est en cours. Terminez-la avant de calibrer.")
            termine?()
            return
        }
        guard occupation == .libre else {
            Self.alerter("Pas maintenant",
                         (occupation.raison ?? "") + " Terminez-la avant de calibrer.")
            termine?()
            return
        }
        guard let page = try? pageActive() else {
            termine?()
            return
        }
        occupation = .calibration
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
        // Dix minutes d'horloge, et non six cents tours : un tour dont l'appel
        // attend son délai en dure six.
        let limite = Date.now.addingTimeInterval(600)
        while Date.now < limite {
            try? await Task.sleep(for: .seconds(1))
            guard voieChatGPT, !Task.isCancelled else { return false }
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

    /// Une question à plusieurs issues ; rend le rang du bouton choisi.
    private static func choisir(_ titre: String, _ texte: String,
                                _ boutons: [String]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = titre
        a.informativeText = texte
        for bouton in boutons { a.addButton(withTitle: bouton) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Ce que le relais voit de la page, en clair.
    ///
    /// Quand un clic ne prend pas, la seule question utile est « sur quoi
    /// as-tu cliqué ? ». Sans cet écran, il n'y a aucun moyen de distinguer un
    /// sélecteur devenu caduc d'un bouton qui refuse de répondre, et le seul
    /// recours est de tout recalibrer en espérant.
    func diagnostic() {
        guard let page = try? pageActive() else { return }
        let sel = RelaisSelecteurs.charger()
        Task {
            let connexion = await page.etatConnexion(patience: 2)
            let ecoute = await page.estEnEnregistrement()
            let micro = page.microOuvert
            func ligne(_ nom: String, _ valeur: String) -> String {
                valeur.isEmpty ? "\(nom) : (non calibré — heuristique)" : "\(nom) : \(valeur)"
            }
            Self.alerter("Diagnostic du relais", """
                Session : \(connexion == .connecte ? "connectée"
                            : connexion == .inconnu ? "la page ne répond pas" : "pas connectée")
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
