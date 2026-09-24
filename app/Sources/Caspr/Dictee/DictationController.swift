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
/// Le cycle ChatGPT est une machine à part, `VoieChatGPT` : elle tient sa
/// phase de l'appui à la livraison et la projette ici (cf. `State`) ; la
/// touche et la croix ne font que lui passer le geste.
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
        // L'état d'une dictée ChatGPT est celui de sa phase.
        chatgpt.surEtat = { [weak self] etat in
            guard let self else { return }
            switch etat {
            case .idle, .failed: voieDuCycle = nil
            case .starting, .recording, .processing: break
            }
            state = etat
        }
        // Échap suit ce que le relais montre (cf. `ajusterEchap`).
        Relais.partage.surAffichageChange = { [weak self] in self?.ajusterEchap() }
        // Le module du relais se choisit sur la barre, au moment de parler.
        overlay.onSelectModule = { [weak self] index in
            guard let self else { return }
            chatgpt.choisirModule(index)
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

    /// Le dernier appui retenu, pour absorber les rebonds.
    ///
    /// Un seul anti-rebond, ici, pour tous les déclencheurs — il n'y en avait
    /// qu'un, dans le guetteur d'Option, et le raccourci n'en avait pas. Un
    /// `CGEventTap` peut recevoir deux `flagsChanged` pour un seul relâchement,
    /// et un double appui nerveux à l'arrêt d'une dictée ChatGPT tomberait
    /// sinon sur la transcription — où la touche renonce à ChatGPT. Deux appuis
    /// volontaires à moins de 400 ms ne correspondent à aucune dictée réelle.
    private var dernierAppui = Date.distantPast

    /// Appelé par le raccourci global : démarre ou termine la dictée.
    func toggle() {
        let maintenant = Date.now
        guard maintenant.timeIntervalSince(dernierAppui) > 0.4 else {
            Log.info("appui rebondi, ignoré")
            return
        }
        dernierAppui = maintenant
        // Sous ChatGPT, c'est la phase qui décide (cf. `RelaisCycle.decider`).
        if voieDuCycle == .chatgpt {
            chatgpt.geste(.touche)
            return
        }
        switch state {
        case .idle, .failed:
            commencer()
        case .recording:
            Task { await finirParMacOS() }
        case .starting, .processing:
            // Sous macOS, ignorer est juste : le traitement dure une seconde,
            // et réappuyer n'est qu'un geste nerveux. Seul le dialogue
            // d'autorisation du micro peut retenir le démarrage, et il se
            // ferme par ses propres boutons.
            break
        }
    }

    /// Ouvre un cycle, depuis le repos.
    private func commencer() {
        // C'est la voie choisie qui décide, pas la touche : les deux
        // s'excluent, et il n'y a qu'un seul déclencheur.
        let voie = Preferences.shared.voie
        voieDuCycle = voie
        let visee = Livraison.applicationDevant()
        switch voie {
        case .chatgpt:
            let refus = chatgpt.commencer(applicationVisee: visee, permissions: { [weak self] in
                await self?.permissionsManquantes() ?? nil
            })
            if let refus {
                voieDuCycle = nil
                state = .failed(refus)
            }
        case .apple:
            macOS.prendreLeMicro()
            applicationVisee = visee
            state = .starting
            Task { await startRecording() }
        }
    }

    /// Échap, la croix de la barre, et Option maintenue — qui, sous ChatGPT,
    /// vaut la croix à toute phase : rien n'est inséré, et ce qui est déjà en
    /// main va au menu (cf. `VoieChatGPT.abandonner`).
    func cancel() {
        if voieDuCycle == .chatgpt {
            chatgpt.geste(.croix)
            return
        }
        switch state {
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
        case .recording:
            // Une transcription macOS dure une seconde : seule l'écoute
            // s'annule.
            macOS.annuler()
            overlay.hide()
            Feedback.cancelled()
            voieDuCycle = nil
            state = .idle
        case .starting, .processing:
            break
        }
    }

    // MARK: - Écouter

    /// Le démarrage d'une dictée macOS.
    private func startRecording() async {
        // Toute sortie qui n'aboutit pas à l'écoute rend le micro et quitte
        // `.starting`. Une ligne par chemin de sortie, c'était la promesse
        // d'en oublier un. Aucun autre cycle ne peut s'ouvrir d'ici là : l'état
        // reste `.starting` jusqu'à cette sortie.
        defer {
            if state == .starting { state = .idle }
            if state != .recording {
                voieDuCycle = nil
                macOS.rendreLeMicro()
            }
        }
        if let refus = await permissionsManquantes() {
            state = .failed(refus)
            return
        }
        do {
            try await macOS.demarrer()
            // Une page gardée pour qu'on y récupère un texte tenait Caspr
            // devant à l'appui : l'application visée a été lue nil. Sa
            // destruction vient de rendre le premier plan (cf.
            // `Relais.libererLaPageGardee`), et celle qui revient devant est
            // celle où l'on travaillait. Nil encore, c'est la zone d'essai de
            // l'accueil, qui garde Caspr devant.
            if applicationVisee == nil {
                applicationVisee = Livraison.applicationDevant()
            }
            Log.info("enregistrement démarré")
            // Avant d'afficher la barre : elle grise le bouton Notes tant
            // qu'un sélecteur serait impossible, et lit l'état pour le savoir.
            // Échap est pris au passage (cf. `ajusterEchap`).
            state = .recording
            overlay.showRecording(overlayStatus)
            macOS.demarrerApercu(langue: language)
            Feedback.recordingStarted()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Le micro et l'accessibilité, qu'exigent les deux voies ; le message
    /// d'échec quand l'un manque.
    private func permissionsManquantes() async -> String? {
        switch AudioRecorder.microphoneAccess {
        case .granted:
            break
        case .undetermined:
            // L'app vit en arrière-plan : sans activation, le dialogue système
            // s'ouvre derrière les autres fenêtres et passe inaperçu.
            NSApp.activate(ignoringOtherApps: true)
            guard await AudioRecorder.requestPermission() else { return "Accès au micro refusé." }
        case .denied:
            Permissions.openMicrophoneSettings()
            return "Micro refusé — ouvrir Réglages › Micro depuis le menu de Caspr."
        }
        guard injector.hasPermission else {
            injector.requestPermission()
            return "Accessibilité requise — voir le menu de Caspr."
        }
        return nil
    }

    /// Ce qui est dit à l'arrêt : la destination du moment.
    private func figer(duree: TimeInterval) -> DicteeEnCours {
        DicteeEnCours(voie: .apple, module: nil, destination: target,
                      applicationVisee: applicationVisee, duree: duree)
    }

    // MARK: - La voie macOS

    private func finirParMacOS() async {
        // Abandonnée entre l'appui et l'exécution de cette tâche : il n'y a
        // plus d'écoute à arrêter.
        guard state == .recording, voieDuCycle == .apple else { return }
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
        await transcrireParMacOS(samples, figer(duree: seconds))
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
    }

    // MARK: - Destination

    /// Insère un texte déjà transcrit — réinsertion depuis l'historique.
    ///
    /// Le menu la propose même pendant une dictée. Son échec ne dit donc
    /// l'état qu'au repos, comme `insertPendingPreview` : posé par-dessus une
    /// écoute, `.failed` passait pour un repos, et l'appui suivant rouvrait
    /// un cycle sur une page ou un micro encore pris — plus rien n'arrêtait
    /// l'écoute avant le redémarrage.
    func insert(_ text: String) async {
        do {
            try await livraison.deliver(text, to: target)
        } catch {
            if isAtRest { state = .failed(error.localizedDescription) }
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
        let figee = figer(duree: livraison.pendingDuration)
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
    var pendingPreviewIsReponse: Bool { livraison.recoursEstLaReponse }
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
