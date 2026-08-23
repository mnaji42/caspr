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
        case recording
        case processing
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?

    /// Mode, langue et lexique sont **lus** dans les préférences, jamais
    /// recopiés.
    ///
    /// Ils l'ont été, et c'était un bug : le contrôleur gardait des copies
    /// rafraîchies à la fermeture de la fenêtre de réglages. Choisir l'anglais
    /// puis dicter sans fermer la fenêtre transcrivait de l'anglais avec le
    /// modèle français — panne parfaitement muette, puisque le moteur rend
    /// simplement un texte vide ou absurde. Toute copie d'un réglage est une
    /// occasion de divergence ; il n'y en a plus.
    var mode: TranscriptionMode {
        get { Preferences.shared.defaultMode }
        set { Preferences.shared.defaultMode = newValue }
    }

    /// `nil` laisse le moteur appliquer son lexique développeur par défaut.
    var lexicon: [String]? { Preferences.shared.effectiveLexicon }

    var language: String { Preferences.shared.language }

    /// Destination du texte : curseur actif, ou fichier de notes.
    ///
    /// Elle n'est lue qu'à la livraison (cf. `deliver`), jamais au démarrage :
    /// basculer en pleine phrase redirige donc la dictée en cours, dans les
    /// deux sens. C'est le comportement attendu — on se rend compte en parlant
    /// que ça ne doit pas aller là.
    ///
    /// **Lue** dans les préférences, jamais recopiée — la même règle que le
    /// mode, la langue et le lexique juste au-dessus, et pour la même raison.
    /// Elle était un état local remis au curseur à chaque lancement, ce qui
    /// obligeait qui travaille au fichier de notes à y revenir tous les matins.
    var target: DictationTarget { Preferences.shared.effectiveTarget }

    /// Fichier des notes, mémorisé même quand on écrit au curseur.
    var noteFile: URL? { Preferences.shared.noteFile }

    /// Le service local. Toujours construit, jamais contacté tant qu'il n'est
    /// pas choisi — c'est `EngineService` qui décide s'il tourne.
    private let localEngine: any SpeechEngine
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

    /// Dernier texte rendu par l'aperçu pour la dictée en cours, et le moteur
    /// qui l'a produit.
    ///
    /// Les deux vont ensemble, et c'est le sujet d'un bug corrigé : le texte
    /// était archivé sous « apple » quel que soit l'aperçu réellement employé,
    /// donc une machine sans Apple Intelligence consignait du `SFSpeechRecognizer`
    /// sous le nom du moteur de macOS 26. Un corpus qui se trompe de moteur ne
    /// répond plus à la seule question pour laquelle il existe.
    private var previewText = ""
    private var previewEngine: EngineChoice?

    /// Seconde passe du moteur pour la collecte. Annulable : elle ne doit
    /// jamais retarder une nouvelle dictée.
    private var secondPassTask: Task<Void, Never>?

    let history = TranscriptionHistory()

    /// Audio d'une dictée dont la transcription a échoué. Conservé en mémoire
    /// vive uniquement, et libéré dès qu'une insertion réussit ou que
    /// l'utilisateur y renonce.
    private var pendingAudio: [Float]?

    /// Le fichier déjà archivé pour cet audio-là, s'il y en a un.
    ///
    /// Depuis que les échecs entrent dans le corpus, une dictée ratée puis
    /// relancée produit deux lignes — ce qui est la vérité — mais elles
    /// décrivent le **même** enregistrement. Sans cette mémoire, « Réessayer »
    /// écrirait une seconde copie de plusieurs mégaoctets, sur la
    /// fonctionnalité même qui existe pour ne rien perdre.
    private var pendingAudioFile: String?

    /// Ce que l'aperçu en direct avait déjà écrit, quand la passe finale a
    /// échoué.
    ///
    /// Le moteur de macOS a transcrit pendant qu'on parlait. Si la passe finale
    /// échoue, ce texte existe, il est bon — moins précis sur le vocabulaire,
    /// puisqu'il n'a pas le lexique — et il était jeté. On proposait donc de
    /// « réessayer » comme seule issue, y compris quand la cause de l'échec ne
    /// s'arrangera pas d'un second essai : un service qui refuse de démarrer
    /// refusera encore.
    ///
    /// Figé ici plutôt que lu dans `previewText` au moment de l'insertion : ce
    /// dernier est remis à zéro au début de la dictée suivante, et l'on peut
    /// très bien reparler avant de décider quoi faire de la précédente.
    private var pendingPreview: String?

    /// Le moteur qui écrit réellement.
    ///
    /// Passe par `EngineSafetyManager` plutôt que de lire la préférence :
    /// celle-ci peut désigner un moteur momentanément incapable d'écrire —
    /// poids en cours de téléchargement, service arrêté pour libérer la
    /// mémoire, modèle supprimé depuis. Le repli est temporaire et n'est jamais
    /// réécrit dans les réglages : le choix de l'utilisateur revient de
    /// lui-même dès que son moteur est de nouveau debout.
    private var writerChoice: EngineChoice { EngineSafetyManager.shared.effectiveEngine }

    private var writer: any SpeechEngine {
        engine(for: writerChoice) ?? localEngine
    }

    private func engine(for choice: EngineChoice) -> (any SpeechEngine)? {
        switch choice {
        case .apple: systemEngine
        case .appleLegacy: legacyEngine
        case .crisperWhisper: localEngine
        }
    }

    init(engine: any SpeechEngine) {
        self.localEngine = engine
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
        // RELAIS — le choix se fait sur la barre, au moment de parler.
        overlay.onSelectModeIndex = { [weak self] index in
            guard let self, RelaisMode.proposes.indices.contains(index) else { return }
            RelaisMode.courant = RelaisMode.proposes[index]
            refreshOverlay()
        }
        overlay.onSelectMode = { [weak self] mode in
            guard let self else { return }
            self.mode = mode
            refreshOverlay()
            onStateChange?(state)
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
        // La collecte se coupe depuis la barre, pas seulement depuis le menu :
        // c'est en dictant qu'on se rend compte qu'on ne veut pas archiver
        // ce qu'on est en train de dire.
        overlay.onToggleCorpus = { [weak self] in
            guard let self else { return }
            Preferences.shared.corpusEnabled.toggle()
            refreshOverlay()
            onStateChange?(state)
        }
    }

    /// État courant de la barre.
    ///
    /// RELAIS — trois réglages n'ont aucun sens quand la dictée passe par
    /// ChatGPT, et les afficher quand même laisse croire qu'ils agissent : les
    /// modes appartiennent à CrisperWhisper, la langue est détectée par le
    /// service lui-même, et rien n'est collecté. Le badge de langue sert alors
    /// à nommer le moteur réellement à l'œuvre — sans quoi la barre est
    /// indiscernable d'une dictée ordinaire.
    private var overlayStatus: RecordingOverlay.Status {
        if relaisEnCours {
            // La pastille porte les modes du relais dès que l'aller-retour
            // est calibré. Sans lui, un seul mode est possible : proposer un
            // choix qui échouerait vaut moins que ne rien proposer.
            let modes = Relais.partage.saitDialoguer ? RelaisMode.proposes : []
            return RecordingOverlay.Status(
                mode: mode,
                target: target,
                noteName: noteFile?.lastPathComponent,
                canPickNote: state != .recording,
                previewEnabled: Preferences.shared.livePreviewEnabled,
                modesAvailable: !modes.isEmpty,
                modeLabels: modes.isEmpty ? nil : modes.map(\.libelle),
                modeIndex: modes.firstIndex(of: RelaisMode.courant) ?? 0,
                corpusEnabled: false,
                corpusKeepsAudio: false,
                languageBadge: "ChatGPT",
                switchableLanguages: [],
                languageCode: Preferences.shared.primaryLanguage)
        }
        return RecordingOverlay.Status(
            mode: mode,
            target: target,
            noteName: noteFile?.lastPathComponent,
            // Sans fichier mémorisé, basculer sur les notes suppose un
            // sélecteur — impossible pendant qu'on parle.
            canPickNote: state != .recording,
            previewEnabled: Preferences.shared.livePreviewEnabled,
            modesAvailable: Preferences.shared.engine.hasModes,
            corpusEnabled: Preferences.shared.corpusEnabled,
            corpusKeepsAudio: Preferences.shared.corpusKeepsAudio,
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

    /// Appelé par le raccourci global : démarre ou termine la dictée.
    // RELAIS — vrai quand le cycle en cours passe par ChatGPT plutôt que par
    // le moteur choisi. Positionné à l'appui, lu jusqu'à la livraison : le
    // geste d'arrêt n'a pas à redire par où l'on était parti.
    private var relaisEnCours = false
    // RELAIS — début de la dictée, faute d'enregistrement pour en déduire la
    // durée. Elle sert à dimensionner l'attente de la transcription.
    private var relaisDebut = Date()
    // RELAIS — le cycle en cours, retenu pour qu'Échap puisse l'interrompre.
    // L'attente d'une transcription ChatGPT dure des minutes : sans prise
    // dessus, la barre restait sur « Transcription… » sans autre issue que de
    // quitter l'application.
    private var relaisTache: Task<Void, Never>?

    func toggle() {
        switch state {
        case .idle, .failed:
            // RELAIS — c'est le mode qui décide, pas la touche : les deux
            // s'excluent, et il n'y a qu'un seul déclencheur.
            relaisEnCours = Relais.partage.actif
            guard !relaisEnCours || Relais.partage.estCalibre else {
                state = .failed("ChatGPT Web Preview est actif mais pas configuré — "
                                + "voir Réglages › Moteur IA.")
                return
            }
            Task { await startRecording() }
        case .recording:
            relaisTache = Task { await finishRecording() }        // RELAIS —
        case .processing:
            break  // cycle en cours, on ignore
        }
    }

    func cancel() {
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
        if relaisEnCours, state == .recording || state == .processing {
            relaisTache?.cancel()
            relaisTache = nil
            relaisEnCours = false
            releaseEscape()
            Task { await Relais.partage.interrompre() }
            overlay.hide()
            Feedback.cancelled()
            state = .idle
            return
        }
        guard state == .recording else { return }
        if relaisEnCours { Task { await Relais.partage.annuler() } }   // RELAIS —
        relaisEnCours = false                                          // RELAIS —
        recorder.cancel()
        stopPreview()
        releaseEscape()
        overlay.hide()
        Feedback.cancelled()
        state = .idle
    }

    // MARK: - Étapes

    private func startRecording() async {
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
            if relaisEnCours {
                relaisDebut = Date()
                // La barre s'ouvre avant l'écoute : on voit ChatGPT démarrer,
                // et la page, enfin à l'écran, cesse d'être différée par le
                // système.
                Relais.partage.afficherBarre()
                try await Relais.partage.demarrer()
            } else {
                try recorder.start()
            }
            Log.info("enregistrement démarré")
            captureEscape()
            // Une collecte encore en cours cède la place : le moteur ne traite
            // qu'une requête à la fois, et la dictée qui commence est
            // prioritaire sur l'archivage de la précédente.
            secondPassTask?.cancel()
            previewText = ""
            previewEngine = nil
            // Avant d'afficher la barre : elle grise le bouton Notes tant
            // qu'un sélecteur serait impossible, et lit l'état pour le savoir.
            state = .recording
            overlay.showRecording(overlayStatus)
            if relaisEnCours {                                     // RELAIS —
                overlay.setPreviewNotice("ChatGPT transcrit à la fin de la dictée")
            } else {
                startPreview()
            }
            Feedback.recordingStarted()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func finishRecording() async {
        // RELAIS — rien n'a été enregistré de notre côté : ni durée minimale à
        // vérifier, ni audio à conserver pour un « Réessayer » qui n'aurait
        // rien à rejouer. La page a le son, elle seule.
        if relaisEnCours {
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
            // clic délibéré au bon endroit.
            releaseEscape()
            Feedback.recordingStopped()
            overlay.showProcessing()
            Log.info("fin de dictée relais : "
                     + "\(String(format: "%.1f", Date().timeIntervalSince(relaisDebut))) s")
            await transcribeAndInject([])
            return
        }
        let samples = recorder.stop()
        stopPreview()
        releaseEscape()
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
                 + "moteur \(Preferences.shared.engine.rawValue)")

        // Un appui-relâché trop bref ne contient rien d'exploitable ; inutile
        // de réveiller le moteur. Un vrai VAD reste à faire (cf. README).
        guard samples.count > Int(AudioRecorder.targetSampleRate * 0.3) else {
            Log.info("trop court, ignoré")
            overlay.hide()
            state = .idle
            return
        }

        await transcribeAndInject(samples)
    }

    /// Transcrit puis insère, en gardant l'audio tant que ce n'est pas réussi.
    ///
    /// Une dictée peut durer dix minutes. Perdre cet audio parce que le moteur
    /// était arrêté ou a échoué obligerait à tout redire — c'est le pire échec
    /// possible pour cette application. L'audio n'est donc libéré qu'après une
    /// insertion réussie, et `retryLast()` permet de relancer sans reparler.
    private func transcribeAndInject(_ samples: [Float]) async {
        state = .processing
        let used = mode
        // RELAIS — le relais se conforme au protocole des moteurs, donc tout ce
        // qui suit (insertion, historique, échecs, barre) marche sans le savoir.
        let parRelais = relaisEnCours
        defer { relaisEnCours = false }
        let moteur: any SpeechEngine = parRelais ? RelaisEngine() : writer
        do {
            let result = try await moteur.transcribe(
                TranscriptionRequest(samples: samples, mode: used,
                                     language: language, lexicon: lexicon))

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
                          + "(\(Preferences.shared.engine.rawValue), "
                          + "\(Int(result.latency.wallMs)) ms)")
                overlay.showFailure("Rien n'a été entendu",
                                    hint: Self.rescueHint(preview: previewText))
                // L'audio est conservé, contrairement à avant. Un moteur mal
                // configuré rend le vide aussi sûrement qu'un micro coupé, et
                // dans ce cas jeter la dictée oblige à tout redire — ce que
                // cette application s'interdit partout ailleurs.
                // RELAIS — rien à conserver ni à archiver : il n'y a pas
                // d'audio de notre côté, « Réessayer » rejouerait le vide, et
                // le corpus n'a que faire d'une dictée qu'un service tiers
                // n'a pas entendue.
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
                      + "(\(Preferences.shared.engine.fullLabel)) — "
                      + "audio conservé, « Réessayer » ci-dessous.")
                // Archivé comme le reste : c'est l'observation la plus utile
                // du corpus, et c'était la seule qu'il jetait.
                if !parRelais {                                    // RELAIS —
                    collect(samples: samples, primary: result, mode: used,
                            outcome: .empty)
                }
                return
            }
            if parRelais {                                     // RELAIS —
                releaseEscape()
                Relais.partage.masquerBarre()
            }
            overlay.hide()
            // L'application au premier plan au moment d'insérer. L'insertion
            // par accessibilité vise l'élément focalisé de cette
            // application-là : si c'est Caspr, le texte part dans une de nos
            // propres fenêtres et disparaît sans qu'aucune erreur ne soit
            // levée. C'était indiagnosticable de l'extérieur.
            let devant = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            Log.info("insertion vers \(devant)")
            try await deliver(text)
            history.add(text, mode: used)
            pendingAudio = nil
            pendingAudioFile = nil
            pendingPreview = nil
            // Ce moteur vient de prouver qu'il sait écrire ici : c'est sur lui
            // que le repli se rabattra si un autre choix échoue plus tard. La
            // preuve est l'insertion réussie, pas la disponibilité annoncée —
            // un moteur qui répond « disponible » peut encore échouer à la
            // première phrase.
            // RELAIS — le repli ne doit rien apprendre d'un moteur qui n'est
            // pas un choix de l'utilisateur, et le corpus ne collecte pas ce
            // qu'un service tiers a transcrit.
            if !parRelais { EngineSafetyManager.shared.confirmWorking(writerChoice) }
            Log.info("transcrit en \(Int(result.latency.wallMs)) ms, \(text.count) caractères")
            state = .idle
            // Après l'insertion, jamais avant : la collecte ne doit rien
            // coûter au temps que l'utilisateur attend.
            if !parRelais {                                        // RELAIS —
                collect(samples: samples, primary: result, mode: used,
                        outcome: .inserted)
            }
        } catch is CancellationError {                             // RELAIS —
            releaseEscape()
            return
        } catch {
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
            overlay.showFailure(Self.shortReason(for: error),
                                hint: Self.rescueHint(preview: previewText))
            state = .failed(parRelais
                ? "\(error.localizedDescription) — le texte est peut-être encore "
                  + "dans la fenêtre du relais."
                : "\(error.localizedDescription) — audio conservé, « Réessayer » dans le menu.")
            // Les autres moteurs tournent quand même : savoir que macOS a
            // écrit la phrase pendant que CrisperWhisper échouait est
            // exactement ce qu'on vient chercher dans le corpus.
            // RELAIS — la barre reste, et s'agrandit : quand la lecture
            // échoue, le texte est encore dans la page, et c'est le seul moyen
            // de le récupérer. Elle redevient donc utilisable au clavier, pour
            // qu'un ⌘C y soit possible. Rien n'est rechargé, et rien ne se
            // collera à la dictée suivante — celle-ci vide la zone avant
            // d'écouter.
            if parRelais {
                releaseEscape()
                Relais.partage.ouvrirFenetre()
            } else {
                collect(samples: samples, primary: nil, mode: used,
                        outcome: .failed, failure: error.localizedDescription)
            }
        }
    }

    /// La raison, en une ligne qui tient dans la barre.
    ///
    /// Le message complet part dans le menu ; celui-ci doit se lire d'un coup
    /// d'œil, pendant les cinq secondes où la barre reste affichée. Le cas du
    /// modèle en cours de chargement est distingué parce que c'est le seul où
    /// il suffit d'attendre, et que le dire évite de chercher une panne.
    private static func shortReason(for error: Error) -> String {
        if case SpeechEngineError.unavailable = error, EngineService.isInstalled {
            if EngineService.isAnswering { return "Moteur injoignable — réessayez" }
            // « Réessayez dans un instant » sur un service qui se relance en
            // boucle laisse attendre indéfiniment quelque chose qui n'arrivera
            // pas. Quand le journal porte une trace, c'est une panne, et la
            // barre doit le dire même si le détail complet part dans le menu.
            return EngineService.recentFailure != nil
                ? "CrisperWhisper n'a pas pu démarrer — voir le menu"
                : "CrisperWhisper charge son modèle — réessayez dans un instant"
        }
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

    // MARK: - Collecte

    /// Archive la dictée, puis la complète avec les autres moteurs demandés.
    ///
    /// Le texte du moteur système est gratuit quand l'aperçu tournait : il a
    /// été produit pendant que l'utilisateur parlait. Tout le reste demande
    /// une passe supplémentaire, lancée **après** insertion.
    /// - Parameters:
    ///   - primary: ce que le moteur d'écriture a rendu, ou `nil` s'il a
    ///     échoué avant de rendre quoi que ce soit.
    ///   - outcome: l'issue réelle. Un échec s'archive comme un succès, avec
    ///     les autres moteurs lancés en seconde passe — c'est précisément là
    ///     que la comparaison devient tranchante.
    private func collect(samples: [Float], primary: TranscriptionResult?,
                         mode used: TranscriptionMode,
                         outcome: CorpusEntry.Outcome,
                         failure: String? = nil) {
        let prefs = Preferences.shared
        guard prefs.corpusEnabled else { return }

        let id = Corpus.makeIdentifier()
        // Le moteur qui a **réellement** écrit, pas celui qui est coché : un
        // repli silencieux archivé sous le nom du moteur demandé rendrait le
        // corpus menteur sur la seule chose qu'il sert à mesurer.
        let choice = writerChoice
        var entry = CorpusEntry(
            id: id,
            date: Date(),
            durationSeconds: Double(samples.count) / AudioRecorder.targetSampleRate,
            // Code court ici, locale complète à côté. Cf. `CorpusEntry`.
            language: Locale(identifier: language).language.languageCode?.identifier
                ?? language,
            locale: language,
            appVersion: UpdateChecker.currentVersion,
            destination: target.isLocked ? "notes" : "curseur",
            lexicon: choice.honoursLexicon ? lexicon : nil,
            transcriptions: [],
            storedOutcome: outcome,
            failure: failure)

        if prefs.corpusKeepsAudio {
            // Réutilisé quand l'utilisateur relance la même dictée depuis le
            // menu : une tentative ratée puis réussie fait deux lignes, ce qui
            // est la vérité, mais elles décrivent le **même** audio. L'écrire
            // deux fois coûterait deux mégaoctets par minute pour un doublon
            // exact, sur la fonctionnalité même qui existe pour ne rien perdre.
            if let existing = pendingAudioFile {
                entry.audioFile = existing
            } else {
                entry.audioFile = Corpus.shared.writeAudio(samples, id: id)
                if outcome != .inserted { pendingAudioFile = entry.audioFile }
            }
        }

        // Figé ici, et pas à l'archivage : l'archivage a lieu plusieurs
        // centaines de millisecondes plus tard, et si l'utilisateur réenchaîne
        // une dictée d'ici là, `previewText` a déjà été réinitialisé puis
        // rempli par la nouvelle. Constaté dans le corpus — une entrée portait
        // comme texte Apple le début de la dictée suivante. À ce point-ci la
        // reconnaissance système est finalisée depuis longtemps : elle l'était
        // avant même que la transcription ne rende la main.
        //
        // Le moteur de l'aperçu est figé avec son texte, pour la même raison et
        // parce qu'il n'est pas devinable : il dépend du moteur d'écriture et
        // de ce que la machine sait faire.
        let preview = previewText
        let previewEngine = previewEngine
        let pending = prefs.enginesToCollect().subtracting([choice])
        secondPassTask = Task { [weak self] in
            await self?.completeAndArchive(entry, samples: samples,
                                           primary: primary, insertedMode: used,
                                           writer: choice, pending: pending,
                                           preview: preview,
                                           previewEngine: previewEngine)
        }
    }

    /// Complète l'archive avec ce qui manque, puis écrit la ligne.
    ///
    /// Chaque moteur supplémentaire occupe la machine : ces passes sont donc
    /// lancées après insertion, et abandonnées dès qu'une nouvelle dictée
    /// démarre. Ce qui n'a pas été produit est **consigné** dans `skipped` —
    /// une transcription manquante ne doit jamais être confondue avec un
    /// moteur qu'on n'avait pas coché.
    private func completeAndArchive(_ entry: CorpusEntry, samples: [Float],
                                    primary: TranscriptionResult?,
                                    insertedMode: TranscriptionMode,
                                    writer choice: EngineChoice,
                                    pending: Set<EngineChoice>,
                                    preview: String,
                                    previewEngine: EngineChoice?) async {
        var entry = entry
        let identity = await (engine(for: choice)?.identity
                              ?? EngineIdentity(engine: choice.rawValue, model: nil))

        // Rien à consigner quand le moteur a échoué avant de rendre un
        // résultat : l'entrée n'aura que les transcriptions des autres, et
        // `failure` dit pourquoi celle-ci manque.
        if let primary {
            entry.transcriptions.append(CorpusTranscription(
                engine: identity.engine, model: identity.model,
                mode: choice.hasModes ? insertedMode.rawValue : nil,
                text: primary.text, latencyMs: primary.latency.wallMs,
                // Une chaîne vide n'a rien inséré, et le prétendre fausserait
                // toute analyse qui cherche « ce que l'utilisateur a vu ».
                inserted: entry.outcome == .inserted))
        }

        // Le second mode du moteur qui vient d'écrire, quand il en a deux.
        var remaining: [(EngineChoice, TranscriptionMode?)] = []
        if choice.hasModes {
            let other: TranscriptionMode = insertedMode == .intended ? .verbatim : .intended
            remaining.append((choice, other))
        }
        for engine in pending.sorted(by: { $0.rawValue < $1.rawValue }) {
            remaining.append((engine, engine.hasModes ? .intended : nil))
        }

        // L'aperçu a déjà transcrit avec l'un des moteurs de macOS : on ne le
        // refait pas tourner pour rien. Lequel, on ne le devine pas — il suit
        // le moteur d'écriture et ce que la machine sait faire — d'où
        // `previewEngine`, figé avec le texte à la source.
        if !preview.isEmpty, let previewEngine,
           let index = remaining.firstIndex(where: { $0.0 == previewEngine }) {
            // La locale, pas `nil`. Ce raccourci écrivait « apple » sans rien
            // d'autre, alors que la seconde passe, elle, enregistre bien
            // `fr-FR` : deux lignes du même moteur n'étaient donc pas
            // comparables selon qu'un aperçu avait tourné ou non. Or c'est
            // exactement le champ dont une analyse ultérieure a besoin —
            // arbitrer CrisperWhisper contre macOS suppose de savoir sur
            // quelle langue chaque texte a été produit.
            let identity = await engine(for: previewEngine)?.identity
            entry.transcriptions.append(CorpusTranscription(
                engine: identity?.engine ?? previewEngine.rawValue,
                model: identity?.model, mode: nil,
                text: preview, latencyMs: nil, inserted: false))
            remaining.remove(at: index)
        }

        for (choice, mode) in remaining {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, state == .idle else {
                entry.skipped.append("\(choice.rawValue): dictée enchaînée")
                continue
            }
            // Demandé avant d'essayer, et mesuré : `legacyEngine` existe
            // toujours, même là où la Dictée n'a aucun modèle. Sans ce test on
            // apprendrait l'indisponibilité par une exception, après avoir fait
            // attendre la machine — et la raison archivée serait un message
            // d'erreur au lieu du fait.
            guard choice.isAvailable(for: entry.requestLocale),
                  let engine = engine(for: choice) else {
                entry.skipped.append("\(choice.rawValue): indisponible")
                continue
            }
            do {
                let result = try await engine.transcribe(TranscriptionRequest(
                    samples: samples, mode: mode ?? .intended,
                    language: entry.requestLocale,
                    lexicon: choice.honoursLexicon ? entry.lexicon : nil))
                let identity = await engine.identity
                entry.transcriptions.append(CorpusTranscription(
                    engine: identity.engine, model: identity.model,
                    mode: mode?.rawValue, text: result.text,
                    latencyMs: result.latency.wallMs, inserted: false))
            } catch {
                NSLog("caspr: corpus — %@ a échoué : %@", choice.rawValue,
                      error.localizedDescription)
                entry.skipped.append("\(choice.rawValue): \(error.localizedDescription)")
            }
        }

        Corpus.shared.append(entry)
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
        // L'aperçu a **sa** version de macOS, réglée dans l'onglet Dictée.
        // Elle se déduisait de celle du moteur d'écriture : le réglage existait
        // dans l'interface et ne pilotait rien ici, si bien que choisir Dictée
        // pour l'aperçu n'avait aucun effet sur ce qui s'affichait pendant
        // qu'on parlait. Cf. `SpeechPreview.engine`.
        guard let made = SpeechPreview.make(
            using: Preferences.shared.liveEngineTechnology, for: language,
            onText: { [weak self] text in
                guard let self else { return }
                if previewText.isEmpty, !text.isEmpty {
                    Log.info("aperçu : premier texte reçu")
                }
                // Retenu pour la collecte : c'est la transcription d'un moteur
                // de macOS sur exactement le même audio.
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
        self.preview = made.preview
        previewEngine = made.engine
        recorder.onBuffer = { [weak preview = made.preview] buffer in
            preview?.append(buffer)
        }
        // Détaché : le premier lancement peut télécharger le modèle système,
        // et la dictée ne doit pas attendre.
        Task { await made.preview.start(language: language) }
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

    /// Relance la transcription de l'audio conservé après un échec.
    func retryLast() {
        guard let pendingAudio, state != .processing else { return }
        Task { await transcribeAndInject(pendingAudio) }
    }

    /// Insère ce que l'aperçu en direct avait écrit, faute de mieux.
    ///
    /// La seconde issue d'un échec, et souvent la bonne : quand le service
    /// local refuse de démarrer, réessayer échouera pareil, alors que le texte
    /// de macOS est là et se suffit à lui-même. Moins précis sur le vocabulaire
    /// — l'aperçu n'a pas le lexique — mais un texte imparfait vaut mieux que
    /// dix minutes de parole à redire.
    ///
    /// L'audio est libéré comme après une insertion réussie : on a choisi cette
    /// issue-là, et garder l'autre en réserve laisserait « Réessayer » dans le
    /// menu au-dessus d'un texte déjà écrit.
    func insertPendingPreview() {
        guard let text = pendingPreviewText else { return }
        Task {
            do {
                try await deliver(text)
            } catch {
                // L'insertion elle-même a échoué — plus de curseur, fichier
                // devenu illisible. On garde tout : c'est un autre problème
                // que celui qu'on essayait de contourner, et il se répare.
                state = .failed(error.localizedDescription)
                return
            }
            history.add(text, mode: mode)
            pendingAudio = nil
            pendingAudioFile = nil
            pendingPreview = nil
            state = .idle
        }
    }

    /// Libère l'audio conservé. Appelé quand l'utilisateur renonce.
    func discardPending() {
        pendingAudio = nil
        pendingAudioFile = nil
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
    private func captureEscape() {
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
