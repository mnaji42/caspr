import AppKit
import Combine

/// Caspr vit dans la barre de menus, sans fenêtre ni icône au Dock.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotkey: HotkeyMonitor!
    private var historyHotkey: HotkeyMonitor!
    private var voieHotkey: HotkeyMonitor!
    /// Le raccourci « Changer de voie » a-t-il été accepté par le système ?
    /// Le menu ne l'affiche qu'à cette condition (cf. `registerVoieShortcut`).
    private var voieShortcutActif = false
    /// Le raccourci de la dictée a-t-il été accepté par le système ? Refusé
    /// — pris par l'historique ou une autre application —, plus rien ne
    /// déclenche la dictée, et le menu doit le dire au lieu de l'annoncer.
    private var dictateShortcutActif = false
    private var modifierKey: ModifierKeyMonitor!
    private var reArmTimer: Timer?
    private var controller: DictationController!
    /// La discussion ChatGPT s'ouvre et se ferme sans que l'état de la
    /// dictée change : l'icône, qui la signale, doit suivre quand même.
    private var discussionWatch: AnyCancellable?

    private let preferences = PreferencesWindowController()
    private let onboarding = OnboardingWindowController()
    private let installPrompt = InstallPromptWindowController()
    private let updateNotice = UpdateNotificationWindowController()
    private let uninstaller = UninstallWindowController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tout premier geste, avant tout ce qui lit `Preferences` : les
        // réglages de l'ancien moteur local doivent être traduits avant
        // d'être lus (cf. `Migration.run`).
        Migration.run()
        SpeechAssets.shared.probe(Preferences.shared.selectedLanguages)
        controller = DictationController()
        controller.onStateChange = { [weak self] state in
            self?.render(state)
        }
        discussionWatch = Relais.partage.$enDiscussion
            .removeDuplicates()
            .dropFirst()
            // L'icône : c'est elle qui dit qu'un fil attend quand rien
            // d'autre n'est à l'écran. Dans une tâche : `@Published` prévient
            // avant d'écrire, l'état se relit un tour plus tard.
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.render(self.controller.state)
                }
            }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Un seul menu, rempli à chaque ouverture (cf. `menuNeedsUpdate`).
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render(.idle)

        // L'accueil ne connaît pas la fenêtre des Réglages, et n'a aucune
        // raison de la connaître : son bouton « Personnaliser… » passe par ici.
        onboarding.openSettings = { [weak self] in
            guard let self else { return }
            preferences.show(history: controller.history)
        }

        Relais.partage.prechauffer()

        // Option seule ou le raccourci, selon les réglages. Le raccourci
        // existe avant d'être branché : changer de déclencheur le reprend.
        hotkey = HotkeyMonitor { [weak self] in self?.controller.toggle() }
        brancherLaDictee()

        // Ouvrir le menu au clavier : sans ça, retrouver une transcription
        // suppose de viser une icône de barre de menus à la souris.
        historyHotkey = HotkeyMonitor { [weak self] in self?.openMenu() }
        _ = historyHotkey.register(.history)

        // Après les deux autres, et c'est voulu : macOS ne donne une
        // combinaison qu'à un seul raccourci, le premier arrivé. Une bascule
        // réglée sur la combinaison de la dictée ne doit pas la lui prendre.
        voieHotkey = HotkeyMonitor { [weak self] in self?.changerDeVoie() }
        registerVoieShortcut()

        // Le système désactive un tap dont le processus a trop tardé ; sans ce
        // réarmement la dictée cesserait de répondre sans prévenir. Le même
        // appel crée le tap s'il n'a pas pu l'être au lancement, faute
        // d'accessibilité — c'est le filet de sécurité, à dix secondes près.
        reArmTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard Preferences.shared.triggerKind == .option else { return }
                self?.modifierKey.reArmIfNeeded()
            }
        }

        // Et voici le chemin rapide : pendant l'accueil, quelqu'un vient
        // d'accorder l'accessibilité et va essayer la touche Option dans la
        // seconde. Attendre le prochain tour de l'horloge lui ferait conclure
        // que ça ne marche pas.
        NotificationCenter.default.addObserver(
            forName: .casprAccessibilityGranted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard Preferences.shared.triggerKind == .option else { return }
                self?.modifierKey.reArmIfNeeded()
            }
        }

        // Le tap clavier ne se reconfigure pas tout seul : on le reconstruit
        // dès que le réglage change, pas à la fermeture d'une fenêtre.
        NotificationCenter.default.addObserver(
            forName: .casprTriggerChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPreferences() }
        }

        // La voie peut changer depuis les Réglages, le menu ou le raccourci ;
        // l'icône doit suivre dans les trois cas.
        NotificationCenter.default.addObserver(
            forName: .casprVoieChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.render(self.controller.state)
            }
        }

        Task {
            // Depuis l'image disque, rien d'autre ne s'ouvre tant qu'on n'a pas
            // répondu : configurer des langues et des autorisations sur une
            // copie en lecture seule serait du travail à refaire, puisque les
            // autorisations tiennent au chemin et que ce chemin va disparaître.
            if promptToInstallIfNeeded() { return }
            // Au premier lancement, l'accueil prend la main sur le micro : il
            // l'explique avant de le demander. Les deux en même temps feraient
            // surgir le dialogue système derrière la fenêtre d'accueil, et
            // macOS ne le présente qu'une fois — le manquer vaut refus.
            if Preferences.shared.onboarded {
                await requestMicrophoneIfNeeded()
            } else {
                onboarding.show()
            }
        }

        // Avant tout le reste de l'asynchrone : si l'application tourne depuis
        // l'image disque, rien de ce qui suit ne tiendra.

        // Hors du chemin critique : ça ne conditionne rien de ce lancement-ci,
        // seulement le confort des suivants. Le bundle se lit ici, sur le fil
        // principal ; `xattr` tourne ailleurs.
        let bundle = Uninstall.appBundle
        Task.detached(priority: .utility) { Quarantine.clear(bundle: bundle) }

        // Après le reste : rien ici ne conditionne l'usage de l'application,
        // et le résultat n'arrive qu'une fois le réseau revenu.
        Task {
            await UpdateChecker.shared.checkIfDue()
            // La vérification trouvait une version plus récente et n'en disait
            // rien : il fallait ouvrir les Réglages pour l'apprendre. Une
            // fonction qu'on active pour être prévenu ne prévenait personne.
            updateNotice.showIfNeeded()
            if UpdateChecker.shared.newer != nil { render(controller.state) }
        }
    }

    /// Caspr tourne depuis l'image disque : on ne l'explique pas, on le règle.
    ///
    /// La disposition d'un .dmg est un piège que macOS n'a jamais corrigé. On
    /// glisse l'application dans Applications, et elle reste affichée juste à
    /// côté dans la fenêtre de l'image — donc c'est *elle* qu'on double-clique,
    /// parce qu'elle est là. Rien ne distingue les deux icônes.
    ///
    /// La copie ainsi lancée est en lecture seule, et tout ce qui suit s'en
    /// trouve empoisonné sans jamais se nommer : autorisations attachées à un
    /// chemin temporaire, quarantaine impossible à retirer, mise à jour
    /// intégrée refusée, désinstallation sans rien à retirer. Quatre pannes
    /// diagnostiquées séparément avant qu'on remonte à ce double-clic.
    ///
    /// D'où un dialogue qui *agit* au lieu d'instruire : ouvrir la copie déjà
    /// installée, ou installer et ouvrir s'il n'y en a pas. Un clic, et le
    /// problème n'a plus lieu d'être expliqué.
    /// Rend `true` si la modale a pris la main — auquel cas rien d'autre ne
    /// s'ouvre, et c'est elle qui enchaînera sur l'accueil.
    @discardableResult
    private func promptToInstallIfNeeded() -> Bool {
        guard Uninstall.runsFromReadOnlyVolume else { return false }
        let destination = URL(fileURLWithPath: "/Applications/Caspr.app")
        let installed = FileManager.default.fileExists(atPath: destination.path)
        let volume = sourceVolume

        installPrompt.show(.init(
            alreadyInstalled: installed,
            onPrimary: { [weak self] in
                guard let self else { return }
                if installed {
                    // Éjecter compte autant que réinstaller : c'est la fenêtre
                    // restée ouverte sur l'icône de l'image qui provoque le
                    // double-clic au mauvais endroit.
                    Commande.relancer(destination, ejecter: volume)
                } else {
                    install(to: destination)
                }
            },
            onContinue: { [weak self] in
                guard let self else { return }
                // Le refus n'annule que l'installation, pas la suite : on
                // continue exactement là où on serait allé sans image disque.
                Task { @MainActor in
                    if Preferences.shared.onboarded {
                        await self.requestMicrophoneIfNeeded()
                    } else {
                        self.onboarding.show()
                    }
                }
            }))
        return true
    }

    /// Recopie l'application dans Applications, puis s'y rouvre.
    private func install(to destination: URL) {
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
            // Recopiée depuis une image téléchargée, elle hérite de la
            // quarantaine. La retirer évite que la copie fraîchement installée
            // redemande l'autorisation à chaque ouverture — ici, sur le fil
            // principal, parce qu'elle doit l'être avant de se rouvrir.
            Quarantine.retirer(de: destination)
            // L'image disque part avec : c'est elle qui laissait une fenêtre
            // ouverte sur une icône devenue inutile, et c'est cette icône qui
            // se fait double-cliquer au tour suivant.
            Commande.relancer(destination, ejecter: sourceVolume)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "L'installation n'a pas pu se faire"
            // L'image ne contient plus de raccourci vers Applications : le
            // repli passe donc par la barre latérale du Finder, seul endroit
            // où la cible reste visible.
            failure.informativeText = "\(error.localizedDescription)\n\nGlissez "
                + "Caspr sur « Applications » dans la barre latérale du "
                + "Finder, éjectez l'image, puis ouvrez-le depuis Applications."
            failure.runModal()
        }
    }

    /// Le volume d'où l'on s'exécute, s'il est amovible.
    ///
    /// `nil` sur le disque de démarrage : on n'éjecte pas le Mac.
    private var sourceVolume: URL? {
        let values = try? Uninstall.appBundle.resourceValues(
            forKeys: [.volumeURLKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey])
        guard let volume = values?.volume, volume.path != "/" else { return nil }
        return (values?.volumeIsReadOnly ?? false) ? volume : nil
    }

    /// Demande le micro au lancement plutôt qu'à la première dictée.
    ///
    /// Au lancement l'utilisateur vient d'agir et regarde son écran ; à la
    /// première dictée il est dans une autre app, et un dialogue surgissant
    /// derrière sa fenêtre passe inaperçu. macOS n'affiche ce dialogue qu'une
    /// fois : le manquer enregistre un refus définitif, et l'app n'apparaît
    /// même pas dans la liste des Réglages tant qu'elle n'a rien demandé.
    private func requestMicrophoneIfNeeded() async {
        guard AudioRecorder.microphoneAccess == .undetermined else { return }
        // Par le moniteur, et non en ligne : c'est lui qui sait activer l'app
        // avant le dialogue **et** reprendre le premier plan après. Cette
        // demande-ci s'en passait, et rien ne garantissait qu'elle continue de
        // s'en passer — un chemin de moins qui puisse diverger.
        await PermissionsMonitor.shared.requestMicrophone()
    }

    func applicationWillTerminate(_ notification: Notification) {
        reArmTimer?.invalidate()
        modifierKey?.stop()
        hotkey?.unregister()
        historyHotkey?.unregister()
        voieHotkey?.unregister()
    }

    // MARK: - Barre de menus

    private func render(_ state: DictationController.State) {
        guard let button = statusItem.button else { return }

        let (image, description): (NSImage?, String) = switch state {
        case .idle:
            // Une mise à jour en attente se voit depuis la barre, sans ouvrir
            // quoi que ce soit — c'est l'endroit où le regard passe déjà.
            // Une discussion ChatGPT ouverte passe avant la mise à jour :
            // elle change ce que fera le prochain appui — il poursuivra le
            // fil. Réglée sur « Rien », ou fenêtre fermée, elle n'a pas d'autre
            // témoin à l'écran, et Échap ne la ferme pas (cf.
            // `Relais.discussionAffichee`) : sans ce signe, on ne savait
            // qu'en ouvrant le menu que la dictée suivante partirait dans
            // l'ancienne conversation.
            if Relais.partage.enDiscussion {
                (MenuBarIcon.image(.discussion),
                 "Caspr — discussion ChatGPT ouverte, la prochaine dictée y répond")
            } else if UpdateChecker.shared.newer != nil {
                (MenuBarIcon.image(.update), "Caspr — mise à jour disponible")
            } else if controller.target.isLocked {
                (MenuBarIcon.image(.idle),
                 "Caspr — écrit dans \(controller.target.displayName)")
            } else {
                (MenuBarIcon.image(.idle), "Caspr — prêt")
            }
        case .starting:
            (MenuBarIcon.image(.processing), "Caspr — démarrage")
        case .recording:
            (MenuBarIcon.image(.listening), "Caspr — enregistrement")
        case .processing:
            (MenuBarIcon.image(.processing), "Caspr — transcription")
        // Le fantôme reste, la bulle porte un point d'exclamation rouge : on
        // reconnaît l'application avant de lire son état, ce qu'un triangle
        // d'alerte système ne permettait pas.
        case .failed:
            (MenuBarIcon.image(.error), "Caspr — erreur")
        }

        // La voie ChatGPT se voit dans tous les états, pas seulement au
        // repos : c'est le seul signal permanent que la voix part par le
        // compte ChatGPT plutôt que de rester sur ce Mac.
        let chatgpt = switch Preferences.shared.voie {
        case .chatgpt: true
        case .apple: false
        }
        let marked = chatgpt ? image.map(MenuBarIcon.markedForChatGPT) : image
        let said = chatgpt ? description + " · voie ChatGPT" : description

        marked?.isTemplate = true
        marked?.accessibilityDescription = said
        button.image = marked
        button.toolTip = said

        if case .failed(let message) = state {
            button.toolTip = message
            Log.error("échec : \(message)")
        }
    }

    /// Le menu se remplit à l'ouverture, et seulement là.
    ///
    /// Il était reconstruit d'avance, à chaque changement d'état et après
    /// quelques gestes : tout ce qui changeait autrement y restait figé — l'âge
    /// d'une transcription (« à l'instant » des heures plus tard), un micro
    /// accordé dans les Réglages Système toujours marqué refusé, un historique
    /// effacé depuis les Réglages qu'on pouvait encore réinsérer.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        remplirMenu(menu)
    }

    private func remplirMenu(_ menu: NSMenu) {

        // Configuration inachevée : le menu se réduit à ce qui a du sens.
        //
        // Il s'ouvre quand même, et c'est le point important. Les documents
        // demandaient d'intercepter aussi ce clic pour rouvrir l'accueil —
        // ce serait retirer le seul chemin vers « Quitter », et enfermer
        // quelqu'un qui refuse l'accessibilité en connaissance de cause dans
        // une fenêtre qui revient à chaque tentative de fermer l'application.
        if SetupRecoveryGuard.shouldIntercept {
            let header = NSMenuItem(title: "Caspr — configuration à terminer",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            let resume = NSMenuItem(title: "Terminer la configuration…",
                                    action: #selector(openOnboarding),
                                    keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)

            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quitter Caspr",
                                    action: #selector(NSApplication.terminate(_:)),
                                    keyEquivalent: "q"))
            return
        }

        let status: String = switch controller.state {
        case .idle: "Prêt"
        case .starting: "Démarrage…"
        case .recording: "Enregistrement…"
        case .processing: "Transcription…"
        case .failed(let message): message
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        // Une transcription macOS dure une seconde, sauf quand Apple
        // Intelligence télécharge son modèle : le menu, que l'on ouvre pour
        // comprendre ce qui se passe, offre aussi d'en sortir.
        if controller.transcriptionMacOSEnCours {
            let stop = NSMenuItem(title: "Interrompre la transcription",
                                  action: #selector(interruptTranscription), keyEquivalent: "")
            stop.target = self
            stop.toolTip = "L'enregistrement reste au menu, « Réessayer »."
            menu.addItem(stop)
        }

        // En haut, avant tout le reste. L'icône de la barre ne porte pas de
        // pastille : un point permanent pour un évènement non urgent finit par
        // se faire ignorer, puis détester. Le menu s'ouvre de toute façon
        // souvent — c'est par lui qu'on atteint l'historique et les réglages.
        if let update = UpdateChecker.shared.newer {
            let item = NSMenuItem(title: "↑  Installer la version \(update.version)",
                                  action: #selector(openUpdate), keyEquivalent: "")
            item.target = self
            item.toolTip = "Vous utilisez la \(UpdateChecker.currentVersion). "
                + "Ouvre les Réglages, où un bouton fait tout le reste."
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // N'annoncer que le déclencheur réellement actif : afficher les deux
        // laisserait croire qu'ils marchent tous les deux.
        let prefs = Preferences.shared
        let trigger = switch prefs.triggerKind {
        case .option: prefs.triggerSide.label
        case .shortcut: dictateShortcutActif ? prefs.dictateShortcut.label : "(raccourci refusé)"
        }
        let dictate = NSMenuItem(
            title: "Dicter  \(trigger)",
            action: #selector(triggerDictation), keyEquivalent: "")
        dictate.target = self
        menu.addItem(dictate)

        // La bascule de voie, juste sous la dictée qu'elle commande. Le menu
        // est rempli à l'ouverture : la coche dit toujours ce que fera le
        // prochain appui.
        let voieLabel = voieShortcutActif
            ? (prefs.voieShortcut.map { "  \($0.label)" } ?? "") : ""
        let voie = NSMenuItem(title: "Écrire avec ChatGPT\(voieLabel)",
                              action: #selector(toggleVoie), keyEquivalent: "")
        voie.target = self
        switch prefs.voie {
        case .chatgpt:
            voie.state = .on
            voie.toolTip = "Décocher : la prochaine dictée passe par macOS, hors "
                + "ligne. Une dictée en cours va au bout sur ChatGPT."
        case .apple:
            voie.state = .off
            voie.toolTip = Relais.partage.saitDicter
                ? "Cocher : la prochaine dictée passe par votre compte ChatGPT."
                : "ChatGPT n'est pas encore prêt : ouvre les réglages de la voie "
                  + "pour s'y connecter et apprendre ses boutons."
        }
        menu.addItem(voie)

        // La sortie de la discussion ChatGPT, quand Échap n'est pas pris.
        //
        // Échap ne ferme la discussion que devant sa fenêtre. Une discussion
        // qui ne fait que parler, ou dont on a fermé la fenêtre, reste ouverte
        // — la dictée suivante y répond — et c'est ici qu'on la voit, et
        // qu'on en sort.
        if Relais.partage.enDiscussion, controller.isAtRest {
            let end = NSMenuItem(title: "Terminer la discussion ChatGPT",
                                 action: #selector(endDiscussion), keyEquivalent: "")
            end.target = self
            end.toolTip = "La prochaine dictée repartira d'une conversation neuve."
            menu.addItem(end)
        }

        // Une dictée ratée après plusieurs minutes de parole doit pouvoir être
        // relancée sans tout redire : l'audio est encore là — sur la voie
        // ChatGPT, le son de la page, tant que sa transcription brute n'est
        // pas lue. Lue, c'est elle (cf. `Livraison.garderLeBrut`) : elle passe
        // par la même entrée que l'aperçu de macOS.
        //
        // Au repos seulement : pendant une dictée, ces entrées agissaient
        // sur le recours de la précédente et remettaient l'état au repos
        // par-dessus un enregistrement en cours.
        let preview = controller.pendingPreviewText
        if controller.isAtRest, controller.hasPendingAudio || preview != nil {
            // L'aperçu d'abord, et c'est délibéré : quand la passe finale
            // échoue pour une raison qui tient — un modèle absent, la Dictée
            // éteinte —, réessayer échouera de la même façon, alors que le
            // texte de l'aperçu est déjà écrit. C'est l'issue qui aboutit dans
            // le plus grand nombre de cas, donc celle qu'on lit en premier.
            // Absente quand il n'y a rien à insérer — l'aperçu est coupé, ou
            // l'on a déclenché sans parler.
            if let preview {
                let insert: NSMenuItem
                switch controller.pendingPreviewVoie {
                case .apple:
                    insert = NSMenuItem(title: "Insérer l'aperçu de macOS",
                                        action: #selector(insertPreview), keyEquivalent: "")
                    insert.toolTip = "Écrit ce que macOS avait transcrit pendant que "
                        + "vous parliez, moins soigné que la transcription "
                        + "finale.\n\n\(preview)"
                case .chatgpt where controller.pendingPreviewIsReponse:
                    insert = NSMenuItem(title: "Insérer la réponse de ChatGPT",
                                        action: #selector(insertPreview), keyEquivalent: "")
                    insert.toolTip = "Écrit la réponse de ChatGPT à la dictée "
                        + "annulée.\n\n\(preview)"
                case .chatgpt:
                    insert = NSMenuItem(title: "Insérer la transcription brute de ChatGPT",
                                        action: #selector(insertPreview), keyEquivalent: "")
                    insert.toolTip = "Écrit ce que ChatGPT avait transcrit, avant que "
                        + "la suite de la dictée n'échoue.\n\n\(preview)"
                }
                insert.target = self
                menu.addItem(insert)
            }

            if controller.hasPendingAudio {
                let minutes = controller.pendingDuration / 60
                let label = minutes >= 1
                    ? String(format: "Réessayer avec le moteur (%.1f min conservées)", minutes)
                    : String(format: "Réessayer avec le moteur (%.0f s conservées)",
                             controller.pendingDuration)
                let retry = NSMenuItem(title: label, action: #selector(retry), keyEquivalent: "")
                retry.target = self
                retry.toolTip = "Relance la transcription sur l'enregistrement "
                    + "conservé, avec \(EngineSafetyManager.effectiveEngine.fullLabel)."
                menu.addItem(retry)
            }

            let discard = NSMenuItem(title: controller.hasPendingAudio
                                        ? "Abandonner cet enregistrement"
                                        : "Oublier cette transcription",
                                     action: #selector(discard), keyEquivalent: "")
            discard.target = self
            menu.addItem(discard)
        }
        menu.addItem(.separator())

        // La destination, en lecture seule.
        //
        // Le *choix* du fichier a quitté ce menu pour `DestinationCard`, dans
        // l'onglet Général : un menu de barre qu'on doit parcourir pour
        // retrouver un sélecteur de fichier a cessé d'être un menu.
        //
        // Mais l'**indication** reste, et c'est délibéré — les documents
        // demandaient de retirer la section entière. Verrouillé sur un
        // fichier, le texte n'apparaît plus là où on regarde, et hors dictée
        // rien d'autre ne le signale. C'est le seul filet contre une demi-heure
        // de dictée écrite dans un fichier qu'on avait oublié.
        if let url = controller.target.fileURL {
            let locked = NSMenuItem(title: "▸ Écrit dans \(url.lastPathComponent)",
                                    action: #selector(revealTarget), keyEquivalent: "")
            locked.target = self
            locked.toolTip = "\(url.path)\n\nSe change dans Réglages › Général."
            menu.addItem(locked)
            menu.addItem(.separator())
        }

        // Section toujours présente, même vide : masquée, elle est
        // indécouvrable — on ne cherche pas une fonction dont rien n'indique
        // l'existence.
        let entries = controller.history.entries
        let header = NSMenuItem(
            title: "Transcriptions récentes  \(HotkeyMonitor.Shortcut.history.label)",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if entries.isEmpty {
            let empty = NSMenuItem(
                title: controller.history.isEnabled
                    ? "  aucune pour l'instant"
                    : "  historique désactivé",
                action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in entries {
                let item = NSMenuItem(title: "  \(entry.preview)",
                                      action: #selector(reinsert(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = "\(entry.relativeAge)\n\n\(entry.text)"
                    + (entry.brut == nil ? "" : "\n\n⌥ : la transcription brute de ChatGPT.")
                menu.addItem(item)
                // Ce que ChatGPT avait transcrit avant qu'un module ne le
                // reprenne, sous ⌥ : une ligne de plus par dictée doublerait
                // la liste pour un recours qu'on cherche rarement.
                if let brut = entry.brut {
                    let alternative = NSMenuItem(
                        title: "  Brut : \(TranscriptionHistory.Entry.apercu(de: brut))",
                        action: #selector(reinsert(_:)), keyEquivalent: "")
                    alternative.target = self
                    alternative.representedObject = brut
                    alternative.toolTip = "Ce que ChatGPT avait transcrit, avant la "
                        + "reprise du module.\n\n\(brut)"
                    alternative.keyEquivalentModifierMask = [.option]
                    alternative.isAlternate = true
                    menu.addItem(alternative)
                }
            }

            let clear = NSMenuItem(title: "  Effacer l'historique",
                                   action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        menu.addItem(.separator())

        // Le menu s'arrête aux gestes du quotidien. Tout ce qui se règle une
        // fois puis s'oublie — aperçu, sons, historique, langues — vit dans
        // les Réglages : un menu de barre qu'on doit parcourir pour
        // retrouver une case à cocher a cessé d'être un menu.
        if !Permissions.allGranted {
            let permsItem = NSMenuItem(
                title: Permissions.summary(accessibilityGranted: AXIsProcessTrusted()),
                action: nil, keyEquivalent: "")
            permsItem.isEnabled = false
            menu.addItem(permsItem)

            let mic = NSMenuItem(title: "Ouvrir les réglages Micro…",
                                 action: #selector(openMicSettings), keyEquivalent: "")
            mic.target = self
            menu.addItem(mic)

            let ax = NSMenuItem(title: "Ouvrir les réglages Accessibilité…",
                                action: #selector(openAXSettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: "Réglages…", action: #selector(openPreferences),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // L'accueil contient la seule explication de ce que fait
        // l'accessibilité et de ce qu'implique la licence du modèle. Ne
        // l'afficher qu'une fois reviendrait à cacher ces deux réponses à
        // quiconque n'a pas tout lu le premier jour.
        let welcome = NSMenuItem(title: "Revoir l'accueil…", action: #selector(openOnboarding),
                                 keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

        // Sous les réglages, au-dessus de « Quitter » : là où on cherche une
        // sortie. Une application qui réclame le micro, l'accessibilité et le
        // démarrage automatique doit savoir partir, et le dire.
        let uninstall = NSMenuItem(title: "Désinstaller Caspr…",
                                   action: #selector(openUninstaller), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)

        menu.addItem(NSMenuItem(title: "Quitter Caspr", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    // MARK: - Actions

    @objc private func triggerDictation() {
        // La dictée ne peut rien produire tant que le socle minimal n'est pas
        // posé : plutôt qu'un échec de plus, on rouvre l'écran qui l'explique,
        // là où la personne s'était arrêtée.
        guard !SetupRecoveryGuard.intercept(.dictation, reopening: onboarding) else {
            return
        }
        controller.toggle()
    }

    /// Mène au bouton, pas au navigateur.
    ///
    /// L'installation vit dans les Réglages plutôt que dans ce menu : elle
    /// dure une minute, elle a des étapes, elle peut échouer pour une raison
    /// qui demande une phrase entière. Un élément de menu ne sait rien montrer
    /// de tout ça, et la barre se referme au premier clic.
    @objc private func toggleVoie() {
        changerDeVoie()
    }

    /// Passe à l'autre voie — depuis le menu ou le raccourci.
    ///
    /// Vaut pour la dictée suivante : une dictée en cours garde la voie
    /// qu'elle avait à l'appui (cf. `Preferences.voie`).
    ///
    /// **Vers ChatGPT, seulement s'il sait dicter** — connecté et calibré,
    /// autant qu'on le sache sans interroger la page. Sinon on ouvre les
    /// réglages de la voie au lieu de basculer : c'est là que se font la
    /// connexion et la calibration, et elles demandent une fenêtre et des
    /// clics qu'un élément de menu ou un raccourci ne sait pas mener.
    /// Basculer quand même rendrait une voie qui refuse chaque dictée.
    ///
    /// **Vers macOS, toujours.** C'est la porte de sortie : une page ChatGPT
    /// qui ne répond plus ne doit pas retenir qui veut en sortir. Si le
    /// modèle de la langue manque, les réglages s'ouvrent en plus, pour qu'on
    /// voie ce qui empêchera la prochaine dictée.
    private func changerDeVoie() {
        let prefs = Preferences.shared
        switch prefs.voie {
        case .chatgpt:
            prefs.voie = .apple
            Log.info("voie : macOS")
            if !AppleEngineCard.isValid { showPreferences(on: .voie) }
        case .apple:
            guard Relais.partage.saitDicter else {
                Log.info("voie ChatGPT pas prête — réglages ouverts au lieu de basculer")
                showPreferences(on: .voie)
                return
            }
            prefs.voie = .chatgpt
            Log.info("voie : ChatGPT")
        }
    }

    @objc private func openUpdate() {
        openPreferences()
    }

    @objc private func openOnboarding() {
        onboarding.show()
    }

    @objc private func openUninstaller() {
        uninstaller.show()
    }

    /// Déroule le menu de la barre de menus par programme.
    private func openMenu() {
        statusItem.button?.performClick(nil)
    }

    /// Option maintenue : on ouvre les réglages, et on renonce à la dictée en
    /// cours s'il y en avait une.
    ///
    /// L'audio est jeté, rien n'est transcrit ni inséré : quelqu'un qui tient
    /// la touche deux secondes ne demande pas qu'on écrive ce qu'il vient de
    /// dire, il demande les réglages. Sous ChatGPT, c'est la croix : une
    /// réponse déjà obtenue n'est pas écrite par-dessus les réglages qui
    /// s'ouvrent, mais elle reste au menu.
    private func openSettingsFromHold() {
        controller.cancel()
        Log.info("Option maintenue — ouverture des réglages")
        openPreferences()
    }

    @objc private func openPreferences() {
        showPreferences(on: nil)
    }

    /// Ouvre les réglages, sur un onglet donné ou là où on les avait laissés.
    private func showPreferences(on tab: PreferencesView.Tab?) {
        guard !SetupRecoveryGuard.intercept(.settings, reopening: onboarding) else {
            return
        }
        preferences.show(history: controller.history, on: tab)
    }

    /// Reporte les réglages sur les composants déjà en place.
    private func applyPreferences() {
        // La langue et la destination ne sont plus recopiées : le contrôleur
        // les lit dans les préférences au moment de s'en servir. Reste le
        // déclencheur, que le système tient (cf. `brancherLaDictee`).
        //
        // Le raccourci Carbon est enregistré auprès du système : en changer
        // suppose de rendre l'ancien avant de prendre le nouveau. Les trois
        // sont rendus puis repris dans l'ordre du lancement : la dictée,
        // l'historique, la bascule. Si l'on vient de donner à la dictée la
        // combinaison d'un autre, c'est elle qui la garde — et non l'un ici,
        // l'autre au lancement suivant.
        hotkey.unregister()
        historyHotkey.unregister()
        voieHotkey.unregister()
        brancherLaDictee()
        _ = historyHotkey.register(.history)
        registerVoieShortcut()
    }

    /// Branche le déclencheur de la dictée que les réglages désignent.
    ///
    /// Une seule fois écrit, pour le lancement comme pour un réglage changé :
    /// le guetteur d'Option se construisait aux deux endroits, et seul le
    /// lancement disait au journal qu'il n'avait pas pu naître.
    ///
    /// Option pressée seule, par un tap clavier dont le côté est fixé à la
    /// création : il est reconstruit à chaque fois. Ou le raccourci, par
    /// Carbon, qui n'exige aucune autorisation là où le tap réclame
    /// l'accessibilité — c'est la porte de sortie quand Option est déjà
    /// prise, ou quand on refuse ce droit. L'un exclut l'autre : sous
    /// « touche Option », le raccourci n'est même pas enregistré, et le
    /// laisser actif ferait fonctionner un déclencheur qu'on a écarté.
    private func brancherLaDictee() {
        let prefs = Preferences.shared
        modifierKey?.stop()
        modifierKey = ModifierKeyMonitor(
            side: prefs.triggerSide,
            onTrigger: { [weak self] in self?.controller.toggle() },
            onHold: { [weak self] in self?.openSettingsFromHold() })
        if prefs.triggerKind == .option, !modifierKey.start() {
            Log.error("tap clavier indisponible — accessibilité accordée ?")
        }
        dictateShortcutActif = prefs.triggerKind == .shortcut && hotkey.register(prefs.dictateShortcut)
        if prefs.triggerKind == .shortcut, !dictateShortcutActif {
            Log.error("raccourci \(prefs.dictateShortcut.label) refusé — déjà pris ?")
        }
    }

    /// Le raccourci « Changer de voie », s'il y en a un.
    ///
    /// Le résultat est gardé pour le menu : une combinaison refusée — prise
    /// par la dictée, ou par une autre application — y restait affichée, et
    /// la presser faisait autre chose que changer de voie.
    private func registerVoieShortcut() {
        guard let shortcut = Preferences.shared.voieShortcut else {
            voieShortcutActif = false
            voieHotkey.unregister()
            return
        }
        voieShortcutActif = voieHotkey.register(shortcut)
        if !voieShortcutActif {
            Log.error("raccourci \(shortcut.label) (changer de voie) refusé — déjà pris ?")
        }
    }

    @objc private func revealTarget() {
        guard let url = controller.target.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func retry() {
        controller.retryLast()
    }

    @objc private func interruptTranscription() {
        controller.interrompreLaTranscription()
    }

    @objc private func endDiscussion() {
        controller.endDiscussion()
    }

    /// Écrit ce que l'aperçu avait transcrit, plutôt que de le jeter.
    @objc private func insertPreview() {
        controller.insertPendingPreview()
    }

    @objc private func discard() {
        controller.discardPending()
    }

    @objc private func reinsert(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        Task { await controller.insert(text) }
    }

    @objc private func clearHistory() {
        controller.history.clear()
    }

    @objc private func openMicSettings() {
        Permissions.openMicrophoneSettings()
    }

    @objc private func openAXSettings() {
        // Ouvre le dialogue système si l'app n'a jamais été inscrite, ce qui
        // la fait apparaître dans la liste ; sinon le volet seul suffit.
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        Permissions.openAccessibilitySettings()
    }
}

/// Point d'entrée explicite plutôt que du code top-level : `main.swift`
/// s'exécute hors du main actor, ce qui interdit d'y instancier le delegate.
@main
@MainActor
struct CasprApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory : pas d'icône au Dock, pas de fenêtre — l'app ne vit que
        // dans la barre de menus et ne vole jamais le focus, ce qui est
        // indispensable puisque le texte doit atterrir dans l'application que
        // l'utilisateur a devant lui.
        app.setActivationPolicy(.accessory)
        app.mainMenu = editingMenu()
        // Le delegate est retenu par l'app pour toute la durée du process.
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Le menu principal, réduit aux commandes d'édition.
    ///
    /// ## Pourquoi une application sans menu en a quand même besoin
    ///
    /// Caspr est en `.accessory` : pas de Dock, pas de barre de menus visible.
    /// J'en avais conclu qu'elle n'avait pas besoin de `mainMenu`. C'est faux, et
    /// ça se voyait : **⌘A, ⌘C, ⌘V et ⌘Z ne faisaient rien** dans le moindre
    /// champ de texte de l'application — la zone d'essai de l'accueil, la
    /// recherche de langues, la consigne d'un module du relais.
    ///
    /// macOS ne câble pas ces raccourcis dans les vues : il les route par le
    /// menu principal, en envoyant le sélecteur au premier répondant. Sans
    /// menu, il n'y a aucun chemin, et les touches tombent dans le vide sans
    /// que rien ne le signale.
    ///
    /// Le menu reste invisible — une app accessoire n'affiche pas sa barre —
    /// mais les raccourcis retrouvent leur route. Réduit à l'édition : ni
    /// « Fichier », ni « Fenêtre », ni « Aide », qui n'auraient rien à porter.
    private static func editingMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Édition")

        // `nil` comme cible : le sélecteur descend la chaîne des répondants
        // jusqu'au champ qui a le focus, ce qui est exactement le comportement
        // attendu et ce que fait le menu Édition de n'importe quelle app.
        func add(_ title: String, _ selector: Selector, _ key: String,
                 modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }

        add("Annuler", Selector(("undo:")), "z")
        add("Rétablir", Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add("Couper", #selector(NSText.cut(_:)), "x")
        add("Copier", #selector(NSText.copy(_:)), "c")
        add("Coller", #selector(NSText.paste(_:)), "v")
        add("Tout sélectionner", #selector(NSText.selectAll(_:)), "a")

        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
