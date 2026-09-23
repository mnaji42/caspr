import AppKit
import AVFoundation
import Carbon.HIToolbox
import CasprCore

/// Enchaînement raccourci → capture → transcription → insertion.
///
/// Un seul cycle à la fois : réappuyer pendant le traitement est ignoré
/// plutôt que mis en file, sinon deux transcriptions se disputeraient le
/// curseur.
@MainActor
final class DictationController {
    enum State: Equatable {
        case idle
        /// L'appui est reçu, l'écoute n'est pas encore ouverte.
        ///
        /// Posé **avant** le premier `await`, et c'est toute sa raison d'être.
        /// Sous le relais, ouvrir l'écoute attend la page — de une à plusieurs
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
    var language: String { Preferences.shared.language }

    /// Destination du texte : curseur actif, ou fichier de notes.
    ///
    /// Elle n'est lue qu'à la livraison (cf. `deliver`), jamais au démarrage :
    /// basculer en pleine phrase redirige donc la dictée en cours, dans les
    /// deux sens. C'est le comportement attendu — on se rend compte en parlant
    /// que ça ne doit pas aller là.
    ///
    /// **Lue** dans les préférences, jamais recopiée — la même règle que le
    /// langue juste au-dessus, et pour la même raison.
    /// Elle était un état local remis au curseur à chaque lancement, ce qui
    /// obligeait qui travaille au fichier de notes à y revenir tous les matins.
    var target: DictationTarget { Preferences.shared.effectiveTarget }

    /// Fichier des notes, mémorisé même quand on écrit au curseur.
    var noteFile: URL? { Preferences.shared.noteFile }

    /// Le moteur système de macOS 26, absent en dessous.
    private let systemEngine: (any SpeechEngine)?
    /// L'autre moteur système, celui de la Dictée. Présent partout où la
    /// dictée de macOS fonctionne — Mac Intel et macOS antérieurs compris.
    private let legacyEngine: any SpeechEngine
    private let recorder = AudioRecorder()
    private let injector = TextInjector()
    private let overlay = RecordingOverlay()
    private var escapeMonitor: HotkeyMonitor?

    /// Aperçu en direct, quand le système sait le faire et que l'utilisateur
    /// le veut. `nil` le reste du temps.
    private var preview: (any SpeechPreviewing)?

    /// Dernier texte rendu par l'aperçu pour la dictée en cours : le recours
    /// qui reste quand la passe finale échoue (cf. `pendingPreview`).
    private var previewText = ""

    let history = TranscriptionHistory()

    /// Audio d'une dictée dont la transcription a échoué. Conservé en mémoire
    /// vive uniquement, et libéré dès qu'une insertion réussit ou que
    /// l'utilisateur y renonce.
    private var pendingAudio: [Float]?

    /// Ce que l'aperçu en direct avait déjà écrit, quand la passe finale a
    /// échoué.
    ///
    /// Le moteur de macOS a transcrit pendant qu'on parlait. Si la passe finale
    /// échoue, ce texte existe, il est bon — moins soigné que la passe finale,
    /// qui a toute la phrase sous les yeux — et il était jeté. On proposait
    /// donc de « réessayer » comme seule issue, y compris quand la cause de
    /// l'échec ne s'arrangera pas d'un second essai : un modèle absent
    /// manquera encore.
    ///
    /// Figé ici plutôt que lu dans `previewText` au moment de l'insertion : ce
    /// dernier est remis à zéro au début de la dictée suivante, et l'on peut
    /// très bien reparler avant de décider quoi faire de la précédente.
    private var pendingPreview: String?

    /// La version de macOS qui écrit, choisie à l'instant sur ce que la
    /// machine sait faire dans la langue (cf. `EngineSafetyManager`).
    private var writerChoice: EngineChoice { EngineSafetyManager.effectiveEngine }

    /// La Dictée en dernier recours : elle existe partout, et c'est elle qui
    /// dira pourquoi elle ne peut pas écrire, plutôt qu'un moteur absent.
    private var writer: any SpeechEngine {
        engine(for: writerChoice) ?? legacyEngine
    }

    private func engine(for choice: EngineChoice) -> (any SpeechEngine)? {
        switch choice {
        case .apple: systemEngine
        case .appleLegacy: legacyEngine
        }
    }

    init() {
        if #available(macOS 26.0, *) {
            self.systemEngine = AppleSpeechEngine()
        } else {
            self.systemEngine = nil
        }
        // Toujours instancié : il ne coûte rien tant qu'on ne l'appelle pas,
        // et sa disponibilité réelle se demande à `EngineChoice.isAvailable`
        // plutôt qu'à une version de macOS.
        self.legacyEngine = LegacySpeechEngine()
        overlay.levelProvider = { [weak self] in self?.recorder.level ?? 0 }
        overlay.onCancel = { [weak self] in self?.cancel() }
        // RELAIS — la page peut mourir pendant qu'on parle.
        Relais.partage.surPageInterrompue = { [weak self] in self?.pageRelaisInterrompue() }
        // RELAIS — Échap suit ce que le relais montre (cf. `ajusterEchap`).
        Relais.partage.surAffichageChange = { [weak self] in self?.ajusterEchap() }
        // RELAIS — le choix se fait sur la barre, au moment de parler.
        overlay.onSelectModule = { [weak self] index in
            guard let self else { return }
            let modules = RelaisCatalogue.proposes
            guard modules.indices.contains(index) else { return }
            RelaisCatalogue.courant = modules[index]
            // L'affichage appartient au module : changer de module en pleine
            // dictée doit le faire suivre. C'était le seul réglage figé à
            // l'appui de la touche, et c'est le cas courant — on change d'avis
            // parce qu'on a déjà commencé à parler.
            if state == .recording { Relais.partage.afficherBarre() }
            refreshOverlay()
        }
        overlay.onSelectTarget = { [weak self] wantsNotes in
            guard let self else { return }
            setNotesTarget(wantsNotes)
            refreshOverlay()
            onStateChange?(state)
        }
        // Changer de langue en pleine phrase est sans danger : l'audio est
        // enregistré et transcrit **à la fin**, avec la langue en vigueur à ce
        // moment-là. C'est donc le texte réellement inséré qui suit la
        // bascule. Seul l'aperçu en direct doit repartir sur le nouveau
        // moteur — son texte est jeté de toute façon, et son échec n'a jamais
        // d'effet sur la dictée.
        overlay.onSelectLanguage = { [weak self] code in
            guard let self, Preferences.shared.primaryLanguage != code else { return }
            Preferences.shared.primaryLanguage = code
            if state == .recording, Preferences.shared.livePreviewEnabled {
                stopPreview()
                startPreview()
            }
            refreshOverlay()
            onStateChange?(state)
        }
    }

