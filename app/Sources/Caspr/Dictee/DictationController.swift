import AppKit
import CasprCore

/// Enchaînement raccourci → écoute → transcription → livraison.
///
/// Deux chemins, un par voie, qui se rejoignent à la livraison. Ils ne se
/// ressemblent qu'en apparence : la voie macOS enregistre, transcrit en une
/// seconde et garde l'audio pour « Réessayer » ; la voie ChatGPT laisse la page
/// écouter, attend des minutes, peut ne rien écrire du tout, et laisse son
/// texte dans la page quand elle échoue. Les écrire comme un seul chemin
/// obligeait l'une à mentir — un enregistrement vide, des latences
/// inventées — pour se conformer au contrat de l'autre.
///
/// Un seul cycle à la fois : réappuyer pendant le traitement ne met rien en
/// file, sinon deux transcriptions se disputeraient le curseur.
@MainActor
final class DictationController {
    enum State: Equatable {
        case idle
        /// L'appui est reçu, l'écoute n'est pas encore ouverte.
        ///
        /// Posé **avant** le premier `await`, et c'est toute sa raison d'être.
        /// Sous ChatGPT, ouvrir l'écoute attend la page — de une à plusieurs
        /// dizaines de secondes quand elle se prépare —, et l'état restait
        /// jusque-là au repos : un second appui s'y croyait le premier, se
        /// faisait refuser la page, et remettait à faux le drapeau du relais
        /// d'un cycle qui n'était pas le sien. Ce cycle-là finissait sans
        /// jamais rendre la page, et toute dictée ChatGPT échouait ensuite sur
        /// « Une dictée est en cours » jusqu'au redémarrage.
        case starting
        case recording
        case processing
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            if state != oldValue { onStateChange?(state) }
            ajusterEchap()
        }
    }

    var onStateChange: ((State) -> Void)?

    /// La langue est **lue** dans les préférences, jamais recopiée.
    ///
    /// Elle l'a été, et c'était un bug : le contrôleur gardait des copies
    /// rafraîchies à la fermeture de la fenêtre de réglages. Choisir l'anglais
    /// puis dicter sans fermer la fenêtre transcrivait de l'anglais avec le
    /// modèle français — panne parfaitement muette, puisque le moteur rend
    /// simplement un texte vide ou absurde. Toute copie d'un réglage est une
    /// occasion de divergence ; il n'y en a plus.
    var language: String { Preferences.shared.primaryLanguage }

    /// Destination du texte : curseur actif, ou fichier de notes.
    ///
    /// Figée à l'arrêt de l'écoute (cf. `DicteeEnCours`), jamais au
    /// démarrage : basculer en pleine phrase redirige donc la dictée en cours,
    /// dans les deux sens. C'est le comportement attendu — on se rend compte
    /// en parlant que ça ne doit pas aller là.
    ///
    /// **Lue** dans les préférences, jamais recopiée — la même règle que la
    /// langue juste au-dessus, et pour la même raison.
    /// Elle était un état local remis au curseur à chaque lancement, ce qui
    /// obligeait qui travaille au fichier de notes à y revenir tous les matins.
    var target: DictationTarget { Preferences.shared.effectiveTarget }

    private let injector = TextInjector()
    private let overlay = RecordingOverlay()
    /// La queue commune aux deux voies : insertion, historique, recours.
    private let livraison: Livraison
    private let macOS: VoieApple
    private let chatgpt: VoieChatGPT
    private lazy var echap = Echap { [weak self] in self?.cancel() }

    var history: TranscriptionHistory { livraison.history }

    init() {
        livraison = Livraison(injector: injector, overlay: overlay)
        macOS = VoieApple(overlay: overlay, livraison: livraison)
        chatgpt = VoieChatGPT(overlay: overlay, livraison: livraison)
        overlay.levelProvider = { [weak self] in self?.macOS.niveau ?? 0 }
        overlay.onCancel = { [weak self] in self?.cancel() }
        // La page peut mourir pendant qu'on parle.
        Relais.partage.surPageInterrompue = { [weak self] in self?.pageRelaisInterrompue() }
        // Échap suit ce que le relais montre (cf. `ajusterEchap`).
        Relais.partage.surAffichageChange = { [weak self] in self?.ajusterEchap() }
        // Le module du relais se choisit sur la barre, au moment de parler.
        overlay.onSelectModule = { [weak self] index in
            guard let self else { return }
            chatgpt.choisirModule(index, enEcoute: state == .recording)
            refreshOverlay()
        }
        overlay.onSelectTarget = { [weak self] wantsNotes in
            guard let self else { return }
            livraison.choisirLesNotes(wantsNotes, selecteurPossible: state != .recording)
            refreshOverlay()
            onStateChange?(state)
        }
        // Changer de langue en pleine phrase est sans danger : l'audio est
        // enregistré et transcrit **à la fin**, avec la langue en vigueur à ce
        // moment-là. C'est donc le texte réellement inséré qui suit la
        // bascule. Seul l'aperçu en direct doit repartir sur le nouveau
        // moteur — son texte ne sert que de recours, et son échec n'a jamais
        // d'effet sur la dictée.
        overlay.onSelectLanguage = { [weak self] code in
            guard let self, Preferences.shared.primaryLanguage != code else { return }
            Preferences.shared.primaryLanguage = code
            if state == .recording, voieDuCycle == .apple {
                macOS.arreterApercu()
                macOS.demarrerApercu(langue: language)
            }
            refreshOverlay()
            onStateChange?(state)
        }
    }

    /// État courant de la barre : celui de la voie de la dictée en cours, et
    /// au repos, de la suivante.
    private var overlayStatus: RecordingOverlay.Status {
        switch voieDuCycle ?? Preferences.shared.voie {
        case .apple: macOS.statutDeLaBarre(peutChoisirLaNote: state != .recording)
        case .chatgpt: chatgpt.statutDeLaBarre(peutChoisirLaNote: state != .recording)
        }
    }

    private func refreshOverlay() {
        overlay.update(overlayStatus)
    }

    // MARK: - Le cycle

    /// La voie du cycle en cours, **figée à l'appui** ; `nil` hors d'un cycle.
    ///
    /// Lue une fois, dans `commencer`, et portée jusqu'à la livraison. La
    /// relire en chemin, c'était laisser une bascule en pleine phrase
    /// arrêter par macOS une écoute que ChatGPT avait ouverte — le geste
    /// d'arrêt n'a pas à redire par où l'on était parti. Basculer vaut donc
    /// pour la dictée suivante, dans les deux sens : le relais garde sa page
    /// jusqu'à la fin d'une dictée ChatGPT, et n'en construit pas pendant une
    /// dictée macOS (cf. `Relais.suivreLaVoie`).
    private var voieDuCycle: VoieDeDictee?

    /// L'application où l'on parlait, capturée à l'appui ; `nil` quand c'était
    /// Caspr lui-même — la zone d'essai de l'accueil.
    ///
    /// L'insertion par accessibilité vise l'élément focalisé **au moment
    /// d'écrire**. Sous macOS, moins d'une seconde sépare la parole de
    /// l'insertion ; sous ChatGPT, de trente secondes à trois minutes, pendant
    /// lesquelles on a toutes les raisons d'aller travailler ailleurs — et la
    /// dictée s'écrivait alors dans la fenêtre où l'on était passé.
    private var applicationVisee: NSRunningApplication?

    /// La dictée qui se transcrit, figée à l'arrêt de l'écoute ; `nil` avant.
    private var dictee: DicteeEnCours?

    /// La fin de la dictée en cours, retenue pour que la touche de dictée ou
    /// la croix de la barre puissent l'interrompre. L'attente d'une
    /// transcription ChatGPT dure des minutes : sans prise dessus, la barre
    /// restait sur « Transcription… » sans autre issue que de quitter
    /// l'application.
    private var fin: Task<Void, Never>?

    /// Le démarrage en cours, retenu pour que la touche l'interrompe.
    ///
    /// Sous ChatGPT, l'appui attend que la page soit prête — jusqu'à quelques
    /// dizaines de secondes quand elle a dû être rechargée. C'est l'état
    /// `.starting` qui dit qu'on y est, et cette tâche qui permet d'en sortir.
    /// Sous macOS, rien n'y répond : seul le dialogue d'autorisation du micro
    /// peut retenir le démarrage, et il se ferme par ses propres boutons.
    private var demarrage: Task<Void, Never>?

    /// Le numéro du cycle en cours.
    ///
    /// Un cycle abandonné finit de se dérouler après coup : ses `defer` et
    /// ses branches d'échec s'exécutent quand sa tâche se rend compte de
    /// l'annulation. Rappuyer aussitôt, c'était donc laisser le cycle mort
    /// rendre la page que le nouveau venait de prendre, recharger la page sous
    /// la dictée qui commençait, poser son état par-dessus le sien. Chaque
    /// effet différé vérifie désormais que le cycle est encore le sien ;
    /// abandonner un cycle, c'est changer ce numéro, et reprendre à son compte
    /// tout ce qu'il aurait dû défaire (cf. `abandonnerLeCycleRelais`).
    private var cycle = 0

    /// Appelé par le raccourci global : démarre ou termine la dictée.
    func toggle() {
        switch state {
        case .idle, .failed:
            commencer()
        case .starting:
            // La touche interrompt l'attente du démarrage, comme celle de la
            // transcription. Le démarrage se défait lui-même (cf.
            // `startRecording`) : c'est lui qui sait où il en était.
            demarrage?.cancel()
        case .recording:
            fin = Task { await finishRecording() }
        case .processing:
            // Sous macOS, ignorer est juste : le traitement dure une seconde,
            // et réappuyer n'est qu'un geste nerveux. Rien ne peut donc
            // interrompre une transcription macOS, et son chemin n'a pas à
            // vérifier que le cycle est encore le sien.
            //
            // Sous ChatGPT, il peut durer des minutes, et il faut une sortie.
            // Échap ne peut pas la fournir — c'est un raccourci global, une
            // pression dans une autre application annulerait sans qu'on l'ait
            // voulu. La touche de dictée, elle, est un geste délibéré et propre
            // à Caspr : personne ne la presse par distraction, et celui qui la
            // presse pendant l'attente veut bien dire qu'il abandonne.
            switch voieDuCycle {
            case .chatgpt?: cancel()
            case .apple?, nil: break
            }
        }
    }

    /// Ouvre un cycle, depuis le repos.
    private func commencer() {
        cycle &+= 1
        // C'est la voie choisie qui décide, pas la touche : les deux
        // s'excluent, et il n'y a qu'un seul déclencheur.
        let voie = Preferences.shared.voie
        switch voie {
        case .apple:
            macOS.prendreLeMicro()
        case .chatgpt:
            if let refus = chatgpt.prendre() {
                state = .failed(refus)
                return
            }
        }
        voieDuCycle = voie
        applicationVisee = Livraison.applicationDevant()
        state = .starting
        demarrage = Task { await startRecording(voie: voie) }
    }

    func cancel() {
        switch state {
        case .starting:
            // La croix de la barre, pendant que la page se prépare.
            demarrage?.cancel()
            return
        case .idle, .failed:
            // Hors dictée, Échap met fin à la discussion ouverte.
            //
            // Après un échec aussi : une dictée ratée en pleine discussion
            // laisse l'état sur `.failed`, et la discussion doit pouvoir se
            // fermer quand même.
            if Relais.partage.enDiscussion {
                Relais.partage.terminerDiscussion()
                Feedback.cancelled()
            }
            return
        case .recording, .processing:
            break
        }
        switch voieDuCycle {
        case .chatgpt?:
            // L'annulation vaut d'abord pendant l'attente de la transcription,
            // qui n'a pas de fin prévisible — c'est même là qu'elle sert le
            // plus. Et dans les deux états, il faut arrêter la page et refermer
            // sa barre : Échap pendant l'écoute rendait la main, mais laissait
            // ChatGPT écouter derrière une barre restée à l'écran.
            //
            // Sauf une fois le message de « Discuter » parti, ou la réponse
            // d'un module qui écrit en main : il n'y a plus rien à abandonner.
            // Ni arrêter la page, ni cacher la barre, ni annuler la tâche —
            // elle a encore à ouvrir la discussion ou à insérer le texte —,
            // seulement cesser d'attendre la lecture à haute voix. Le cycle
            // s'achève alors de lui-même, et il reste le sien (cf.
            // `Relais.seuleLaLectureEnAttente`).
            if state == .processing, chatgpt.seuleLaLectureEnAttente {
                chatgpt.cesserDAttendreLaLecture()
            } else {
                abandonnerLeCycleRelais()
            }
        case .apple?, nil:
            // Une transcription macOS dure une seconde : seule l'écoute
            // s'annule.
            guard state == .recording else { return }
            macOS.annuler()
            overlay.hide()
            Feedback.cancelled()
            voieDuCycle = nil
            state = .idle
        }
    }

    /// Abandonne la dictée ChatGPT en cours, et fait à sa place ce qu'elle ne
    /// fera plus.
    ///
    /// Le cycle cesse d'être le cycle en cours avant tout le reste : ce qui
    /// s'en déroulera encore — l'annulation se constate à la tâche suivante —
    /// ne touchera plus à rien. Ce que la fin du cycle aurait fait de la page
    /// se fait donc ici, une fois (cf. `VoieChatGPT.abandonner`).
    private func abandonnerLeCycleRelais() {
        cycle &+= 1
        fin?.cancel()
        fin = nil
        voieDuCycle = nil
        chatgpt.abandonner(dictee)
        dictee = nil
        overlay.hide()
        Feedback.cancelled()
        state = .idle
    }

    // MARK: - Écouter

    private func startRecording(voie: VoieDeDictee) async {
        // Toute sortie qui n'aboutit pas à l'écoute rend ce que la voie avait
        // pris — le micro, la page —, et quitte `.starting`. Une ligne par
        // chemin de sortie, c'était la promesse d'en oublier un — et il y en
        // avait deux : un micro ou une accessibilité refusés gardaient la page
        // jusqu'au redémarrage.
        //
        // Aucun autre cycle ne peut s'ouvrir d'ici là : l'état reste
        // `.starting` jusqu'à cette sortie, et un appui n'y fait qu'annuler.
        defer {
            demarrage = nil
            if state == .starting { state = .idle }
            if state != .recording {
                voieDuCycle = nil
                switch voie {
                case .apple: macOS.rendreLeMicro()
                case .chatgpt: chatgpt.rendre()
                }
            }
        }
        switch AudioRecorder.microphoneAccess {
        case .granted:
            break
        case .undetermined:
            // L'app vit en arrière-plan : sans activation, le dialogue système
            // s'ouvre derrière les autres fenêtres et passe inaperçu.
            NSApp.activate(ignoringOtherApps: true)
            guard await AudioRecorder.requestPermission() else {
                state = .failed("Accès au micro refusé.")
                return
            }
        case .denied:
            state = .failed("Micro refusé — ouvrir Réglages › Micro depuis le menu de Caspr.")
            Permissions.openMicrophoneSettings()
            return
        }

        guard injector.hasPermission else {
            injector.requestPermission()
            state = .failed("Accessibilité requise — voir le menu de Caspr.")
            return
        }
        do {
            switch voie {
            case .apple:
                try await macOS.demarrer()
                // Une page gardée pour qu'on y récupère un texte tenait
                // Caspr devant à l'appui : l'application visée a été lue nil.
                // Sa destruction vient de rendre le premier plan (cf.
                // `Relais.libererLaPageGardee`), et celle qui revient devant
                // est celle où l'on travaillait. Nil encore, c'est la zone
                // d'essai de l'accueil, qui garde Caspr devant.
                if applicationVisee == nil {
                    applicationVisee = Livraison.applicationDevant()
                }
            case .chatgpt:
                try await chatgpt.demarrer()
            }
            Log.info("enregistrement démarré")
            // Avant d'afficher la barre : elle grise le bouton Notes tant
            // qu'un sélecteur serait impossible, et lit l'état pour le savoir.
            // Échap est pris au passage (cf. `ajusterEchap`).
            state = .recording
            overlay.showRecording(overlayStatus)
            switch voie {
            case .apple: macOS.demarrerApercu(langue: language)
            case .chatgpt: chatgpt.ecouteOuverte()
            }
            Feedback.recordingStarted()
        } catch is CancellationError {
            // Seule l'attente de la page s'interrompt. La page est rendue par
            // le `defer`, avant que l'arrêt ne s'exécute : c'est l'arrêt qui
            // range la barre, et il ne le fait qu'une page libre.
            chatgpt.demarrageInterrompu()
            overlay.hide()
            Feedback.cancelled()
            state = .idle
        } catch {
            switch voie {
            case .apple:
                break
            case .chatgpt:
                chatgpt.demarrageManque(error)
            }
            state = .failed(error.localizedDescription)
        }
    }

    /// WebKit a tué la page ChatGPT pendant qu'on parlait.
    ///
    /// La page est déjà rechargée, et le son qu'elle captait est perdu avec
    /// elle. Continuer d'afficher l'écoute, c'était laisser parler dans le
    /// vide jusqu'à l'appui d'arrêt ; on échoue donc tout de suite, en le
    /// disant. Les autres phases le découvrent seules : l'attente de la
    /// transcription relève la mort à son tour suivant, et le démarrage au
    /// clic suivant.
    private func pageRelaisInterrompue() {
        guard state == .recording else { return }
        // La page d'un cycle macOS n'existe pas : elle ne peut pas y mourir.
        // Une page détruite après un cycle ChatGPT, elle, ne regarde plus
        // personne.
        switch voieDuCycle {
        case .chatgpt?: break
        case .apple?, nil: return
        }
        voieDuCycle = nil
        state = .failed(chatgpt.pageInterrompue())
    }

    private func finishRecording() async {
        // Abandonnée entre l'appui et l'exécution de cette tâche : il n'y a
        // plus d'écoute à arrêter.
        guard state == .recording, let voie = voieDuCycle else { return }
        switch voie {
        case .apple: await finirParMacOS()
        case .chatgpt: await finirParChatGPT()
        }
    }

    /// Ce qui est dit à l'arrêt : le module et la destination du moment.
    private func figer(_ voie: VoieDeDictee, module: RelaisModule?,
                       duree: TimeInterval) -> DicteeEnCours {
        let figee = DicteeEnCours(cycle: cycle, voie: voie, module: module,
                                  destination: target,
                                  applicationVisee: applicationVisee,
                                  duree: duree)
        dictee = figee
        return figee
    }

    // MARK: - La voie macOS

    private func finirParMacOS() async {
        let samples = macOS.arreter()
        Feedback.recordingStopped()
        overlay.showProcessing()
        // Un appui-relâché trop bref ne contient rien d'exploitable ; inutile
        // de réveiller le moteur. Un vrai VAD reste à faire (cf. README).
        guard samples.count > Int(AudioRecorder.targetSampleRate * 0.3) else {
            Log.info("trop court, ignoré")
            overlay.hide()
            voieDuCycle = nil
            state = .idle
            return
        }
        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        await transcrireParMacOS(samples, figer(.apple, module: nil, duree: seconds))
    }

    /// `apercuConserve` : cf. `VoieApple.transcrireEtLivrer`.
    private func transcrireParMacOS(_ samples: [Float], _ dictee: DicteeEnCours,
                                    apercuConserve: String? = nil) async {
        state = .processing
        // Le micro est déjà rendu, à l'arrêt du magnétophone.
        let echec = await macOS.transcrireEtLivrer(samples, dictee, langue: language,
                                                   apercuConserve: apercuConserve)
        state = echec.map { .failed($0) } ?? .idle
        voieDuCycle = nil
        self.dictee = nil
    }

    // MARK: - La voie ChatGPT

    private func finirParChatGPT() async {
        // Échap est rendu pendant l'attente, et c'est délibéré. Elle peut
        // durer des minutes, il faut pouvoir en sortir ; mais Échap est un
        // raccourci **global** : il répond quelle que soit l'application au
        // premier plan. Le garder armé une minute pendant que quelqu'un
        // travaille ailleurs, c'est faire d'une touche parmi les plus pressées
        // du clavier une annulation silencieuse. Mesuré : deux
        // réorganisations annulées coup sur coup, sans que personne n'ait
        // voulu annuler quoi que ce soit. La sortie reste la touche de dictée,
        // et la croix de la barre (cf. `ajusterEchap`).
        Feedback.recordingStopped()
        let module = RelaisCatalogue.courant
        let dictee = figer(.chatgpt, module: module, duree: chatgpt.secondesEcoutees)
        state = .processing
        let issue = await chatgpt.terminer(dictee, module: module,
                                           estEnCours: { dictee.cycle == cycle })
        // Seulement pour le cycle en cours : un cycle abandonné rendrait la
        // page que le suivant vient de prendre, et la rechargerait sous lui.
        guard dictee.cycle == cycle else { return }
        switch issue {
        case .reussie: state = .idle
        case .echec(let message, _): state = .failed(message)
        case .sansSuite: break
        }
        voieDuCycle = nil
        self.dictee = nil
        chatgpt.apresLivraison(module, issue: issue)
    }

    // MARK: - Destination

    /// Insère un texte déjà transcrit — réinsertion depuis l'historique.
    func insert(_ text: String) async {
        do {
            try await livraison.deliver(text, to: target)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Recours

    /// Au repos : ni démarrage, ni écoute, ni transcription en cours.
    ///
    /// Les trois recours du menu sur l'audio conservé n'ont de sens qu'ici.
    /// Ils posaient `.idle` quel que soit l'état : par-dessus un magnétophone
    /// qui tournait, la touche suivante croyait démarrer, le magnétophone
    /// refusait en silence de repartir, et la dictée d'après rendait deux
    /// phrases collées.
    var isAtRest: Bool {
        switch state {
        case .idle, .failed: true
        case .starting, .recording, .processing: false
        }
    }

    /// Relance la transcription de l'audio conservé après un échec.
    func retryLast() {
        guard let pendingAudio = livraison.pendingAudio, isAtRest else { return }
        // Posé tout de suite, et non par la tâche : entre les deux, un appui
        // aurait trouvé l'état au repos et ouvert un cycle par-dessus.
        state = .processing
        // Seule la voie macOS garde de l'audio : c'est elle qui le rejoue,
        // quelle que soit la voie retenue depuis.
        voieDuCycle = .apple
        // Le menu de Caspr ne prend pas le premier plan : l'application devant
        // est celle où l'on veut le texte, comme à l'appui. Et la destination
        // du moment : réessayer est une nouvelle livraison.
        applicationVisee = Livraison.applicationDevant()
        let figee = figer(.apple, module: nil, duree: livraison.pendingDuration)
        // L'aperçu gardé avec cet audio, et non celui d'une dictée faite
        // depuis.
        let apercu = livraison.pendingPreviewText ?? ""
        Task { await transcrireParMacOS(pendingAudio, figee, apercuConserve: apercu) }
    }

    /// Insère ce que l'aperçu en direct avait écrit (cf.
    /// `Livraison.insererLApercu`).
    func insertPendingPreview() {
        guard pendingPreviewText != nil, isAtRest else { return }
        Task {
            do {
                try await livraison.insererLApercu()
            } catch {
                if isAtRest { state = .failed(error.localizedDescription) }
                return
            }
            // Une dictée a pu commencer pendant l'insertion : son état n'est
            // pas le nôtre.
            if isAtRest { state = .idle }
        }
    }

    /// Libère l'audio ou le brut conservés. Appelé quand l'utilisateur
    /// renonce.
    func discardPending() {
        guard isAtRest else { return }
        livraison.oublierLeRecours()
        state = .idle
    }

    var hasPendingAudio: Bool { livraison.hasPendingAudio }
    var pendingPreviewText: String? { livraison.pendingPreviewText }
    /// L'aperçu de macOS, ou la transcription brute de ChatGPT.
    var pendingPreviewVoie: VoieDeDictee { livraison.voieDuRecours }
    var pendingDuration: TimeInterval { livraison.pendingDuration }

    /// Met fin à la discussion ChatGPT depuis le menu.
    ///
    /// La sortie qui reste quand Échap n'est pas pris : une discussion qui ne
    /// fait que parler, ou dont on a fermé la fenêtre, n'a rien sous les yeux
    /// pour Échap — et le prendre quand même avalait la frappe dans
    /// l'application où l'on travaillait, en fermant le fil au passage.
    func endDiscussion() {
        guard isAtRest, Relais.partage.enDiscussion else { return }
        Relais.partage.terminerDiscussion()
    }

    // MARK: - Échap

    /// Prend ou rend Échap selon ce qui est en cours — la seule décision, prise
    /// à chaque changement d'état ou d'affichage du relais.
    ///
    /// Il était pris et rendu au fil des chemins du cycle, une ligne par
    /// chemin, et l'un d'eux l'oubliait toujours. Pris pendant l'écoute ; rendu
    /// pendant la transcription, qui peut durer des minutes pendant qu'on
    /// travaille ailleurs ; au repos, pris seulement devant une discussion
    /// affichée (cf. `Relais.discussionAffichee`) — Caspr est alors au repos,
    /// mais une fenêtre attend qu'on en sorte.
    private func ajusterEchap() {
        let voulu = switch state {
        case .recording: true
        case .starting, .processing: false
        case .idle, .failed: Relais.partage.discussionAffichee
        }
        echap.tenir(voulu)
    }
}
