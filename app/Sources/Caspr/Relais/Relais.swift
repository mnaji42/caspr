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
    ///   fin du cycle qui la détruit alors (cf. `finirLeCycle`) — ou, si elle
    ///   y a laissé un texte à récupérer, la fermeture de la fenêtre ou la
    ///   dictée macOS suivante (cf. `libererLaPageGardee`).
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
    func macOSPrendLeMicro() { ecouteMacOS = true }

    /// Détruit, avant que le magnétophone n'écoute, la page que plus rien ne
    /// réclame.
    ///
    /// Celle qu'un échec a gardée sur la voie macOS pour qu'on y récupère son
    /// texte (cf. `finirLeCycle`) : vivante, elle tient le micro, et la dictée
    /// macOS n'enregistrerait que du silence. Rappuyer, c'est dire qu'on en a
    /// fini avec ce texte, comme sur la voie ChatGPT (cf.
    /// `attendreLaPreparation`).
    ///
    /// Sa fenêtre a pris le clavier et activé Caspr (cf. `ouvrirFenetre`) ;
    /// rappuyer sans avoir cliqué ailleurs est un chemin prévu. La détruire
    /// sans rendre le premier plan laissait Caspr devant sans fenêtre, et la
    /// voie macOS, qui ne rend pas le clavier avant d'écrire, insérait la
    /// dictée chez lui. Jugé avant de détruire, tant que la fenêtre clé dit
    /// d'où l'on vient ; l'appelant relit ensuite l'application devant, qui
    /// est celle où l'on veut le texte.
    func libererLaPageGardee() async {
        guard occupation == .libre, !pageVoulue else { return }
        let rendreLePremierPlan = premierPlanTenuParLeRelais
        await libererPage()
        guard rendreLePremierPlan else { return }
        await seRetirer()
    }

    /// Le magnétophone est arrêté, quelle qu'en soit l'issue : la page que la
    /// voie réclame peut naître.
    func macOSRendLeMicro() {
        guard ecouteMacOS else { return }
        ecouteMacOS = false
        // Rien sur la voie macOS : elle ne veut pas de page, et ce n'est pas
        // l'arrêt du magnétophone qui libère celle qu'un échec a gardée (cf.
        // `libererLaPageGardee`).
        if voieChatGPT { suivreLaVoie() }
    }

    /// Détruit la page que la voie macOS ne veut plus.
    private func quitterLaPage() {
        // Une calibration non plus : la destruction ne passe pas par la
        // fermeture de la fenêtre, qui l'aurait arrêtée, et elle continuait
        // sur une vue morte — chatgpt.com rechargé dans le vide, puis une
        // alerte « ne répond pas » ou « inachevée » pour un parcours qu'on
        // venait d'annuler en repassant à macOS.
        abandonnerCalibration()
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

    /// Dérivée de deux faits, chacun écrit par un seul propriétaire — la
    /// calibration l'emporte.
    ///
    /// Elle était prise et rendue à la main, chemin par chemin, et il en
    /// suffisait d'un qui l'oublie : un second appui pendant le démarrage la
    /// rendait pour un cycle qui n'était pas le sien, et toute dictée ChatGPT
    /// échouait ensuite sur « Une dictée est en cours » jusqu'au redémarrage
    /// (60d7f38). Une dictée qui a la page, c'est une phase en cours (cf.
    /// `VoieChatGPT.entrer`) ; il n'y a plus rien à rendre.
    ///
    /// Publiée par ses deux faits, pour que l'écran de réglages ne montre
    /// jamais un état périmé : il lisait l'occupation une fois, et « une
    /// dictée est en cours » restait affiché après la fin de la dictée.
    var occupation: Occupation {
        calibrationEnCours ? .calibration : dicteeEnCours ? .dictee : .libre
    }

    /// Ce qui interdit de toucher à la page maintenant, s'il y a quelque
    /// chose : un flux qui la pilote, ou une dictée macOS qui garde le micro
    /// et devant laquelle la page ne doit pas naître (cf. `ecouteMacOS`).
    ///
    /// Une seule réponse pour la carte qui grise ses boutons et pour la
    /// calibration qui refuse de partir : chacune tenait la sienne, et rien
    /// ne les gardait d'accord.
    var empechement: String? {
        occupation.raison ?? (ecouteMacOS ? "Une dictée macOS est en cours." : nil)
    }

    /// Une dictée ChatGPT a la page, de l'appui à la fin de son cycle — écrit
    /// par `VoieChatGPT.entrer`, et par lui seul.
    @Published var dicteeEnCours = false

    /// Une calibration a la page — écrit à son départ et à sa sortie, que
    /// `RelaisCalibration` demande (cf. `prendrePourCalibrer`).
    @Published private(set) var calibrationEnCours = false

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
        guard pageVoulue else { throw RelaisErreur.relaisEteint }
        let neuve = RelaisPage()
        neuve.surFermeture = { [weak self] in self?.fenetreFermee() }
        neuve.surMort = { [weak self] in self?.surPageInterrompue?() }
        neuve.surAffichage = { [weak self] in self?.surAffichageChange?() }
        neuve.surConnexion = { [weak self] in self?.sessionVue = $0 }
        page = neuve
        return neuve
    }

    var estCalibre: Bool { RelaisMagasin.partage.selecteurs.estCalibre }

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
    /// sans session (cf. `RelaisCalibration.obtenirLaSession`). Reste la session perdue
    /// depuis : elle compte dès que la page l'a montrée.
    var saitDicter: Bool { estCalibre && sessionVue != .deconnecte }

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

    // MARK: - La page au repos

    /// Un scénario neuf sur `page`, qui écrit au journal et dit la session vue.
    private func scenario(_ page: RelaisPage) -> RelaisDictee {
        let dictee = RelaisDictee(page: page, pressePapiers: NSPasteboard.general)
        dictee.journal = { $1 ? Log.error($0) : Log.info($0) }
        dictee.surSession = { [weak self] in self?.sessionVue = $0 ? .connecte : .deconnecte }
        return dictee
    }

    /// Ce que fait la page entre deux dictées.
    enum Repos {
        case prete
        /// La page se prépare pour la dictée suivante.
        ///
        /// Retenue pour pouvoir l'attendre : elle tourne au repos, donc elle est
        /// finie depuis longtemps quand on rappuie — mais « longtemps » n'est
        /// pas « toujours », et rappuyer dans la seconde ne doit pas recharger
        /// la page sous une dictée qui commence. Remise à `.prete` par la
        /// tâche elle-même quand elle se termine : c'est ce que l'appui observe.
        case preparation(Task<Void, Never>)
        /// Un échec a laissé son texte dans la page, et la grande fenêtre est
        /// ouverte pour qu'on l'y copie. Préparer tout de suite, c'était vider
        /// ou recharger cette page sous les yeux de qui venait la chercher —
        /// l'inverse de ce que le message d'échec promettait. La préparation
        /// attend donc que l'utilisateur en ait fini : qu'il ferme la fenêtre,
        /// ou qu'il rappuie sur la touche.
        case recuperation

        var estRecuperation: Bool { if case .recuperation = self { true } else { false } }
    }

    private var repos = Repos.prete {
        // La fenêtre de récupération tient le clavier : Échap y revient au
        // système tant qu'elle attend (cf. `discussionAffichee`).
        didSet { if enRecuperation != (oldValue.estRecuperation) { surAffichageChange?() } }
    }
    private var numeroPreparation = 0
    private var enRecuperation: Bool { repos.estRecuperation }

    /// Abandonne la préparation en vol, s'il y en a une ; l'annulation
    /// interrompt aussi un appel au pont resté en suspens.
    private func annulerLaPreparation() {
        if case .preparation(let tache) = repos { tache.cancel() }
    }

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
    /// Et quand la page ne répond plus du tout, on la reconstruit, discussion
    /// comprise : une page muette ne doit pas devenir la panne de la dictée
    /// suivante. **Seulement dans ce cas.** Une zone qui refuse de se vider
    /// sur une page qui répond n'est pas une page à jeter — c'est souvent une
    /// transcription encore en cours, qu'un rechargement détruirait ;
    /// l'ouverture de l'écoute vide de toute façon la zone avant d'écouter.
    ///
    /// Chaque étape est bornée — c'est le repos, où un silence se constate
    /// (cf. `RelaisPage.sonder`) —, parce que l'appui attend cette tâche avant
    /// même d'ouvrir l'écoute : une seule attente sans fin ici, et la barre
    /// « chargeait » indéfiniment, avant que rien n'ait été enregistré.
    func preparerLaProchaine() {
        lancerPreparation { [weak self] in await self?.preparer($0) }
    }

    /// Le travail de `preparerLaProchaine`, à part pour que l'arrêt d'une
    /// dictée abandonnée le fasse aussi (cf. `interrompre`) : l'état de la
    /// page, et ce qu'en décide `RelaisPreparation`.
    ///
    /// `attendu` : un chargement a déjà été attendu, en vain. On ne le
    /// recharge ni ne l'attend plus : la page passe par la question
    /// ordinaire, et muette, elle est reconstruite.
    private func preparer(_ page: RelaisPage, attendu: Bool = false) async {
        guard !Task.isCancelled else { return }
        let etat: RelaisPreparation.Page = !attendu && page.rechargementRetenu ? .morte
            : !attendu && page.chargementEnCours ? .enChargement
            : await page.auRepos().map { .repond(conversation: $0.conversation) } ?? .muette
        guard !Task.isCancelled else { return }
        switch RelaisPreparation.decision(enDiscussion: enDiscussion, page: etat) {
        case .recharger:
            page.charger()
            fallthrough
        case .attendreLeChargement:
            if await !page.attendreComposeurPret(secondes: 30) { await preparer(page, attendu: true) }
        case .garderLeFil:
            return
        case .conversationNeuve:
            page.charger()
            guard await !page.attendreComposeurPret(secondes: 30), !Task.isCancelled else { return }
            // La page vient d'être rechargée : il n'y a rien à y perdre. Un
            // chargement resté en route trente secondes est un fil bloqué,
            // qu'un second rechargement n'aurait pas débloqué.
            Log.error("relais : la page rechargée est restée sans zone de saisie")
            await reconstruireLaPage()
        case .vider:
            // Un vidage refusé par une page qui répond se retente à l'appui ;
            // par une page devenue muette entre-temps, il la laissait figée
            // devant l'appui suivant, sans reconstruction.
            guard await !page.viderComposeur(), !Task.isCancelled,
                  await page.auRepos() == nil, !Task.isCancelled else { return }
            await reconstruireLaPage()
        case .reconstruire:
            await reconstruireLaPage()
        }
    }

    /// Remplace une page muette par une neuve — au repos, depuis la
    /// préparation.
    ///
    /// Recharger ne la réparait pas : sur un fil JavaScript bloqué, `reload()`
    /// et `load()` n'aboutissent jamais (mesuré). Une vue neuve charge en une
    /// fraction de seconde, et le stockage de WebKit lui garde la session.
    ///
    /// Pas par `libererPage` : elle annule la préparation — la tâche même qui
    /// appelle. La discussion, elle, ne survit pas : son fil était sur la page
    /// qu'on jette.
    private func reconstruireLaPage() async {
        guard let ancienne = page else { return }
        Log.error("relais : la page ne répond plus — reconstruite")
        page = nil
        enDiscussion = false
        await ancienne.rendreLeMicro()
        ancienne.detruire()
        surAffichageChange?()
        guard let neuve = try? pageActive() else { return }
        _ = await neuve.attendreComposeurPret(secondes: 30)
    }

    private func lancerPreparation(_ travail: @escaping @MainActor (RelaisPage) async -> Void) {
        // Remplacer la précédente : deux chemins peuvent demander la
        // préparation à quelques millisecondes d'écart — la fin d'une dictée et
        // la sortie d'une discussion — et la seconde doit simplement prendre la
        // place de la première. L'annulation interrompt aussi un appel au pont
        // resté en suspens.
        annulerLaPreparation()
        numeroPreparation &+= 1
        let numero = numeroPreparation
        // Voie macOS : il n'y a plus de page à préparer, et surtout pas une
        // neuve à construire (cf. `pageActive`) — ni celle qu'on s'apprête à
        // détruire, que la fin d'une dictée demanderait sinon de préparer.
        guard pageVoulue, let page = try? pageActive() else {
            repos = .prete
            return
        }
        repos = .preparation(Task { [weak self] in
            await travail(page)
            guard let self, numeroPreparation == numero else { return }
            repos = .prete
        })
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
        if enRecuperation { preparerLaProchaine() }
        _ = try await RelaisHorlogeReelle.systeme.guetter(toutes: .milliseconds(100)) { () -> Void? in
            if case .preparation = repos { nil } else { () }
        }
    }

    /// La grande fenêtre a été fermée par l'utilisateur.
    ///
    /// C'est aussi le moment de faire la préparation remise après un échec :
    /// fermer la fenêtre où l'on venait récupérer son texte, c'est dire qu'on
    /// l'a récupéré.
    private func fenetreFermee() {
        abandonnerCalibration()
        guard enRecuperation, occupation == .libre else { return }
        // Gardée sur la voie macOS pour ce seul texte (cf. `finirLeCycle`) :
        // il n'y a rien à préparer, la page part.
        guard pageVoulue else { quitterLaPage(); return }
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
        guard enDiscussion, !enRecuperation, let page else { return false }
        return page.estVisible || page.barreEnVue
    }

    /// Appelé quand la page meurt pendant que la dictée écoute.
    var surPageInterrompue: (() -> Void)?

    /// La durée du son que la page a capté pour la dictée en cours (cf.
    /// `RelaisEcho`) — il survit à sa mort —, son niveau crête, et ce son,
    /// pris pour le repli.
    var secondesEntendues: Double { page?.echo.secondes ?? 0 }
    var creteEntendue: Float { page?.echo.crete ?? 0 }
    func prendreLeSon() -> [Float] { page?.echo.prendre() ?? [] }
    /// Chaque morceau de ce son, pour l'aperçu en direct ; `nil` le coupe.
    func suivreLeSon(_ morceau: ((ArraySlice<Float>, Double) -> Void)?) { page?.echo.surMorceau = morceau }

    /// La page d'une dictée qui commence, et le scénario qui la pilotera.
    ///
    /// La page a été préparée quand la dictée précédente s'est achevée : il
    /// n'y a rien à décider ici, seulement à s'assurer que ce travail est
    /// fini. Il l'est, sauf si l'on rappuie dans la seconde — `patienter` le
    /// dit alors dans la barre, avec la sortie : cette attente n'a pas de fin
    /// ailleurs que sous la touche de dictée.
    ///
    /// Une page figée au démarrage ne lève rien : l'appui l'attend jusqu'à la
    /// touche, et l'arrêt qui suit la trouve muette — la préparation la
    /// reconstruit alors pour l'appui suivant (cf. `interrompre`).
    func pagePourDictee(patienter: () -> Void) async throws -> RelaisDictee {
        if case .prete = repos {} else { patienter() }
        let avant = page
        try await attendreLaPreparation()
        // La préparation a reconstruit une page muette : la barre que l'appui
        // avait ouverte était celle de l'ancienne, et la neuve, rangée hors
        // champ, verrait ses rendus différés — le bouton d'arrêt avec eux.
        if let avant, page !== avant { afficherBarre(module: RelaisMagasin.partage.retenu) }
        return scenario(try pageActive())
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
        annulerLaPreparation()
        repos = .prete
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
    /// l'écoute, et non celui qu'on relirait maintenant. `pageMorte` : la page
    /// que cette dictée a prise est morte depuis (cf. `RelaisDictee.pageMorte`).
    func entrerEnDiscussion(_ module: RelaisModule, pageMorte: Bool) {
        // Choisir macOS pendant la dictée condamne la page à sa fin : un fil
        // ouvert dessus n'aurait nulle part où continuer.
        guard voieChatGPT else { return }
        // La page est morte pendant la dictée : rechargée, elle porte une
        // conversation vierge, et un fil « ouvert » dessus enverrait la suite
        // sans son contexte, sans que rien le signale.
        guard !pageMorte else {
            enDiscussion = false
            return
        }
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
        guard !enRecuperation else {
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
    ///
    /// La décision porte sur le **premier plan**, pas sur la fenêtre : à
    /// l'arrêt, la barre vient d'être rangée, et une grande fenêtre ouverte à
    /// l'appui a été retirée dès que la dictée a pris un module qui écrit
    /// (cf. `afficherBarre`). Juger sur `estVisible` ne voyait donc plus rien,
    /// alors que Caspr restait devant, sans fenêtre : le texte s'y perdait.
    func rendreLeClavier() async {
        guard premierPlanTenuParLeRelais else { return }
        if page?.estVisible == true { page?.cacher() }
        page?.fenetreCleRetiree = false
        await seRetirer()
    }

    /// Cache Caspr, et attend que le système ait rendu le premier plan.
    private func seRetirer() async {
        NSApp.hide(nil)
        // Insérer avant que le système ait rendu le premier plan viserait
        // encore Caspr : on observe qu'il l'a rendu. Délai de geste : le
        // système rend le premier plan dans l'instant, et une seconde sans
        // effet dit qu'il ne le rendra pas — l'insertion part alors quand même.
        // Un abandon y met fin sur-le-champ, au lieu de tourner à vide une
        // seconde durant sur le fil principal, qui seul peut voir le premier
        // plan changer.
        let nous = NSRunningApplication.current.processIdentifier
        _ = try? await RelaisHorlogeReelle.systeme.guetter(toutes: .milliseconds(20), auPlus: .seconds(1)) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == nous ? nil : ()
        }
    }

    /// Caspr est-il devant du seul fait du relais ?
    ///
    /// Vrai quand la fenêtre clé est l'une des siennes, qu'il n'y en a plus,
    /// ou que la dictée a retiré la grande fenêtre qui l'était — une autre
    /// fenêtre de Caspr en a hérité sans qu'on y soit. Faux devant une autre
    /// fenêtre de Caspr qu'on avait choisie : l'accueil a sa zone d'essai, les
    /// réglages le texte d'un module, et c'est là qu'on dicte.
    private var premierPlanTenuParLeRelais: Bool {
        guard NSApp.isActive else { return false }
        guard let cle = NSApp.keyWindow, page?.fenetreCleRetiree != true else { return true }
        return page?.possede(cle) ?? false
    }

    /// Comment une dictée ChatGPT a fini, pour ce qu'il reste à faire de la
    /// page.
    enum Fin {
        /// Allée au bout — réussite, texte vide ou échec —, avec le module
        /// figé à l'arrêt de l'écoute. `texteLaisse` : l'échec a laissé la
        /// transcription dans la fenêtre, ouverte pour qu'on l'y récupère.
        case livree(RelaisModule, texteLaisse: Bool)
        /// Abandonnée : la page est arrêtée, puis préparée. `ecouteQuiDemarre`
        /// : l'appui a été défait pendant le démarrage, peut-être juste après
        /// le clic du micro (cf. `RelaisDictee.arreterApresAbandon`).
        case abandonnee(quitterLaDiscussion: Bool, ecouteQuiDemarre: Bool)
        /// Le démarrage a échoué sur cette erreur ; `nil` quand la page n'a
        /// pas encore été touchée — une permission refusée.
        case demarrageManque(RelaisErreur?)
    }

    /// LA sortie d'une dictée ChatGPT, quelle qu'en soit l'issue — réussite,
    /// texte vide, échec, abandon, démarrage manqué. La dictée a déjà quitté
    /// sa phase (cf. `VoieChatGPT.entrer`) : l'occupation est libre.
    ///
    /// C'est **la fin d'une dictée qui prépare la suivante**, jamais l'appui
    /// (cf. `preparerLaProchaine`) ; cette méthode est l'endroit où cette
    /// règle se tient. Elle se tenait en cinq endroits — la fin d'une dictée,
    /// l'occupation rendue, l'abandon, l'abandon du démarrage, le démarrage
    /// manqué —, et chacun devait penser à tout : un oubli condamnait la page
    /// jusqu'au redémarrage.
    func finirLeCycle(_ fin: Fin) {
        // Le son de la page n'a plus d'usage : le repli l'a pris, ou la dictée
        // s'est passée de lui. Des minutes de parole en mémoire vive ne
        // doivent pas attendre la dictée suivante pour partir.
        page?.echo.liberer()
        // Le report d'abord (cf. `Repos.recuperation`) : c'est lui qui dit de
        // garder la page quand on a choisi macOS pendant la dictée, et à la
        // sortie de la discussion de laisser la fenêtre ouverte sur le texte.
        if case .livree(_, texteLaisse: true) = fin {
            annulerLaPreparation()
            repos = .recuperation
        }
        // Choisir macOS pendant la dictée condamnait la page à sa fin (cf.
        // `suivreLaVoie`). Sauf si la dictée vient d'y laisser son texte : la
        // détruire effaçait sous les yeux ce que le message d'échec disait
        // récupérable. Elle part alors avec sa fenêtre (cf. `fenetreFermee`),
        // ou à l'appui de la dictée macOS suivante (cf. `libererLaPageGardee`).
        if !pageVoulue, page != nil, !enRecuperation {
            quitterLaPage()
            return
        }
        switch fin {
        case .livree(let module, let texteLaisse):
            if !texteLaisse { preparerLaProchaine() }
            // Délivrer ailleurs, c'est quitter la discussion. Basculer de
            // « Discuter » vers un module qui écrit referme la fenêtre, et
            // Caspr poursuivait sinon un fil que plus personne ne voyait.
            if module.ecrit { terminerDiscussion() }
            // La barre se range quelle que soit l'issue : un texte vide la
            // laissait flotter au-dessus du travail. Sauf ce que la dictée
            // laisse délibérément à l'écran — la discussion qui continue, la
            // fenêtre ouverte sur le texte à récupérer.
            if !texteLaisse, !enDiscussion { masquerBarre() }
        case .abandonnee(let quitter, let ecouteQuiDemarre):
            // Encore dans l'attente de la préparation, rien n'a été cliqué.
            // Arrêter abandonnait le rechargement en cours pour en recommencer
            // un : jusqu'à quarante secondes de plus au prochain appui, et
            // autant à chaque renoncement. On range ce que l'appui a ouvert ;
            // la préparation continue.
            if ecouteQuiDemarre, case .preparation = repos {
                if let page { ranger(page) }
                return
            }
            interrompre(quitterLaDiscussion: quitter, ecouteQuiDemarre: ecouteQuiDemarre)
        case .demarrageManque(let erreur):
            guard let page, let erreur else { return }
            switch erreur {
            // La page a montré l'écran de connexion : la grande fenêtre
            // s'ouvre pour qu'on s'y connecte.
            case .pasConnecte: page.montrer()
            // Le micro a été cliqué sans qu'elle écoute : elle peut encore s'y
            // mettre, hors champ. Elle est arrêtée comme après un appui
            // abandonné juste après ce clic, et c'est l'arrêt qui la range —
            // rangée avant, elle serait suspendue, et l'arrêt n'aboutirait pas.
            case .ecouteNonOuverte: interrompre(ecouteQuiDemarre: true)
            // Toute autre grande fenêtre a été ouverte par l'appui lui-même :
            // épargnée parce que visible, elle restait devant avec le clavier,
            // et les frappes suivantes partaient dans ChatGPT. Sauf celle
            // d'une discussion en cours.
            //
            // Rien n'écoute — le micro n'a pas été cliqué —, mais WebKit peut
            // tenir le sien depuis la dictée d'avant : il est rendu, et la
            // page préparée, comme à toute fin (15, 67) ; dans la
            // préparation, que l'appui suivant attend avant son clic. Une
            // page sans pont y est reconstruite au lieu d'attendre l'appui.
            default:
                if !(enDiscussion && page.estVisible) { ranger(page) }
                lancerPreparation { [weak self] page in
                    await page.rendreLeMicro()
                    await self?.preparer(page)
                }
            }
        }
    }

    /// Adopte la page ouverte dans la fenêtre comme point de départ.
    ///
    /// On lit l'adresse plutôt que de la faire saisir : personne ne recopie à
    /// la main l'URL d'un projet ChatGPT sans se tromper, et elle est sous les
    /// yeux de qui vient d'y naviguer.
    func adopterPageDeDepart() {
        guard let url = page?.adresseCourante, RelaisMagasin.partage.adopter(url) else {
            RelaisDialogues.alerter("Point de départ",
                         "Ouvrez d'abord la fenêtre du relais et allez sur la page "
                         + "ChatGPT que vous voulez utiliser — un projet dédié, par "
                         + "exemple.")
            return
        }
        RelaisDialogues.alerter("Point de départ enregistré", """
            Les conversations créées par Caspr partiront désormais de cette page :

            \(url.absoluteString)

            Une dictée « Réorganiser » ouvre une conversation neuve à chaque fois — \
            sans quoi la note précédente orienterait la suivante. Les regrouper dans un \
            projet dédié évite qu'elles se mêlent à vos vraies conversations.
            """)
    }

    func oublierPageDeDepart() {
        RelaisMagasin.partage.revenirALAccueil()
        RelaisDialogues.alerter("Point de départ",
                     "Retour à la page d'accueil de ChatGPT.")
    }

    // MARK: - Réglages

    func ouvrirFenetre() { try? pageActive().montrer() }

    /// La petite fenêtre pendant la dictée, selon ce que demande `module` —
    /// celui du moment pendant l'écoute —, et son retrait après.
    func afficherBarre(module: RelaisModule) { try? pageActive().afficherBarre(module: module) }
    func masquerBarre() { page?.cacher() }

    /// Range la page, et rend le premier plan si c'est elle qui le tenait.
    ///
    /// La grande fenêtre a pu activer Caspr — une discussion, une
    /// reconnexion, un module qui s'affiche en page. La ranger sans rendre le
    /// premier plan le laissait devant sans fenêtre : les frappes suivantes
    /// s'y perdaient, et la dictée d'après écrivait chez lui. Jugé avant de
    /// ranger, tant que la fenêtre clé dit d'où l'on vient.
    private func ranger(_ page: RelaisPage) {
        let rendreLePremierPlan = premierPlanTenuParLeRelais
        page.cacher()
        guard rendreLePremierPlan else { return }
        page.fenetreCleRetiree = false
        NSApp.hide(nil)
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
    ///
    /// `ecouteQuiDemarre` : cf. `Fin.abandonnee`.
    private func interrompre(quitterLaDiscussion: Bool = false, ecouteQuiDemarre: Bool = false) {
        if quitterLaDiscussion { enDiscussion = false }
        lancerPreparation { [weak self] page in
            // Borné, comme tout ce qui se fait au repos : un relevé, puis trois
            // secondes pour que la page se mette à écouter, cinq pour son
            // arrêt, et de quoi vider (cf. `RelaisDictee.arreterApresAbandon`).
            // Tenant le micro, elle est à arrêter quoi qu'elle réponde : on ne
            // lui demande rien.
            let vu = page.microOuvert ? nil : await page.auRepos()
            _ = await page.sonder(auPlus: .seconds(10)) {
                await self?.scenario(page).arreterApresAbandon(auRepos: vu, ecouteQuiDemarre: ecouteQuiDemarre)
            }
            await page.rendreLeMicro()
            // Une dictée a pu commencer entre-temps et afficher sa barre : ce
            // n'est plus à nous de la ranger.
            guard let self else { return }
            if occupation == .libre { ranger(page) }
            await preparer(page)
        }
    }

    // MARK: - La calibration (cf. `RelaisCalibration`)

    private lazy var calibration = RelaisCalibration(relais: self)

    /// Apprendre les boutons de la page sans les faire montrer : Caspr les
    /// essaie lui-même, et ne retient que ceux dont il a vu l'effet.
    func calibrerAutomatiquement() { calibration.lancer(.automatique) }

    /// Les faire montrer, clic par clic : le repli d'une page que l'automate
    /// ne sait pas lire.
    func calibrerALaMain() { calibration.lancer(.manuel) }

    /// Met fin à la calibration, d'où qu'on le demande.
    func abandonnerCalibration() { calibration.abandonner() }

    /// La page, prise pour une calibration ; `nil` quand ce n'est pas le
    /// moment, dit à l'utilisateur.
    ///
    /// L'une des deux portes par lesquelles le parcours touche au relais (cf.
    /// `RelaisCalibration`) : ce que la page doit au départ et à la sortie
    /// d'une calibration reste ici, à côté de ce qu'il protège —
    /// l'occupation, la préparation, le premier plan —, qui reste privé.
    ///
    /// Une dictée macOS n'occupe pas la page, elle interdit qu'elle naisse :
    /// le magnétophone n'entendrait plus que du silence. Le parcours recharge
    /// la page : un fil de discussion ou une préparation en vol n'y
    /// survivraient pas, et la préparation pouvait même la recharger sous la
    /// main qui désigne le micro.
    func prendrePourCalibrer() -> RelaisPage? {
        if let refus = empechement {
            RelaisDialogues.alerter("Pas maintenant", refus + " Terminez-la avant de calibrer.")
            return nil
        }
        // Sur la voie macOS, sans rien dire : aucun bouton n'y mène — les
        // réglages du relais n'existent que sous ChatGPT, et le choisir
        // change la voie avant de calibrer.
        guard let page = try? pageActive() else { return nil }
        oublierCeQuiVitSurLaPage()
        calibrationEnCours = true
        return page
    }

    /// La sortie d'une calibration, quelle qu'en soit l'issue : l'occupation
    /// rendue, la page rangée, puis la préparation d'une dictée, après avoir
    /// remis la page d'aplomb. Rangée toujours, « ne répond pas » compris :
    /// laissée à l'écran, la préparation qui suit pouvait la reconstruire
    /// sous les yeux, et l'alerte renvoyait à une page qui n'était plus là.
    ///
    /// Le guetteur de clic est retiré d'abord : resté sur la page, il
    /// retiendrait le prochain clic de l'utilisateur, n'importe où dans
    /// ChatGPT. Puis le micro est rendu, et une page laissée à l'écoute — le
    /// micro montré à la main, puis l'abandon ; l'automate interrompu entre
    /// son micro et son arrêt — est rechargée : vider sa zone n'arrêterait
    /// rien. Dans la préparation et non à part : c'est elle que l'appui
    /// suivant attend avant de cliquer le micro.
    func rendreApresCalibration(_ page: RelaisPage) {
        calibrationEnCours = false
        ranger(page)
        lancerPreparation { [weak self] page in
            await page.abandonnerCalibration()
            let ecoute = page.microOuvert
            await page.rendreLeMicro()
            guard !Task.isCancelled else { return }
            if ecoute { page.charger() }
            await self?.preparer(page)
        }
    }

    /// Ce que le relais voit de la page, en clair (cf. `RelaisDialogues`).
    func diagnostic() {
        guard let page = try? pageActive() else { return }
        Task { await RelaisDialogues.diagnostic(page) }
    }
}