    /// État courant de la barre.
    ///
    /// RELAIS — la langue n'a aucun sens quand la dictée passe par ChatGPT, qui
    /// la détecte lui-même, et l'afficher quand même laisserait croire qu'elle
    /// agit. Le badge de langue sert alors à nommer le moteur réellement à
    /// l'œuvre — sans quoi la barre est indiscernable d'une dictée ordinaire.
    private var overlayStatus: RecordingOverlay.Status {
        // La voie de la dictée en cours ; au repos, celle de la suivante.
        switch voieDuCycle ?? Preferences.shared.voie {
        case .apple:
            break
        case .chatgpt:
            // La pastille porte les modules du relais dès que l'aller-retour
            // est calibré. Sans lui, un seul module est possible, et la barre
            // n'en montre pas : proposer un choix qui échouerait vaut moins
            // que ne rien proposer.
            let modules = RelaisCatalogue.proposes
            let courant = RelaisCatalogue.courant
            return RecordingOverlay.Status(
                target: target,
                noteName: noteFile?.lastPathComponent,
                canPickNote: state != .recording,
                previewEnabled: Preferences.shared.livePreviewEnabled,
                moduleLabels: modules.map(\.nom),
                moduleIndex: modules.firstIndex(of: courant) ?? 0,
                destinationImposee: courant.sorties == [.aucune]
                    ? "Réponse à l'écran" : nil,
                languageBadge: "ChatGPT",
                switchableLanguages: [],
                languageCode: Preferences.shared.primaryLanguage)
        }
        return RecordingOverlay.Status(
            target: target,
            noteName: noteFile?.lastPathComponent,
            // Sans fichier mémorisé, basculer sur les notes suppose un
            // sélecteur — impossible pendant qu'on parle.
            canPickNote: state != .recording,
            previewEnabled: Preferences.shared.livePreviewEnabled,
            // La langue **effectivement** écoutée. Elle n'était nulle part sur
            // la barre : depuis le multi-langues, dicter en français avec
            // l'anglais actif produit un texte incompréhensible qu'on met
            // longtemps à imputer à la bonne cause.
            languageBadge: Preferences.shared.primary.shortBadge,
            switchableLanguages: Preferences.shared.activeLanguages
                .map { ($0.code, $0.shortBadge) },
            languageCode: Preferences.shared.primaryLanguage)
    }

    private func refreshOverlay() {
        overlay.update(overlayStatus)
    }

