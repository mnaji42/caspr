import AppKit
import AVFoundation
import Carbon.HIToolbox
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
    var language: String { Preferences.shared.language }

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

    /// Fichier des notes, mémorisé même quand on écrit au curseur.
    var noteFile: URL? { Preferences.shared.noteFile }

    private let macOS = VoieApple()
    private let injector = TextInjector()
    private let overlay = RecordingOverlay()
    /// La queue commune aux deux voies : insertion, historique, recours.
    private let livraison: Livraison
    private var escapeMonitor: HotkeyMonitor?

    var history: TranscriptionHistory { livraison.history }

    init() {
        self.livraison = Livraison(injector: injector, overlay: overlay)
        overlay.levelProvider = { [weak self] in self?.macOS.niveau ?? 0 }
        overlay.onCancel = { [weak self] in self?.cancel() }
        // La page peut mourir pendant qu'on parle.
        Relais.partage.surPageInterrompue = { [weak self] in self?.pageRelaisInterrompue() }
        // Échap suit ce que le relais montre (cf. `ajusterEchap`).
        Relais.partage.surAffichageChange = { [weak self] in self?.ajusterEchap() }
        // Le module du relais se choisit sur la barre, au moment de parler.
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
        // moteur — son texte ne sert que de recours, et son échec n'a jamais
        // d'effet sur la dictée.
        overlay.onSelectLanguage = { [weak self] code in
            guard let self, Preferences.shared.primaryLanguage != code else { return }
            Preferences.shared.primaryLanguage = code
            if state == .recording, voieDuCycle == .apple {
                macOS.arreterApercu()
                macOS.demarrerApercu(langue: language, barre: overlay)
            }
            refreshOverlay()
            onStateChange?(state)
        }
    }

    /// État courant de la barre.
    private var overlayStatus: RecordingOverlay.Status {
        // La voie de la dictée en cours ; au repos, celle de la suivante.
        switch voieDuCycle ?? Preferences.shared.voie {
        case .apple:
            return RecordingOverlay.Status(
                target: target,
                noteName: noteFile?.lastPathComponent,
                // Sans fichier mémorisé, basculer sur les notes suppose un
                // sélecteur — impossible pendant qu'on parle.
                canPickNote: state != .recording,
                previewEnabled: Preferences.shared.livePreviewEnabled,
                // La langue **effectivement** écoutée. Elle n'était nulle part
                // sur la barre : depuis le multi-langues, dicter en français
                // avec l'anglais actif produit un texte incompréhensible qu'on
                // met longtemps à imputer à la bonne cause.
                languageBadge: Preferences.shared.primary.shortBadge,
                switchableLanguages: Preferences.shared.activeLanguages
                    .map { ($0.code, $0.shortBadge) },
                languageCode: Preferences.shared.primaryLanguage)
        case .chatgpt:
            // La langue n'a aucun sens quand ChatGPT la détecte lui-même, et
            // l'afficher quand même laisserait croire qu'elle agit. Le badge
            // nomme alors la voie à l'œuvre — sans quoi la barre est
            // indiscernable d'une dictée macOS.
            //
            // La pastille porte les modules dès que l'aller-retour est
            // calibré. Sans lui, un seul module est possible, et la barre n'en
            // montre pas : proposer un choix qui échouerait vaut moins que ne
            // rien proposer.
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
            // Une seule chose à la fois sur la page.
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
            // Sauf une fois le message de « Discuter » parti : il n'y a plus
            // rien à abandonner, ChatGPT répond dans le fil. Ni arrêter la
            // page, ni cacher la barre — seulement cesser d'attendre la lecture
            // à haute voix. Le cycle s'achève alors de lui-même, sur la
            // discussion ouverte (cf. `Relais.messageParti`) : il reste le sien.
            if state == .processing, Relais.partage.messageParti {
                fin?.cancel()
                fin = nil
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
    /// ne touchera plus à rien. Rendre la page, l'arrêter, la préparer pour la
    /// suivante, tout se fait donc ici, une fois — jusqu'à quitter la
    /// discussion quand la dictée devait écrire ailleurs, comme
    /// `Relais.apresLivraison` l'aurait fait.
    private func abandonnerLeCycleRelais() {
        cycle &+= 1
        fin?.cancel()
        fin = nil
        voieDuCycle = nil
        // Pendant l'écoute, rien n'est encore figé : c'est le module du
        // moment qui dit où la dictée devait aller.
        let nEcritNullePart = dictee?.nEcritNullePart
            ?? (RelaisCatalogue.courant.sortieParDefaut == .aucune)
        dictee = nil
        Relais.partage.rendreLaMain()
        Relais.partage.interrompre(quitterLaDiscussion: !nEcritNullePart)
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
            switch voie {
            case .apple:
                try macOS.demarrer()
            case .chatgpt:
                // Caspr n'ouvre pas son micro pendant une dictée ChatGPT.
                //
                // Il l'a fait, et c'était nuisible sans être utile. Sans
                // utilité, parce que la transcription vient du micro ouvert par
                // la page : l'audio capté ici n'aurait servi qu'à l'aperçu en
                // direct. Et nuisible, parce que les deux captures ne
                // cohabitent pas — mesuré au niveau crête, 0.000 sur toutes les
                // dictées dès qu'une page ChatGPT existe.
                //
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
            }
            Log.info("enregistrement démarré")
            // Avant d'afficher la barre : elle grise le bouton Notes tant
            // qu'un sélecteur serait impossible, et lit l'état pour le savoir.
            // Échap est pris au passage (cf. `ajusterEchap`).
            state = .recording
            overlay.showRecording(overlayStatus)
            switch voie {
            case .apple:
                macOS.demarrerApercu(langue: language, barre: overlay)
            case .chatgpt:
                // L'aperçu en direct est impossible ici, et c'est définitif :
                // il faudrait un second flux micro, celui-là même qui prive la
                // page de son.
                overlay.setPreviewNotice("ChatGPT transcrit à la fin de la dictée")
            }
            Feedback.recordingStarted()
        } catch is CancellationError {
            // La touche a interrompu l'attente de la page. Elle a pu se mettre
            // à écouter entre-temps : on l'arrête, comme Échap le fait pendant
            // l'écoute. La page est rendue par le `defer`, avant que l'arrêt ne
            // s'exécute : c'est l'arrêt qui range la barre, et il ne le fait
            // qu'une page libre.
            Relais.partage.interrompre()
            overlay.hide()
            Feedback.cancelled()
            state = .idle
        } catch {
            switch voie {
            case .apple:
                break
            case .chatgpt:
                // La barre dit pourquoi, quand la raison tient en une ligne ;
                // elle s'efface sinon, au lieu de rester sur « ChatGPT se
                // prépare… » devant une dictée qui n'aura pas lieu.
                //
                // Et la barre de ChatGPT se range avec elle. Ouverte avant
                // l'écoute, elle restait à flotter au-dessus du travail, sans
                // rapport visible avec le message d'échec. Pas la grande
                // fenêtre, si elle vient de s'ouvrir : c'est là qu'on se
                // connecte.
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

    private static func ms(depuis debut: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - debut) / .milliseconds(1))
    }

    // MARK: - La voie macOS

    private func finirParMacOS() async {
        let samples = macOS.arreter()
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
                 + "moteur \(macOS.version.rawValue)")

        // Un appui-relâché trop bref ne contient rien d'exploitable ; inutile
        // de réveiller le moteur. Un vrai VAD reste à faire (cf. README).
        guard samples.count > Int(AudioRecorder.targetSampleRate * 0.3) else {
            Log.info("trop court, ignoré")
            overlay.hide()
            voieDuCycle = nil
            state = .idle
            return
        }

        await transcrireParMacOS(samples, figer(.apple, module: nil, duree: seconds))
    }

    /// Transcrit puis livre, en gardant l'audio tant que ce n'est pas réussi.
    ///
    /// Une dictée peut durer dix minutes. Perdre cet audio parce que la
    /// transcription a échoué obligerait à tout redire — c'est le pire échec
    /// possible pour cette application. L'audio n'est donc libéré qu'après une
    /// insertion réussie, et `retryLast()` permet de relancer sans reparler.
    ///
    /// `apercuConserve` : ce que l'aperçu en direct avait écrit du même audio,
    /// gardé avec lui comme second recours — celui d'un « Réessayer ». `nil`
    /// pour une dictée qui vient de finir : l'aperçu est alors lu au moment de
    /// l'échec, et non à l'arrêt, parce qu'il finit son analyse après l'arrêt
    /// et peut encore s'allonger pendant la transcription.
    private func transcrireParMacOS(_ samples: [Float], _ dictee: DicteeEnCours,
                                    apercuConserve: String? = nil) async {
        state = .processing
        // Le micro est déjà rendu, à l'arrêt du magnétophone.
        defer {
            voieDuCycle = nil
            self.dictee = nil
        }
        let debut = ContinuousClock.now
        do {
            let text = try await macOS.transcrire(samples, langue: language)
            guard !text.isEmpty else {
                // Le dernier chemin réellement muet de l'application : le
                // moteur répond, sans erreur, avec une chaîne vide. Rien n'est
                // inséré, la barre disparaît, et il ne reste **aucun** indice —
                // ni message, ni entrée d'historique. Vu de l'utilisateur,
                // c'est indiscernable d'un raccourci qui n'aurait rien
                // déclenché, et c'est ce qui a fait chercher une panne de
                // dictée là où le moteur disait simplement n'avoir rien
                // entendu.
                Log.error("le moteur a rendu un texte vide "
                          + "(\(macOS.version.rawValue), \(Self.ms(depuis: debut)) ms)")
                // L'audio est conservé : une version mal configurée rend le
                // vide aussi sûrement qu'un micro coupé, et dans ce cas jeter
                // la dictée oblige à tout redire.
                livraison.conserver(audio: samples,
                                    apercu: apercuConserve ?? macOS.previewText,
                                    echec: "Rien n'a été entendu")
                // `.failed` et non `.idle` : la barre renvoie au menu, et le
                // menu affichait « Prêt ». Envoyer quelqu'un chercher une
                // explication à un endroit qui n'en porte aucune est pire que
                // de se taire.
                state = .failed("Le moteur a répondu sans rien transcrire "
                                + "(\(macOS.version.fullLabel)) — "
                                + "audio conservé, « Réessayer » ci-dessous.")
                return
            }
            overlay.hide()
            try await livraison.livrer(text, vers: dictee.destination,
                                       depuis: dictee.applicationVisee)
            livraison.oublierLeRecours()
            Log.info("transcrit en \(Self.ms(depuis: debut)) ms, \(text.count) caractères")
            state = .idle
        } catch {
            let minutes = Double(samples.count) / AudioRecorder.targetSampleRate / 60
            Log.error("échec de transcription : \(error.localizedDescription) — "
                      + "\(String(format: "%.1f", minutes)) min conservées")
            livraison.conserver(audio: samples,
                                apercu: apercuConserve ?? macOS.previewText)
            state = .failed("\(error.localizedDescription) — audio conservé, "
                            + "« Réessayer » dans le menu.")
        }
    }

    // MARK: - La voie ChatGPT

    private func finirParChatGPT() async {
        // Rien n'a été enregistré de notre côté : ni durée minimale à
        // vérifier, ni audio à conserver pour un « Réessayer » qui n'aurait
        // rien à rejouer. La page a le son, elle seule.
        //
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
        // La phase et le chrono, relus sur l'attente du relais : elle peut
        // durer des minutes, et la touche de dictée en est la sortie — encore
        // faut-il le dire.
        overlay.showProcessing(RelaisAttente.Phase.transcription.libelle,
                               progress: { Relais.partage.avancement })
        let module = RelaisCatalogue.courant
        // Le temps d'écoute de la page, et non depuis l'appui : ce qui précède
        // — attendre qu'elle soit prête — n'a rien à transcrire.
        let dictee = figer(.chatgpt, module: module,
                           duree: Relais.partage.secondesEcoulees)
        Log.info("fin de dictée relais : \(String(format: "%.1f", dictee.duree)) s")
        state = .processing
        let debut = ContinuousClock.now

        // Vrai quand l'échec laisse la transcription dans la page, à récupérer
        // dans la fenêtre qu'on ouvre pour cela.
        var texteLaisseDansLaPage = false
        // Seulement pour le cycle en cours : un cycle abandonné rendrait la
        // page que le suivant vient de prendre, et la rechargerait sous lui.
        defer {
            if dictee.cycle == cycle {
                voieDuCycle = nil
                self.dictee = nil
                Relais.partage.apresLivraison(
                    module, texteLaisseDansLaPage: texteLaisseDansLaPage)
            }
        }
        do {
            let brut = try await Relais.partage.arreterEtLire(secondesDictees: dictee.duree)
            // La seconde passe, quand le module la demande. Elle rend le brut
            // si elle échoue : rien de ce qui a été dit ne se perd.
            let texte = try await Relais.partage.transformer(brut, module: module)
            guard dictee.cycle == cycle else { return }

            // Une dictée qui n'écrit nulle part s'arrête ici.
            //
            // La réponse est déjà à l'écran, dans la page que l'utilisateur a
            // sous les yeux. Rien à insérer, rien à archiver — l'historique est
            // un filet pour retrouver un texte qu'une insertion aurait perdu,
            // et une conversation n'est pas une dictée qu'on range.
            if dictee.nEcritNullePart {
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
                // L'avertissement se suffit, en une ligne : un titre « n'a pas
                // répondu » au-dessus de « n'a pas répondu en 3 min » ne
                // faisait que le répéter.
                if let avertissement = Relais.partage.prendreAvertissement() {
                    overlay.showFailure(avertissement)
                    state = .failed("\(avertissement).")
                } else {
                    overlay.hide()
                    state = .idle
                }
                Relais.partage.entrerEnDiscussion(module)
                return
            }
            guard !texte.isEmpty else {
                // Rien à conserver, donc rien à promettre sous le message : il
                // n'y a pas d'audio de ce côté-ci, et « Réessayer » n'existe
                // pas sur cette voie.
                Log.error("ChatGPT a rendu un texte vide (\(Self.ms(depuis: debut)) ms)")
                overlay.showFailure("Rien n'a été entendu")
                state = .failed("ChatGPT n'a rien transcrit — avez-vous parlé ?")
                return
            }
            Relais.partage.masquerBarre()
            overlay.hide()
            // Rendre le clavier avant d'écrire. Après une discussion, ou si
            // l'on bascule vers un module qui écrit en pleine dictée, la
            // fenêtre du relais est au premier plan : le texte y partirait.
            await Relais.partage.rendreLeClavier()
            try await livraison.livrer(texte, vers: dictee.destination,
                                       depuis: dictee.applicationVisee)
            // Abandonné pendant l'insertion : le texte est écrit, et c'est
            // tout ce qui reste de ce cycle. L'état appartient au suivant.
            guard dictee.cycle == cycle else { return }
            livraison.oublierLeRecours()
            Log.info("transcrit en \(Self.ms(depuis: debut)) ms, \(texte.count) caractères")
            // La transformation a échoué et c'est le brut qui vient d'être
            // inséré : le dire, là où l'on regarde. Sans quoi un texte non
            // remanié passe pour la réponse de ChatGPT, et un quota atteint
            // pour une consigne mal suivie.
            if let avertissement = Relais.partage.prendreAvertissement() {
                overlay.showFailure("Transcription brute insérée", hint: avertissement)
                state = .failed("Transcription brute insérée — \(avertissement).")
            } else {
                state = .idle
            }
        } catch is CancellationError {
            // L'abandon a tout défait (cf. `abandonnerLeCycleRelais`).
            return
        } catch {
            guard dictee.cycle == cycle else { return }
            // Ce qui reste à reprendre : le texte resté dans la fenêtre du
            // relais — sauf quand la page est morte : celle qu'on ouvrirait est
            // neuve, et le texte a disparu avec l'ancienne.
            //
            // Pas de « Réessayer » : il n'y a pas d'audio de ce côté-ci, et
            // proposer un recours qui ne peut pas marcher est pire que de n'en
            // proposer aucun. La barre le promettait pourtant, par la phrase
            // commune aux deux voies ; elle nomme maintenant la fenêtre.
            Log.error("échec de transcription : \(error.localizedDescription)")
            let recuperable = (error as? RelaisPage.Erreur)?.laissePeutEtreLeTexte ?? true
            // Un refus de ChatGPT porte sa raison, un quota par exemple : la
            // barre la montre telle quelle.
            overlay.showFailure(
                (error as? RelaisPage.Erreur)?.raisonCourte ?? "Transcription impossible",
                hint: recuperable ? "Le texte est peut-être encore dans la fenêtre de ChatGPT."
                                  : nil)
            state = .failed(recuperable
                ? "\(error.localizedDescription) — le texte est peut-être encore "
                  + "dans la fenêtre du relais."
                : error.localizedDescription)
            // La fenêtre du relais s'ouvre sur la page : quand la lecture
            // échoue, le texte y est encore, et c'est le seul moyen de le
            // récupérer. Elle redevient donc utilisable au clavier, pour
            // qu'un ⌘C y soit possible. Rien n'est rechargé, et rien ne se
            // collera à la dictée suivante — celle-ci vide la zone avant
            // d'écouter.
            if recuperable {
                texteLaisseDansLaPage = true
                Relais.partage.ouvrirFenetre()
            }
        }
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
    private func chooseNoteFile() {
        var chosen = TargetWriter.frontmostDocument()
        if chosen == nil {
            // Détection impossible : plutôt qu'un sélecteur surgissant sans
            // raison apparente, on dit pourquoi avant de le proposer.
            NSLog("caspr: fichier non identifié — sélecteur")
            chosen = TargetWriter.chooseFile()
        }
        guard let chosen else { return }
        Preferences.shared.noteFile = chosen
        Preferences.shared.destination = .notes
        NSLog("caspr: notes dans %@", chosen.path)
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
                try await livraison.deliver(text, to: target)
            } catch {
                // L'insertion elle-même a échoué — plus de curseur, fichier
                // devenu illisible. On garde tout : c'est un autre problème
                // que celui qu'on essayait de contourner, et il se répare.
                if isAtRest { state = .failed(error.localizedDescription) }
                return
            }
            history.add(text)
            livraison.oublierLeRecours()
            // Une dictée a pu commencer pendant l'insertion : son état n'est
            // pas le nôtre.
            if isAtRest { state = .idle }
        }
    }

    /// Libère l'audio conservé. Appelé quand l'utilisateur renonce.
    func discardPending() {
        guard isAtRest else { return }
        livraison.oublierLeRecours()
        state = .idle
    }

    var hasPendingAudio: Bool { livraison.hasPendingAudio }
    var pendingPreviewText: String? { livraison.pendingPreviewText }
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
    /// Échap n'est capté que quand il a quelque chose à fermer : le monopoliser
    /// en permanence casserait son usage normal dans toutes les autres apps.
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