    /// La voie du cycle en cours, **figée à l'appui** ; `nil` hors d'un cycle.
    ///
    /// Lue une fois, dans `commencer`, et portée jusqu'à la livraison. La
    /// relire en chemin, c'était laisser une bascule en pleine phrase
    /// arrêter par macOS une écoute que ChatGPT avait ouverte — le geste
    /// d'arrêt n'a pas à redire par où l'on était parti. Basculer vaut donc
    /// pour la dictée suivante, et le relais garde sa page jusqu'à la fin de
    /// celle-ci (cf. `Relais.suivreLaVoie`).
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
    // RELAIS — début de la dictée, faute d'enregistrement pour en déduire la
    // durée. Elle sert à dimensionner l'attente de la transcription.
    private var relaisDebut = Date()
    // RELAIS — le cycle en cours, retenu pour qu'Échap puisse l'interrompre.
    // L'attente d'une transcription ChatGPT dure des minutes : sans prise
    // dessus, la barre restait sur « Transcription… » sans autre issue que de
    // quitter l'application.
    private var relaisTache: Task<Void, Never>?
    // RELAIS — le démarrage en cours, retenu pour que la touche l'interrompe.
    //
    // Avant l'écoute, l'appui attend que la page soit prête — jusqu'à
    // quelques dizaines de secondes quand elle a dû être rechargée. C'est
    // l'état `.starting` qui dit qu'on y est, et cette tâche qui permet d'en
    // sortir.
    private var relaisDemarrage: Task<Void, Never>?
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
            // RELAIS — la touche interrompt l'attente du démarrage, comme
            // celle de la transcription. Le démarrage se défait lui-même (cf.
            // `startRecording`) : c'est lui qui sait où il en était.
            //
            // Sur le chemin ordinaire, rien à interrompre : seul le dialogue
            // d'autorisation du micro peut retenir le démarrage, et il se
            // ferme par ses propres boutons.
            relaisDemarrage?.cancel()
        case .recording:
            relaisTache = Task { await finishRecording() }        // RELAIS —
        case .processing:
            // RELAIS — la touche interrompt l'attente.
            //
            // Sur le chemin ordinaire, ignorer est juste : le traitement dure
            // une seconde, et réappuyer n'est qu'un geste nerveux. Ici il peut
            // durer des minutes, et il faut une sortie. Échap ne peut pas la
            // fournir — c'est un raccourci global, une pression dans une autre
            // application annulerait sans qu'on l'ait voulu, ce qui est
            // précisément le défaut qu'on vient de corriger.
            //
            // La touche de dictée, elle, est un geste délibéré et propre à
            // Caspr : personne ne la presse par distraction, et celui qui la
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
            break
        case .chatgpt:
            // RELAIS — une seule chose à la fois sur la page.
            //
            // La dictée et la calibration pilotent le même document. Les
            // laisser tourner ensemble faisait intercepter par la calibration
            // les clics que la dictée envoyait par programme : Caspr prenait
            // ses propres commandes pour des gestes de l'utilisateur.
            guard Relais.partage.prendreLaMainPourDictee() else {
                state = .failed(Relais.partage.occupation.raison ?? "Relais occupé.")
                return
            }
            guard Relais.partage.estCalibre else {
                Relais.partage.rendreLaMain()
                state = .failed("ChatGPT Web Preview est actif mais pas configuré — "
                                + "voir Réglages › Moteur IA.")
                return
            }
        }
        voieDuCycle = voie
        applicationVisee = Self.applicationDevant()
        state = .starting
        let demarrage = Task { await startRecording(voie: voie) }
        switch voie {
        case .apple: break
        case .chatgpt: relaisDemarrage = demarrage
        }
    }

    func cancel() {
        switch state {
        case .starting:
            // RELAIS — la croix de la barre, pendant que la page se prépare.
            relaisDemarrage?.cancel()
            return
        case .idle, .failed:
            // RELAIS — hors dictée, Échap met fin à la discussion ouverte.
            //
            // Après un échec aussi : une dictée ratée en pleine discussion
            // laisse l'état sur `.failed`, et la discussion doit pouvoir se
            // fermer quand même.
            if Relais.partage.enDiscussion {
                quitterLaDiscussion()
                Feedback.cancelled()
            }
            return
        case .recording, .processing:
            break
        }
        // RELAIS — deux différences avec le chemin ordinaire, et la seconde
        // avait été manquée.
        //
        // L'annulation vaut d'abord pendant l'attente de la transcription, qui
        // n'a pas de fin prévisible — c'est même là qu'elle sert le plus.
        //
        // Et surtout, dans les deux états, il faut arrêter la page et refermer
        // sa barre. Le chemin ordinaire ne connaît que le magnétophone de
        // Caspr : Échap pendant l'enregistrement rendait donc la main, mais
        // laissait ChatGPT écouter derrière une barre restée à l'écran.
        //
        // Sauf une fois le message de « Discuter » parti : il n'y a plus rien
        // à abandonner, ChatGPT répond dans le fil. Ni arrêter la page, ni
        // cacher la barre — seulement cesser d'attendre la lecture à haute
        // voix. Le cycle s'achève alors de lui-même, sur la discussion
        // ouverte (cf. `Relais.messageParti`) : il reste le sien.
        switch voieDuCycle {
        case .chatgpt?:
            if state == .processing, Relais.partage.messageParti {
                relaisTache?.cancel()
                relaisTache = nil
            } else {
                abandonnerLeCycleRelais()
            }
            return
        case .apple?, nil:
            break
        }
        guard state == .recording else { return }
        recorder.cancel()
        stopPreview()
        overlay.hide()
        Feedback.cancelled()
        voieDuCycle = nil
        state = .idle
    }

    /// RELAIS — abandonne le cycle en cours, et fait à sa place ce qu'il ne
    /// fera plus.
    ///
    /// Le cycle cesse d'être le cycle en cours avant tout le reste : ce qui
    /// s'en déroulera encore — l'annulation se constate à la tâche suivante —
    /// ne touchera plus à rien. Rendre la page, l'arrêter, la préparer pour la
    /// suivante, tout se fait donc ici, une fois — jusqu'à quitter la
    /// discussion quand le module du moment écrit ailleurs, comme
    /// `acheverLeCycle` l'aurait fait.
    private func abandonnerLeCycleRelais() {
        cycle &+= 1
        relaisTache?.cancel()
        relaisTache = nil
        voieDuCycle = nil
        Relais.partage.rendreLaMain()
        Relais.partage.interrompre(
            quitterLaDiscussion: Relais.partage.sortieCourante != .aucune)
        overlay.hide()
        Feedback.cancelled()
        state = .idle
    }

    // MARK: - Étapes

    private func startRecording(voie: VoieDeDictee) async {
        let parRelais = voie == .chatgpt
        // Toute sortie qui n'aboutit pas à l'écoute rend la page, et quitte
        // `.starting`. Une ligne par chemin de sortie, c'était la promesse d'en
        // oublier un — et il y en avait deux : un micro ou une accessibilité
        // refusés gardaient la page jusqu'au redémarrage.
        //
        // Aucun autre cycle ne peut s'ouvrir d'ici là : l'état reste
        // `.starting` jusqu'à cette sortie, et un appui n'y fait qu'annuler.
        defer {
            relaisDemarrage = nil
            if state == .starting { state = .idle }
            if state != .recording {
                voieDuCycle = nil
                switch voie {
                case .apple: break
                case .chatgpt: Relais.partage.rendreLaMain()
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
            // RELAIS — Caspr n'enregistre pas pendant une dictée relais.
            //
            // Il l'a fait, et c'était nuisible sans être utile. Sans utilité,
            // parce que la transcription vient du micro ouvert par la page :
            // l'audio capté ici n'aurait servi qu'à l'aperçu en direct. Et
            // nuisible, parce que les deux captures ne cohabitent pas — mesuré
            // au niveau crête, 0.000 sur toutes les dictées dès qu'une page
            // ChatGPT existe. Ne pas ouvrir le micro du tout est la seule façon
            // de garantir que la dictée principale reste intacte.
            //
            // L'aperçu en direct est donc impossible ici, et c'est définitif :
            // il faudrait un second flux micro, celui-là même qui casse tout.
            switch voie {
            case .chatgpt:
                relaisDebut = Date()
                // La barre s'ouvre avant l'écoute : on voit ChatGPT démarrer,
                // et la page, enfin à l'écran, cesse d'être différée par le
                // système.
                Relais.partage.afficherBarre()
                // La page se prépare encore : on le dit, plutôt que de laisser
                // l'écran muet le temps qu'elle soit prête.
                if Relais.partage.preparationEnCours {
                    overlay.showProcessing("ChatGPT se prépare…")
                }
                try await Relais.partage.demarrer()
                // Interrompu à l'instant où la page commençait à écouter :
                // l'annulation l'emporte, la page est arrêtée plus bas.
                try Task.checkCancellation()
            case .apple:
                try recorder.start()
            }
            Log.info("enregistrement démarré")
            previewText = ""
            // Avant d'afficher la barre : elle grise le bouton Notes tant
            // qu'un sélecteur serait impossible, et lit l'état pour le savoir.
            // Échap est pris au passage (cf. `ajusterEchap`).
            state = .recording
            overlay.showRecording(overlayStatus)
            switch voie {
            case .chatgpt:
                overlay.setPreviewNotice("ChatGPT transcrit à la fin de la dictée")
            case .apple:
                startPreview()
            }
            Feedback.recordingStarted()
        } catch is CancellationError {
            // RELAIS — la touche a interrompu l'attente du démarrage. La page
            // a pu se mettre à écouter entre-temps : on l'arrête, comme Échap
            // le fait pendant l'enregistrement. La page est rendue par le
            // `defer`, avant que l'arrêt ne s'exécute : c'est l'arrêt qui
            // range la barre, et il ne le fait qu'une page libre.
            Relais.partage.interrompre()
            overlay.hide()
            Feedback.cancelled()
            state = .idle
        } catch {
            // RELAIS — la barre dit pourquoi, quand la raison tient en une
            // ligne ; elle s'efface sinon, au lieu de rester sur « ChatGPT se
            // prépare… » devant une dictée qui n'aura pas lieu.
            //
            // Et la barre de ChatGPT se range avec elle. Ouverte avant
            // l'écoute, elle restait à flotter au-dessus du travail, sans
            // rapport visible avec le message d'échec. Pas la grande fenêtre,
            // si elle vient de s'ouvrir : c'est là qu'on se connecte.
            if parRelais {
                if let courte = (error as? RelaisPage.Erreur)?.raisonCourte {
                    overlay.showFailure(courte)
                } else {
                    overlay.hide()
                }
                Relais.partage.rangerLaBarre()
            }
            state = .failed(error.localizedDescription)
        }
    }

    /// RELAIS — WebKit a tué la page pendant qu'on parlait.
    ///
    /// La page est déjà rechargée, et le son qu'elle captait est perdu avec
    /// elle. Continuer d'afficher l'écoute, c'était laisser parler dans le
    /// vide jusqu'à l'appui d'arrêt ; on échoue donc tout de suite, en le
    /// disant. Les autres phases le découvrent seules : l'attente de la
    /// transcription relève la mort à son tour suivant, et le démarrage au
    /// clic suivant.
    private func pageRelaisInterrompue() {
        guard voieDuCycle == .chatgpt, state == .recording else { return }
        let erreur = RelaisPage.Erreur.pageInterrompue
        Log.error("relais : la page est morte pendant l'écoute")
        voieDuCycle = nil
        Relais.partage.rendreLaMain()
        Relais.partage.masquerBarre()
        overlay.showFailure(erreur.raisonCourte ?? "La page ChatGPT s'est fermée")
        state = .failed(erreur.localizedDescription)
    }

    private func finishRecording() async {
        // Abandonnée entre l'appui et l'exécution de cette tâche : il n'y a
        // plus d'écoute à arrêter, et la poursuivre prendrait le chemin
        // ordinaire — la voie du cycle vient d'être oubliée.
        guard state == .recording, let voie = voieDuCycle else { return }
        switch voie {
        case .apple:
            break
        case .chatgpt:
            // Rien n'a été enregistré de notre côté : ni durée minimale à
            // vérifier, ni audio à conserver pour un « Réessayer » qui n'aurait
            // rien à rejouer. La page a le son, elle seule.
            //
            // Échap est rendu, contrairement à ce qui avait été fait ici.
            //
            // Le raisonnement de départ était juste — l'attente peut durer des
            // minutes, il faut pouvoir en sortir — mais la conclusion était
            // fausse. Échap est un raccourci **global** : il répond quelle que
            // soit l'application au premier plan. Le garder armé une minute
            // pendant que quelqu'un travaille ailleurs, c'est faire d'une
            // touche parmi les plus pressées du clavier une annulation
            // silencieuse. Mesuré : deux réorganisations annulées coup sur
            // coup, sans que personne n'ait voulu annuler quoi que ce soit.
            //
            // La sortie de secours reste la croix de la barre, qui demande un
            // clic délibéré au bon endroit. Il est rendu au passage à
            // `.processing` (cf. `ajusterEchap`).
            Feedback.recordingStopped()
            // La phase et le chrono, relus sur l'attente du relais : elle
            // peut durer des minutes, et la touche de dictée en est la
            // sortie — encore faut-il le dire.
            overlay.showProcessing(RelaisAttente.Phase.transcription.libelle,
                                   progress: { Relais.partage.avancement })
            Log.info("fin de dictée relais : "
                     + "\(String(format: "%.1f", Date().timeIntervalSince(relaisDebut))) s")
            await transcribeAndInject([], voie: voie)
            return
        }
        let samples = recorder.stop()
        stopPreview()
        Feedback.recordingStopped()
        overlay.showProcessing()

        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        // Le niveau crête, et pas seulement la durée. Un compte
        // d'échantillons ne dit pas si l'on a enregistré du son ou du silence,
        // et les deux pannes ne se réparent pas au même endroit : un micro
        // muet se voit ici, une transcription vide se voit plus loin.
        let crete = samples.reduce(Float(0)) { max($0, abs($1)) }
        Log.info("fin d'enregistrement : \(String(format: "%.1f", seconds)) s capturées, "
                 + "crête \(String(format: "%.3f", crete)), "
                 + "moteur \(writerChoice.rawValue)")

        // Un appui-relâché trop bref ne contient rien d'exploitable ; inutile
        // de réveiller le moteur. Un vrai VAD reste à faire (cf. README).
        guard samples.count > Int(AudioRecorder.targetSampleRate * 0.3) else {
            Log.info("trop court, ignoré")
            overlay.hide()
            voieDuCycle = nil
            state = .idle
            return
        }

        await transcribeAndInject(samples, voie: voie)
    }

    /// Transcrit puis insère, en gardant l'audio tant que ce n'est pas réussi.
    ///
    /// Une dictée peut durer dix minutes. Perdre cet audio parce que le moteur
    /// était arrêté ou a échoué obligerait à tout redire — c'est le pire échec
    /// possible pour cette application. L'audio n'est donc libéré qu'après une
    /// insertion réussie, et `retryLast()` permet de relancer sans reparler.
    private func transcribeAndInject(_ samples: [Float], voie: VoieDeDictee) async {
        // Le cycle que cette transcription sert. S'il a été abandonné quand
        // elle reprend la main, elle n'a plus rien à faire : l'abandon a déjà
        // tout défait, et un autre cycle a peut-être commencé.
        let numero = cycle
        // Lue une fois : c'est l'application de l'appui qui compte, pas celle
        // d'un appui qui viendrait pendant la transcription.
        let visee = applicationVisee
        state = .processing
        // Le relais se conforme au protocole des moteurs, donc tout ce qui suit
        // (insertion, historique, échecs, barre) marche sans le savoir — à la
        // poignée de différences près que ce drapeau porte, en attendant que
        // chaque voie ait la sienne.
        let parRelais = voie == .chatgpt
        // RELAIS — vrai quand l'échec laisse la transcription dans la page, à
        // récupérer dans la fenêtre qu'on ouvre pour cela.
        var texteLaisseDansLaPage = false
        // RELAIS — rendue ici parce que c'est la sortie commune à tous les
        // chemins : réussite, texte vide, échec, annulation. La rendre à
        // chaque endroit serait la promesse d'en oublier un, et un oubli
        // condamne la page jusqu'au redémarrage.
        func acheverLeCycle() {
            voieDuCycle = nil
            if parRelais { Relais.partage.rendreLaMain() }
            // RELAIS — et la page est rendue prête pour la prochaine, pendant
            // qu'on ne s'en sert pas. Sauf si l'on vient d'y laisser un texte
            // à récupérer : la préparer maintenant le détruirait sous les yeux
            // de qui vient le chercher. Elle attend alors qu'on en ait fini.
            //
            // Avant de quitter la discussion, et non après : c'est ce report
            // qui dit à la sortie de la discussion de laisser la fenêtre
            // ouverte sur le texte.
            if parRelais {
                Relais.partage.preparerLaProchaine(apresEchec: texteLaisseDansLaPage)
            }
            // RELAIS — délivrer ailleurs, c'est quitter la discussion.
            //
            // Basculer de « Discuter » vers un module qui écrit au curseur
            // referme la fenêtre : l'état devait suivre. Il ne suivait pas, et
            // Caspr poursuivait alors un fil que plus personne ne voyait — la
            // dictée suivante arrivait dans la conversation d'avant.
            //
            // Ici plutôt qu'au fil des chemins de sortie : réussite, texte
            // vide, échec et annulation passent tous par là.
            if parRelais, Relais.partage.sortieCourante != .aucune {
                quitterLaDiscussion()
            }
            // RELAIS — la barre de ChatGPT se range à la fin de la dictée,
            // quelle qu'en soit l'issue.
            //
            // Seules la réussite et un échec sur deux la rangeaient : un texte
            // vide la laissait flotter au-dessus du travail, sans rapport avec
            // le message affiché. Deux exceptions, qui sont ce que la dictée
            // laisse délibérément à l'écran — la discussion qui continue, et
            // la fenêtre ouverte pour qu'on y récupère son texte.
            if parRelais, !texteLaisseDansLaPage, !Relais.partage.enDiscussion {
                Relais.partage.masquerBarre()
            }
        }
        // Seulement pour le cycle en cours : un cycle abandonné rendrait la
        // page que le suivant vient de prendre, et la rechargerait sous lui.
        defer {
            if numero == cycle { acheverLeCycle() }
        }
        let moteur: any SpeechEngine = switch voie {
        case .apple: writer
        case .chatgpt: RelaisEngine()
        }
        do {
            let result = try await moteur.transcribe(
                TranscriptionRequest(samples: samples, language: language))
            guard numero == cycle else { return }

            // RELAIS — une sortie qui n'écrit nulle part s'arrête ici.
            //
            // La réponse est déjà à l'écran, dans la page que l'utilisateur a
            // sous les yeux. Rien à insérer, rien à archiver — l'historique est
            // un filet pour retrouver un texte qu'une insertion aurait perdu,
            // et une conversation n'est pas une dictée qu'on range.
            if parRelais, Relais.partage.sortieCourante == .aucune {
                // Abandonnée avant l'envoi, la dictée n'ouvre pas de
                // discussion : l'annulation a déjà rendu la main. Après
                // l'envoi, l'appui n'a fait que cesser d'attendre, et le fil
                // parti doit rester ouvert — sans quoi la fin du cycle
                // rechargeait la page sous la réponse de ChatGPT.
                if Task.isCancelled, !Relais.partage.messageParti {
                    throw CancellationError()
                }
                // Sauf un refus — un quota, un envoi impossible : sans voix
                // ni texte à insérer, la barre est le seul endroit où le lire.
                // L'avertissement se suffit, en une ligne : un titre « n'a
                // pas répondu » au-dessus de « n'a pas répondu en 3 min » ne
                // faisait que le répéter.
                if let avertissement = Relais.partage.prendreAvertissement() {
                    overlay.showFailure(avertissement)
                    state = .failed("\(avertissement).")
                } else {
                    overlay.hide()
                    state = .idle
                }
                entrerEnDiscussion()
                return
            }
            let text = result.text
            guard !text.isEmpty else {
                // Le dernier chemin réellement muet de l'application : le
                // moteur répond, sans erreur, avec une chaîne vide. Rien n'est
                // inséré, la barre disparaît, et il ne reste **aucun** indice —
                // ni message, ni entrée d'historique. Vu de l'utilisateur,
                // c'est indiscernable d'un raccourci qui n'aurait rien
                // déclenché, et c'est ce qui a fait chercher une panne de
                // dictée là où le moteur disait simplement n'avoir rien
                // entendu. La trace existait, mais dans un journal que
                // personne n'a de raison d'ouvrir.
                Log.error("le moteur a rendu un texte vide "
                          + "(\(writerChoice.rawValue), "
                          + "\(Int(result.latency.wallMs)) ms)")
                overlay.showFailure("Rien n'a été entendu",
                                    hint: Self.rescueHint(preview: previewText))
                // L'audio est conservé, contrairement à avant. Un moteur mal
                // configuré rend le vide aussi sûrement qu'un micro coupé, et
                // dans ce cas jeter la dictée oblige à tout redire — ce que
                // cette application s'interdit partout ailleurs.
                // RELAIS — rien à conserver : il n'y a pas d'audio de notre
                // côté, et « Réessayer » rejouerait le vide.
                if !parRelais {
                    pendingAudio = samples
                    pendingPreview = previewText
                }
                // `.failed` et non `.idle` : la barre renvoyait au menu, et le
                // menu affichait « Prêt ». Envoyer quelqu'un chercher une
                // explication à un endroit qui n'en porte aucune est pire que
                // de se taire — c'est lui faire douter de ce qu'il vient de
                // lire. Le menu porte donc la même raison que sur un échec du
                // moteur, puisque c'en est un du point de vue de l'utilisateur.
                state = .failed(parRelais
                    ? "ChatGPT n'a rien transcrit — avez-vous parlé ?"
                    : "Le moteur a répondu sans rien transcrire "
                      + "(\(writerChoice.fullLabel)) — "
                      + "audio conservé, « Réessayer » ci-dessous.")
                return
            }
            if parRelais { Relais.partage.masquerBarre() }         // RELAIS —
            overlay.hide()
            // L'application au premier plan au moment d'insérer. L'insertion
            // par accessibilité vise l'élément focalisé de cette
            // application-là : si c'est Caspr, le texte part dans une de nos
            // propres fenêtres et disparaît sans qu'aucune erreur ne soit
            // levée. C'était indiagnosticable de l'extérieur.
            // RELAIS — rendre le clavier avant d'écrire. Après une discussion,
            // ou si l'on bascule vers un module qui écrit en pleine dictée, la
            // fenêtre du relais est au premier plan : le texte y partirait.
            if parRelais { await Relais.partage.rendreLeClavier() }
            // Et là où l'on parlait, si l'on en est parti entre-temps.
            switch target {
            case .caret: await ramener(visee)
            case .file: break
            }
            // RELAIS — la touche de dictée abandonne jusqu'ici, et
            // l'insertion ne vérifie rien : un texte arrivé au moment de
            // l'abandon s'écrivait quand même.
            try Task.checkCancellation()
            let devant = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            Log.info("insertion vers \(devant)")
            try await deliver(text)
            history.add(text)
            // Abandonné pendant l'insertion : le texte est écrit, et c'est
            // tout ce qui reste de ce cycle. L'état appartient au suivant.
            guard numero == cycle else { return }
            pendingAudio = nil
            pendingPreview = nil
            Log.info("transcrit en \(Int(result.latency.wallMs)) ms, \(text.count) caractères")
            // RELAIS — la transformation a échoué et c'est le brut qui vient
            // d'être inséré : le dire, là où l'on regarde. Sans quoi un texte
            // non remanié passe pour la réponse de ChatGPT, et un quota
            // atteint pour une consigne mal suivie.
            if parRelais, let avertissement = Relais.partage.prendreAvertissement() {
                overlay.showFailure("Transcription brute insérée", hint: avertissement)
                state = .failed("Transcription brute insérée — \(avertissement).")
            } else {
                state = .idle
            }
        } catch is CancellationError {                             // RELAIS —
            // L'abandon a tout défait (cf. `abandonnerLeCycleRelais`).
            return
        } catch {
            guard numero == cycle else { return }
            // RELAIS — pas d'audio conservé : il n'y en a pas. « Réessayer »
            // rejouerait un enregistrement vide sur une page qui est passée à
            // autre chose, donc échouerait à coup sûr. Proposer un recours qui
            // ne peut pas marcher est pire que de n'en proposer aucun : le
            // texte, lui, est resté dans la fenêtre du relais, et c'est ce
            // qu'il faut aller chercher.
            if !parRelais {
                pendingAudio = samples
                pendingPreview = previewText
            }
            let minutes = Double(samples.count) / AudioRecorder.targetSampleRate / 60
            Log.error("échec de transcription : \(error.localizedDescription)"
                      + (parRelais ? "" : " — \(String(format: "%.1f", minutes)) min conservées"))
            // Dit là où l'utilisateur regarde. La barre des menus recevait déjà
            // le détail, mais on ne consulte pas un menu qu'on n'a pas de
            // raison d'ouvrir : sans ça, un échec se lit comme « je m'y suis
            // mal pris ».
            // RELAIS — sauf quand la page est morte : celle qu'on ouvrirait
            // est neuve, et le texte a disparu avec l'ancienne.
            let texteRecuperable = parRelais
                && (error as? RelaisPage.Erreur)?.laissePeutEtreLeTexte ?? true
            overlay.showFailure(Self.shortReason(for: error),
                                hint: Self.rescueHint(preview: previewText))
            state = .failed(parRelais
                ? (texteRecuperable
                    ? "\(error.localizedDescription) — le texte est peut-être encore "
                      + "dans la fenêtre du relais."
                    : error.localizedDescription)
                : "\(error.localizedDescription) — audio conservé, « Réessayer » dans le menu.")
            // RELAIS — la barre reste, et s'agrandit : quand la lecture
            // échoue, le texte est encore dans la page, et c'est le seul moyen
            // de le récupérer. Elle redevient donc utilisable au clavier, pour
            // qu'un ⌘C y soit possible. Rien n'est rechargé, et rien ne se
            // collera à la dictée suivante — celle-ci vide la zone avant
            // d'écouter.
            if parRelais, texteRecuperable {
                texteLaisseDansLaPage = true
                Relais.partage.ouvrirFenetre()
            }
        }
    }

    /// La raison, en une ligne qui tient dans la barre.
    ///
    /// Le message complet part dans le menu ; celui-ci doit se lire d'un coup
    /// d'œil, pendant les cinq secondes où la barre reste affichée.
    private static func shortReason(for error: Error) -> String {
        // RELAIS — un refus de ChatGPT porte sa raison, un quota par exemple :
        // la barre la montre au lieu d'un « Réessayer » qui n'existe pas ici.
        if let courte = (error as? RelaisPage.Erreur)?.raisonCourte { return courte }
        return "Transcription impossible — « Réessayer » dans le menu"
    }

    /// Achemine le texte vers la destination courante.
    ///
    /// Sur cible verrouillée, l'insertion au curseur est délibérément évitée :
    /// l'intérêt du verrou est justement de pouvoir continuer à travailler
    /// ailleurs sans que la dictée vienne s'écrire dans le code en cours.
    private func deliver(_ text: String) async throws {
        switch target {
        case .caret:
            try await injector.inject(text)
        case .file(let url):
            try TargetWriter.append(text, to: url)
            NSLog("caspr: ajouté à %@", url.lastPathComponent)
        }
    }

    /// L'application au premier plan, sauf si c'est Caspr.
    private static func applicationDevant() -> NSRunningApplication? {
        guard let devant = NSWorkspace.shared.frontmostApplication,
              devant.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return nil }
        return devant
    }

    /// Ramène au premier plan l'application où l'on parlait, si l'on en est
    /// parti et qu'elle tourne encore.
    ///
    /// Le système ne garantit ni que l'activation ait lieu, ni quand : on
    /// **observe** donc qu'elle soit devant, une seconde au plus, avant
    /// d'écrire. Passé ce délai, ou si elle a été quittée, le texte part là où
    /// l'on se trouve — c'était le comportement d'avant, et l'historique le
    /// garde de toute façon.
    private func ramener(_ application: NSRunningApplication?) async {
        guard let application, !application.isTerminated else { return }
        let workspace = NSWorkspace.shared
        func devant() -> Bool {
            workspace.frontmostApplication?.processIdentifier == application.processIdentifier
        }
        guard !devant() else { return }
        let nom = application.bundleIdentifier ?? application.localizedName ?? "?"
        // Céder d'abord : depuis macOS 14, l'activation est coopérative, et une
        // application qui a le premier plan — la fenêtre du relais, parfois —
        // doit le rendre pour qu'une autre puisse le prendre.
        NSApp.yieldActivation(to: application)
        application.activate(options: [])
        let echeance = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < echeance {
            if devant() {
                Log.info("insertion : retour à \(nom), où l'on parlait")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Log.error("insertion : \(nom) n'a pas repris le premier plan en 1 s — "
                  + "texte inséré devant")
    }

    /// Insère un texte déjà transcrit — réinsertion depuis l'historique.
    func insert(_ text: String) async {
        do {
            try await deliver(text)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Bascule entre curseur et notes, sans jamais rien redétecter.
    ///
    /// Le fichier de notes est mémorisé indépendamment de la destination
    /// courante : revenir au curseur ne l'oublie pas, et y retourner ne coûte
    /// qu'un clic. La version précédente relançait la détection à chaque
    /// bascule, donc pouvait ouvrir un sélecteur au milieu d'une phrase — un
    /// panneau modal qui active Caspr, déplace le curseur et avale les
    /// frappes, c'est-à-dire tout ce que la barre flottante évite par
    /// ailleurs.
    func setNotesTarget(_ wantsNotes: Bool) {
        guard wantsNotes else {
            Preferences.shared.destination = .caret
            return
        }
        if noteFile != nil {
            Preferences.shared.destination = .notes
            return
        }
        guard state != .recording else {
            NSLog("caspr: aucun fichier de notes mémorisé — en choisir un depuis le menu")
            return
        }
        chooseNoteFile()
    }

    /// Choisit le fichier des notes, et écrit dedans à partir de maintenant.
    ///
    /// On tente d'abord le document ouvert devant : dans ce cas il suffit de
    /// poser le curseur dans le fichier voulu, sans passer par un sélecteur.
    @discardableResult
    func chooseNoteFile() -> URL? {
        var chosen = TargetWriter.frontmostDocument()
        if chosen == nil {
            // Détection impossible : plutôt qu'un sélecteur surgissant sans
            // raison apparente, on dit pourquoi avant de le proposer.
            NSLog("caspr: fichier non identifié — sélecteur")
            chosen = TargetWriter.chooseFile()
        }
        guard let chosen else { return nil }
        Preferences.shared.noteFile = chosen
        Preferences.shared.destination = .notes
        NSLog("caspr: notes dans %@", chosen.path)
        return chosen
    }

    /// Revient au curseur. Le fichier de notes reste mémorisé.
    func unlockTarget() {
        Preferences.shared.destination = .caret
    }

    // MARK: - Aperçu en direct

    /// Branche l'aperçu sur le flux micro, si le système et l'utilisateur le
    /// permettent.
    ///
    /// Rien de ceci ne touche à la transcription : l'aperçu lit les mêmes
    /// tampons, en parallèle, et son texte est jeté à la fin. Un échec de
    /// l'aperçu n'a donc aucun effet sur la dictée.
    private func startPreview() {
        guard Preferences.shared.livePreviewEnabled, preview == nil else { return }
        // La version qui écrira, et nulle autre : cf. `SpeechPreview.engine`.
        guard let made = SpeechPreview.make(
            for: language,
            onText: { [weak self] text in
                guard let self else { return }
                if previewText.isEmpty, !text.isEmpty {
                    Log.info("aperçu : premier texte reçu")
                }
                // Retenu pour le recours : si la passe finale échoue, c'est
                // un texte de macOS sur exactement le même audio.
                self.previewText = text
                self.overlay.setPreviewText(text)
            },
            onFailure: { [weak self] reason in
                Log.error("aperçu indisponible : \(reason)")
                self?.overlay.setPreviewNotice(reason)
            })
        else {
            overlay.setPreviewNotice("aperçu indisponible sur cette machine")
            return
        }
        self.preview = made
        recorder.onBuffer = { [weak preview = made] buffer in
            preview?.append(buffer)
        }
        // Détaché : le premier lancement peut télécharger le modèle système,
        // et la dictée ne doit pas attendre.
        Task { await made.start(language: language) }
    }

    private func stopPreview() {
        recorder.onBuffer = nil
        preview?.stop()
        preview = nil
    }

    /// La phrase qui dit que rien n'est perdu, sous le message d'échec.
    ///
    /// La barre s'efface au bout de cinq secondes, et c'est voulu : la laisser
    /// ouverte sur un échec encombrerait l'écran, d'autant que le cas le plus
    /// fréquent n'en est pas un — on a déclenché sans parler. Mais elle est le
    /// seul endroit où l'on regarde à ce moment-là, et disparaître sans rien
    /// dire laisse croire que la dictée est perdue.
    ///
    /// Elle nomme donc les deux issues quand les deux existent, et la seule
    /// quand il n'y en a qu'une : sans aperçu — parce qu'il est coupé, ou
    /// parce qu'on n'a effectivement rien dit — proposer d'insérer un texte
    /// vide serait une fausse promesse de plus.
    private static func rescueHint(preview: String) -> String {
        preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Rien n'est perdu : « Réessayer » dans le menu de Caspr."
            : "Rien n'est perdu : insérer l'aperçu ou réessayer, dans le menu de Caspr."
    }

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
        guard let pendingAudio, isAtRest else { return }
        // Posé tout de suite, et non par la tâche : entre les deux, un appui
        // aurait trouvé l'état au repos et ouvert un cycle par-dessus.
        state = .processing
        // Seule la voie macOS garde de l'audio : c'est elle qui le rejoue,
        // quelle que soit la voie retenue depuis.
        voieDuCycle = .apple
        // Le menu de Caspr ne prend pas le premier plan : l'application devant
        // est celle où l'on veut le texte, comme à l'appui.
        applicationVisee = Self.applicationDevant()
        Task { await transcribeAndInject(pendingAudio, voie: .apple) }
    }

    /// Insère ce que l'aperçu en direct avait écrit, faute de mieux.
    ///
    /// La seconde issue d'un échec, et souvent la bonne : quand la version de
    /// macOS choisie ne sait pas écrire ici, réessayer échouera pareil, alors
    /// que le texte de l'aperçu est là et se suffit à lui-même. Moins soigné
    /// que la passe finale, mais un texte imparfait vaut mieux que dix minutes
    /// de parole à redire.
    ///
    /// L'audio est libéré comme après une insertion réussie : on a choisi cette
    /// issue-là, et garder l'autre en réserve laisserait « Réessayer » dans le
    /// menu au-dessus d'un texte déjà écrit.
    func insertPendingPreview() {
        guard let text = pendingPreviewText, isAtRest else { return }
        Task {
            do {
                try await deliver(text)
            } catch {
                // L'insertion elle-même a échoué — plus de curseur, fichier
                // devenu illisible. On garde tout : c'est un autre problème
                // que celui qu'on essayait de contourner, et il se répare.
                if isAtRest { state = .failed(error.localizedDescription) }
                return
            }
            history.add(text)
            pendingAudio = nil
            pendingPreview = nil
            // Une dictée a pu commencer pendant l'insertion : son état n'est
            // pas le nôtre.
            if isAtRest { state = .idle }
        }
    }

    /// Libère l'audio conservé. Appelé quand l'utilisateur renonce.
    func discardPending() {
        guard isAtRest else { return }
        pendingAudio = nil
        pendingPreview = nil
        state = .idle
    }

    var hasPendingAudio: Bool { pendingAudio != nil }

    /// L'aperçu conservé, s'il porte quelque chose d'insérable.
    var pendingPreviewText: String? {
        guard let text = pendingPreview?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }

    var pendingDuration: TimeInterval {
        Double(pendingAudio?.count ?? 0) / AudioRecorder.targetSampleRate
    }

    // MARK: - Échap pendant l'enregistrement

    /// Échap n'est capté que le temps de l'enregistrement : le monopoliser en
    /// permanence casserait son usage normal dans toutes les autres apps.
    // RELAIS — une discussion est ouverte : la page reste, Échap la referme.
    //
    // C'est un état à part, et il fallait le nommer : Caspr est au repos — la
    // touche de dictée relance une dictée dans le même fil — mais une fenêtre
    // attend qu'on en sorte. Sans cet état, rien n'écoutait Échap une fois le
    // cycle terminé.
    //
    // Échap n'est pas pris ici : il suit la fenêtre (cf. `ajusterEchap`).
    private func entrerEnDiscussion() {
        Relais.partage.entrerEnDiscussion()
    }

    private func quitterLaDiscussion() {
        Relais.partage.terminerDiscussion()
    }

    /// RELAIS — met fin à la discussion depuis le menu.
    ///
    /// La sortie qui reste quand Échap n'est pas pris : une discussion qui ne
    /// fait que parler, ou dont on a fermé la fenêtre, n'a rien sous les yeux
    /// pour Échap — et le prendre quand même avalait la frappe dans
    /// l'application où l'on travaillait, en fermant le fil au passage.
    func endDiscussion() {
        guard isAtRest, Relais.partage.enDiscussion else { return }
        quitterLaDiscussion()
    }

    /// Prend ou rend Échap selon ce qui est en cours — la seule décision, prise
    /// à chaque changement d'état ou d'affichage du relais.
    ///
    /// Il était pris et rendu au fil des chemins du cycle, une ligne par
    /// chemin, et l'un d'eux l'oubliait toujours. Pris pendant l'écoute ; rendu
    /// pendant la transcription, qui peut durer des minutes pendant qu'on
    /// travaille ailleurs ; au repos, pris seulement devant une discussion
    /// affichée (cf. `Relais.discussionAffichee`).
    private func ajusterEchap() {
        let voulu = switch state {
        case .recording: true
        case .starting, .processing: false
        case .idle, .failed: Relais.partage.discussionAffichee   // RELAIS —
        }
        if !voulu {
            releaseEscape()
        } else if escapeMonitor == nil {
            captureEscape()
        }
    }

    private func captureEscape() {
        // Rendu d'abord. Un second moniteur enregistré par-dessus le premier
        // se faisait refuser par Carbon, puis la libération de l'ancien
        // désenregistrait la touche : relancer une dictée depuis une
        // discussion laissait Échap sans aucun effet.
        releaseEscape()
        let monitor = HotkeyMonitor { [weak self] in self?.cancel() }
        // Le résultat était jeté : un échec d'enregistrement laissait Échap
        // sans effet, sans que rien ne le signale nulle part.
        if !monitor.register(.cancel) {
            Log.info("Échap indisponible pendant cette dictée — raccourci déjà pris ?")
        }
        escapeMonitor = monitor
    }

    private func releaseEscape() {
        escapeMonitor?.unregister()
        escapeMonitor = nil
    }
}
