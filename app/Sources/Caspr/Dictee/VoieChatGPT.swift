import AppKit
import CasprCore

/// La voie ChatGPT : la page écoute, ChatGPT transcrit, et le module choisi
/// remanie le texte ou y répond — la machine d'une dictée, en marche.
///
/// Le pendant de `VoieApple`, et rien ne s'y ressemble. Caspr n'ouvre pas son
/// micro : la page a le son, elle seule. L'attente dure des minutes au lieu
/// d'une seconde, la dictée peut ne rien écrire du tout, et quand elle échoue
/// son texte est peut-être encore dans la page.
///
/// Une phase (`phase`), écrite à un seul endroit (`entrer`) ; une tâche
/// (`moteur`) qui déroule la dictée de l'appui à la livraison ; deux gestes
/// (`geste`), que la table de `RelaisCycle` décide. Et un numéro
/// (`generation`), vérifié après chaque attente : un cycle abandonné finit de
/// se dérouler après coup — l'annulation se constate à l'attente suivante —,
/// et ses effets tardifs rendaient la page que le suivant venait de prendre,
/// la rechargeaient sous lui, posaient leur état par-dessus le sien.
@MainActor
final class VoieChatGPT {
    private let relais = Relais.partage
    private let overlay: RecordingOverlay
    private let livraison: Livraison

    /// L'état commun, projeté par chaque phase (cf. `entrer`).
    var surEtat: (DictationController.State) -> Void = { _ in }

    /// La phase de la dictée en cours ; `nil` hors d'une dictée ChatGPT.
    private(set) var phase: RelaisPhase?
    /// Le début de la phase : le journal dit ce que chacune a coûté, et
    /// celle de l'écoute fait la durée parlée.
    private var depuis = Date.now
    /// Le chrono de la barre : depuis l'appui, puis depuis l'arrêt.
    private var chrono = Date.now

    private var moteur: Task<Void, Never>?
    private var generation = 0
    /// L'écoute attend la touche : la reprendre, c'est arrêter.
    private var arret: CheckedContinuation<Void, Never>?
    private var arretDemande = false
    /// « ChatGPT se prépare… » est déjà à l'écran : le redire ferait repartir
    /// la barre, alors que le chrono part de l'appui et continue.
    private var annoncee = false

    private var scenario: RelaisDictee?
    private var applicationVisee: NSRunningApplication?
    /// La dictée, figée à l'arrêt de l'écoute ; `nil` avant.
    private var dictee: DicteeEnCours?

    init(overlay: RecordingOverlay, livraison: Livraison) {
        self.overlay = overlay
        self.livraison = livraison
        // La page peut mourir pendant qu'on parle.
        relais.surPageInterrompue = { [weak self] in self?.pageInterrompue() }
    }

    /// Ce que la barre montre sous cette voie.
    ///
    /// La langue n'a aucun sens quand ChatGPT la détecte lui-même, et
    /// l'afficher quand même laisserait croire qu'elle agit. Le badge nomme
    /// alors la voie à l'œuvre — sans quoi la barre est indiscernable d'une
    /// dictée macOS.
    ///
    /// La pastille porte les modules dès que l'aller-retour est calibré. Sans
    /// lui, un seul module est possible, et la barre n'en montre pas : proposer
    /// un choix qui échouerait vaut moins que ne rien proposer.
    func statutDeLaBarre(peutChoisirLaNote: Bool) -> RecordingOverlay.Status {
        let modules = RelaisCatalogue.proposes
        let courant = RelaisCatalogue.courant
        return RecordingOverlay.Status(
            target: Preferences.shared.effectiveTarget,
            noteName: Preferences.shared.noteFile?.lastPathComponent,
            canPickNote: peutChoisirLaNote,
            previewEnabled: Preferences.shared.livePreviewEnabled,
            moduleLabels: modules.map(\.nom),
            moduleIndex: modules.firstIndex(of: courant) ?? 0,
            destinationImposee: courant.sorties == [.aucune]
                ? "Réponse à l'écran" : nil,
            languageBadge: "ChatGPT",
            switchableLanguages: [],
            languageCode: Preferences.shared.primaryLanguage)
    }

    /// Le module choisi sur la barre, au moment de parler.
    func choisirModule(_ index: Int) {
        let modules = RelaisCatalogue.proposes
        guard modules.indices.contains(index) else { return }
        RelaisCatalogue.courant = modules[index]
        // L'affichage appartient au module : changer de module en pleine
        // dictée doit le faire suivre. C'était le seul réglage figé à l'appui
        // de la touche, et c'est le cas courant — on change d'avis parce qu'on
        // a déjà commencé à parler.
        if phase == .ecoute { relais.afficherBarre(module: modules[index]) }
    }

    // MARK: - La phase

    /// Le seul endroit où la phase change : le journal, l'état commun — et
    /// Échap avec lui (cf. `DictationController.ajusterEchap`) —,
    /// l'occupation de la page, la barre.
    ///
    /// `echec` : le message du menu, quand la dictée finit sur un échec.
    private func entrer(_ nouvelle: RelaisPhase?, echec: String? = nil) {
        let avant = phase
        if nouvelle != avant {
            Log.info("relais : \(avant?.rawValue ?? "repos") → \(nouvelle?.rawValue ?? "repos") "
                     + "après \(String(format: "%.1f", Date.now.timeIntervalSince(depuis))) s")
            phase = nouvelle
            depuis = .now
        }
        if relais.dicteeEnCours != (nouvelle != nil) { relais.dicteeEnCours = nouvelle != nil }
        // L'attente se montre dès l'arrêt : sa phase, puis le chrono et la
        // sortie dès dix secondes — elle peut durer des minutes, et la touche
        // de dictée en est la sortie, encore faut-il le dire. Les phases
        // suivantes se lisent sur la même barre (cf. `avancement`).
        if nouvelle == .transcription, avant == .ecoute {
            chrono = .now
            montrerLAttente()
        }
        let etat: DictationController.State = switch nouvelle {
        case .demarrage?: .starting
        case .ecoute?: .recording
        case nil: echec.map { .failed($0) } ?? .idle
        default: .processing
        }
        surEtat(etat)
    }

    /// La phase suivante du cycle `g`, s'il est encore le sien ; faux sinon.
    ///
    /// Un appel à la page peut revenir juste avant l'abandon : le cycle mort
    /// reprend alors la main une fois encore, et écrivait sa phase par-dessus
    /// le repos — ou par-dessus la dictée suivante.
    private func avancer(_ g: Int, _ nouvelle: RelaisPhase) -> Bool {
        guard g == generation else { return false }
        entrer(nouvelle)
        return true
    }

    private func montrerLAttente() {
        overlay.showProcessing(phase?.libelle ?? "", progress: { [weak self] in self?.avancement })
    }

    /// Ce que la barre affiche pendant une attente, relu deux fois par
    /// seconde ; `nil` quand la phase n'en montre pas.
    private var avancement: RecordingOverlay.ProcessingProgress? {
        guard let libelle = phase?.libelle else { return nil }
        return .init(label: libelle, elapsed: Date.now.timeIntervalSince(chrono),
                     exitHint: phase?.sortie)
    }

    // MARK: - Les gestes

    /// La touche de dictée, ou la croix — et Échap pendant l'écoute —,
    /// pendant une dictée ChatGPT. Décidé sur-le-champ : aucune de ces
    /// sorties n'attend qu'un appel à la page rende la main.
    func geste(_ geste: RelaisCycle.Geste) {
        guard let phase else { return }
        let decision = RelaisCycle.decider(geste, en: phase)
        Log.info("relais : \(geste.rawValue) en \(phase.rawValue) — \(decision.rawValue)")
        switch decision {
        case .arreter:
            // Deux appuis dans le même tour ne font qu'un arrêt : le second
            // trouve l'écoute déjà reprise.
            arretDemande = true
            reprendreLArret()
        case .cesserDAttendre:
            // Pas en annulant la tâche : elle a encore à ouvrir la discussion
            // ou à insérer le texte, et une tâche annulée n'insère rien.
            scenario?.cesserDAttendreLaLecture()
        case .annulerLeDemarrage:
            abandonner(ecouteQuiDemarre: true)
        case .replier, .annuler:
            abandonner(ecouteQuiDemarre: false)
        }
    }

    /// Abandonne la dictée, et fait à sa place ce qu'elle ne fera plus.
    ///
    /// Le cycle cesse d'être le cycle en cours avant tout le reste : ce qui
    /// s'en déroulera encore ne touchera plus à rien. La page est arrêtée puis
    /// préparée, jusqu'à quitter la discussion quand la dictée devait écrire
    /// ailleurs, comme sa fin l'aurait fait (cf. `Relais.finirLeCycle`).
    private func abandonner(ecouteQuiDemarre: Bool) {
        // Pendant l'écoute, rien n'est encore figé : c'est le module du
        // moment qui dit où la dictée devait aller.
        let ecrit = !(dictee?.nEcritNullePart ?? (RelaisCatalogue.courant.sortieParDefaut == .aucune))
        couper()
        overlay.hide()
        Feedback.cancelled()
        terminer(.abandonnee(quitterLaDiscussion: !ecouteQuiDemarre && ecrit,
                             ecouteQuiDemarre: ecouteQuiDemarre))
    }

    /// Le cycle en cours cesse de l'être.
    private func couper() {
        generation &+= 1
        moteur?.cancel()
        moteur = nil
        reprendreLArret()
    }

    /// L'arrêt demandé, ou le cycle coupé : l'écoute cesse d'attendre.
    private func reprendreLArret() {
        arret?.resume()
        arret = nil
    }

    /// WebKit a tué la page pendant qu'on parlait.
    ///
    /// Le son qu'elle captait est perdu avec elle. Continuer d'afficher
    /// l'écoute, c'était laisser parler dans le vide jusqu'à l'appui d'arrêt ;
    /// on échoue donc tout de suite, en le disant. Les autres phases le
    /// découvrent seules, au relevé suivant de leur attente (cf.
    /// `RelaisDictee.observer`).
    ///
    /// La page rechargée porte une conversation vierge : une discussion
    /// restée ouverte y enverrait la suite sans son contexte. Elle se ferme,
    /// comme à un abandon.
    private func pageInterrompue() {
        guard phase == .ecoute else { return }
        let erreur = RelaisErreur.pageInterrompue
        Log.error("relais : la page est morte pendant l'écoute")
        couper()
        overlay.showFailure(erreur.raisonCourte ?? "La page ChatGPT s'est fermée")
        terminer(.abandonnee(quitterLaDiscussion: true, ecouteQuiDemarre: false),
                 echec: erreur.localizedDescription)
    }

    // MARK: - Le cycle

    /// Ouvre une dictée ; rend la raison du refus sinon.
    ///
    /// Une seule chose à la fois sur la page. La dictée et la calibration
    /// pilotent le même document ; les laisser tourner ensemble faisait
    /// intercepter par la calibration les clics que la dictée envoyait par
    /// programme.
    ///
    /// `permissions` : le micro et l'accessibilité, que les deux voies
    /// exigent ; rend le message d'échec quand l'un manque.
    func commencer(applicationVisee: NSRunningApplication?,
                   permissions: @escaping @MainActor () async -> String?) -> String? {
        if let raison = relais.occupation.raison { return raison }
        guard relais.estCalibre else {
            return "La voie ChatGPT n'est pas encore calibrée — voir Réglages › Voie."
        }
        generation &+= 1
        let g = generation
        self.applicationVisee = applicationVisee
        arretDemande = false
        annoncee = false
        chrono = .now
        // Avant toute attente : un second appui pendant que la page se
        // prépare doit trouver le démarrage, et non le repos (11).
        entrer(.demarrage)
        moteur = Task { await derouler(g, permissions) }
        return nil
    }

    /// La dictée, de l'appui à la livraison — la seule tâche du cycle.
    private func derouler(_ g: Int, _ permissions: () async -> String?) async {
        if let refus = await permissions() {
            guard g == generation else { return }
            terminer(.demarrageManque(nil), echec: refus)
            return
        }
        guard g == generation else { return }
        let scenario: RelaisDictee
        do {
            // La barre s'ouvre avant l'écoute : on voit ChatGPT démarrer, et
            // la page, enfin à l'écran, cesse d'être différée par le système.
            relais.afficherBarre(module: RelaisCatalogue.courant)
            // La page n'est pas prête sur-le-champ — elle se prépare encore,
            // ne s'est pas dite connectée au premier relevé, ou ne s'est pas
            // mise à écouter : on le dit, plutôt que de laisser l'écran muet.
            let annoncer = { [weak self] in
                guard let self, g == generation, phase == .demarrage, !annoncee else { return }
                annoncee = true
                montrerLAttente()
            }
            scenario = try await relais.pagePourDictee(patienter: annoncer)
            try await scenario.ouvrirLEcoute(siElleTarde: annoncer)
        } catch {
            // Défait par la touche : l'abandon a déjà tout repris.
            guard g == generation else { return }
            demarrageManque(error)
            return
        }
        // Interrompu à l'instant où la page commençait à écouter :
        // l'abandon l'a déjà arrêtée.
        guard g == generation else { return }
        self.scenario = scenario
        Log.info("enregistrement démarré")
        // Avant d'afficher la barre : elle grise le bouton Notes tant qu'un
        // sélecteur serait impossible, et lit l'état pour le savoir.
        entrer(.ecoute)
        overlay.showRecording(statutDeLaBarre(peutChoisirLaNote: false))
        // L'aperçu en direct est impossible ici : il faudrait un second flux
        // micro, celui-là même qui prive la page de son.
        overlay.setPreviewNotice("ChatGPT transcrit à la fin de la dictée")
        Feedback.recordingStarted()

        if !arretDemande { await withCheckedContinuation { arret = $0 } }
        guard g == generation else { return }
        // Échap est rendu pendant l'attente, et c'est délibéré : c'est un
        // raccourci global, et le garder armé une minute pendant que
        // quelqu'un travaille ailleurs annulait des réorganisations que
        // personne n'avait voulu annuler (mesuré). La sortie reste la touche
        // de dictée (cf. `DictationController.ajusterEchap`).
        Feedback.recordingStopped()
        // Ce qui est dit à l'arrêt : le module et la destination du moment.
        // La voie et l'application visée restent celles de l'appui (29).
        let module = RelaisCatalogue.courant
        let dictee = DicteeEnCours(voie: .chatgpt, module: module,
                                   destination: Preferences.shared.effectiveTarget,
                                   applicationVisee: applicationVisee,
                                   duree: Date.now.timeIntervalSince(depuis))
        self.dictee = dictee
        entrer(.transcription)
        guard let issue = await transcrire(dictee, module, scenario, g), g == generation else { return }
        terminer(.livree(module, texteLaisse: issue.texteLaisse), echec: issue.echec)
    }

    /// Le démarrage a échoué sur la page.
    private func demarrageManque(_ error: Error) {
        // La barre dit pourquoi, quand la raison tient en une ligne ; elle
        // s'efface sinon, au lieu de rester sur « ChatGPT se prépare… » devant
        // une dictée qui n'aura pas lieu.
        let erreur = error as? RelaisErreur
        if let courte = erreur?.raisonCourte {
            overlay.showFailure(courte)
        } else {
            overlay.hide()
        }
        terminer(.demarrageManque(erreur), echec: error.localizedDescription)
    }

    /// La sortie de toute dictée : quitter la phase, puis rendre la page
    /// prête pour la suivante (cf. `Relais.finirLeCycle`).
    private func terminer(_ fin: Relais.Fin, echec: String? = nil) {
        entrer(nil, echec: echec)
        moteur = nil
        scenario = nil
        dictee = nil
        applicationVisee = nil
        relais.finirLeCycle(fin)
    }

    // MARK: - Transcrire

    /// Ce qu'une dictée allée au bout laisse : le message du menu (`nil`
    /// réussie), et si le texte est resté dans la page, à récupérer dans la
    /// fenêtre ouverte pour cela.
    private typealias Issue = (echec: String?, texteLaisse: Bool)

    /// Arrête la page, lit la transcription, la transforme, puis ouvre la
    /// discussion ou livre ; `nil` quand le cycle n'est plus le sien.
    ///
    /// Rien n'a été enregistré de notre côté : ni durée minimale à vérifier,
    /// ni audio à conserver pour un « Réessayer » qui n'aurait rien à rejouer.
    private func transcrire(_ dictee: DicteeEnCours, _ module: RelaisModule,
                            _ scenario: RelaisDictee, _ g: Int) async -> Issue? {
        Log.info("fin de dictée relais : \(String(format: "%.1f", dictee.duree)) s")
        let debut = ContinuousClock.now
        // La transcription de ChatGPT a-t-elle été gardée pour le menu ?
        var brutGarde = false
        // La réponse de ChatGPT, quand elle diffère du brut : le menu ne
        // garde que ce dernier, et un échec d'insertion doit savoir s'il
        // reste autre chose à sauver (cf. le `catch` plus bas).
        var remanie: String?
        do {
            let brut = try await scenario.arreterEtLire()
            guard g == generation else { return nil }
            // Rien n'a été dit : on s'arrête là, quel que soit le module.
            // Testé après les modules qui n'écrivent nulle part, ce cas ouvrait
            // en silence une discussion où aucun message n'était parti. Rien à
            // conserver, donc rien à promettre sous le message.
            guard !brut.isEmpty else {
                Log.error("ChatGPT a rendu un texte vide (\(Log.ms(depuis: debut)) ms)")
                overlay.showFailure("Rien n'a été entendu")
                return ("ChatGPT n'a rien transcrit — avez-vous parlé ?", false)
            }
            // Le filet, posé dès que le brut est lu et avant la seconde passe :
            // ce qui échoue ensuite — l'insertion, une attente abandonnée à la
            // touche — ne le perd plus.
            livraison.garderLeBrut(brut)
            brutGarde = true
            // Une dictée qui n'écrit nulle part s'arrête sur la page.
            if dictee.nEcritNullePart { return await discuter(brut, module, scenario, g) }

            // La seconde passe, quand le module la demande. Elle rend le brut
            // si elle échoue : rien de ce qui a été dit ne se perd.
            let (texte, avertissement) = try await transformer(brut, module, scenario, g)
            guard g == generation else { return nil }
            if texte != brut { remanie = texte }
            relais.masquerBarre()
            overlay.hide()
            _ = avancer(g, .livraison)
            // Le brut va à l'historique à côté du texte remanié, quand ils
            // diffèrent (cf. `TranscriptionHistory.Entry.brut`). Réussie, elle
            // oublie le brut gardé plus haut, même si l'appui a repris le
            // cycle pendant l'insertion (cf. `Livraison.ecrire`).
            try await livraison.livrer(texte, dictee, brut: brut)
            // Abandonné pendant l'insertion : le texte est écrit, et c'est
            // tout ce qui reste de ce cycle.
            guard g == generation else { return nil }
            Log.info("transcrit en \(Log.ms(depuis: debut)) ms, \(texte.count) caractères")
            // La transformation a échoué et c'est le brut qui vient d'être
            // inséré : le dire, là où l'on regarde. Sans quoi un texte non
            // remanié passe pour la réponse de ChatGPT, et un quota atteint
            // pour une consigne mal suivie.
            guard let avertissement else { return (nil, false) }
            overlay.showFailure("Transcription brute insérée", hint: avertissement)
            return ("Transcription brute insérée — \(avertissement).", false)
        } catch let echec as Livraison.EchecDInsertion {
            // Seule l'écriture a échoué : la page n'y est pour rien. Le brut
            // reste au menu : rien n'a été écrit.
            guard g == generation else { return nil }
            Log.error("échec d'insertion : \(echec.localizedDescription)")
            // L'historique a gardé le texte, ou il n'y avait que le brut, que
            // le menu garde : pas de fenêtre à ouvrir, la page est préparée
            // pour la suivante comme après une réussite.
            guard !echec.enHistorique, remanie != nil else {
                overlay.showFailure("Insertion impossible", hint: echec.enHistorique
                    ? "Le texte est dans l'historique, menu de Caspr."
                    : "La transcription brute est dans le menu de Caspr.")
                return (echec.localizedDescription, false)
            }
            // Historique désactivé, texte remanié : la réponse de ChatGPT
            // n'est plus que dans la page. La préparer pour la suivante l'y
            // détruisait — ni l'historique ni le menu ne l'avaient. La fenêtre
            // s'ouvre donc sur elle, et la préparation attend qu'on en ait
            // fini (cf. `Relais.finirLeCycle`).
            overlay.showFailure("Insertion impossible",
                                hint: "Le texte est dans la fenêtre de ChatGPT.")
            relais.ouvrirFenetre()
            return ("\(echec.localizedDescription) — le texte est dans la fenêtre du "
                    + "relais, la transcription brute dans le menu de Caspr.", true)
        } catch {
            // L'abandon a tout défait (cf. `abandonner`).
            guard g == generation, !(error is CancellationError) else { return nil }
            return echecDeLaPage(error, brutGarde: brutGarde)
        }
    }

    /// La page a prouvé un échec après l'arrêt : le dire, et ce qui reste à
    /// reprendre — le texte resté dans la fenêtre du relais, sauf quand la
    /// page est morte : celle qu'on ouvrirait est neuve, et le texte a
    /// disparu avec l'ancienne.
    ///
    /// Pas de « Réessayer » : il n'y a pas d'audio de ce côté-ci, et proposer
    /// un recours qui ne peut pas marcher est pire que de n'en proposer aucun.
    private func echecDeLaPage(_ error: Error, brutGarde: Bool) -> Issue {
        Log.error("échec de transcription : \(error.localizedDescription)")
        let recuperable = (error as? RelaisErreur)?.laissePeutEtreLeTexte ?? true
        // Un refus de ChatGPT porte sa raison, un quota par exemple : la
        // barre la montre telle quelle. Et quand le brut a été lu, rien
        // n'est perdu : c'est le recours qu'on nomme d'abord, celui qui ne
        // demande pas d'aller fouiller une page.
        let recours: String? = brutGarde
            ? "Rien n'est perdu : insérer la transcription brute, dans le menu de Caspr."
            : recuperable ? "Le texte est peut-être encore dans la fenêtre de ChatGPT."
                          : nil
        overlay.showFailure((error as? RelaisErreur)?.raisonCourte ?? "Transcription impossible",
                            hint: recours)
        let dansLeMenu = "la transcription brute est dans le menu de Caspr"
        guard recuperable else {
            return (brutGarde ? "\(error.localizedDescription) — \(dansLeMenu)."
                              : error.localizedDescription, false)
        }
        // La fenêtre du relais s'ouvre sur la page : quand la lecture échoue,
        // le texte y est encore, et c'est le seul moyen de le récupérer. Elle
        // redevient donc utilisable au clavier, pour qu'un ⌘C y soit
        // possible. Rien n'est rechargé, et rien ne se collera à la dictée
        // suivante — celle-ci vide la zone avant d'écouter.
        relais.ouvrirFenetre()
        return ("\(error.localizedDescription) — "
                + (brutGarde ? "\(dansLeMenu), et le texte " : "le texte est ")
                + "peut-être encore dans la fenêtre du relais.", true)
    }

    /// Renvoie le brut à ChatGPT avec la consigne d'un module qui écrit, et
    /// rend ce qu'il répond — ou le brut, avec la raison, quand la seconde
    /// passe n'aboutit pas.
    ///
    /// **En cas d'échec, la transcription brute est rendue telle quelle.** Une
    /// dictée de dix minutes ne doit pas se perdre parce que la seconde passe
    /// n'a pas abouti. **Sauf l'abandon**, qui n'est pas un échec : rendre le
    /// brut ici insérerait un texte dont on vient de demander l'abandon.
    private func transformer(_ brut: String, _ module: RelaisModule,
                             _ scenario: RelaisDictee, _ g: Int) async throws -> (String, String?) {
        // Ce que le module exige, et non un drapeau global : c'est lui qui
        // sait de quoi il a besoin, et lui seul.
        guard module.demandeUnAllerRetour, module.estUtilisable(RelaisSelecteurs.charger())
        else { return (brut, nil) }
        _ = avancer(g, .envoi)
        do {
            try await scenario.envoyer(avant: module.avant, apres: module.apres, brut: brut)
            guard avancer(g, .reponse) else { throw CancellationError() }
            let texte = try await scenario.recuperer()
            try Task.checkCancellation()
            guard !texte.isEmpty else {
                Log.error("relais : réponse vide, transcription brute conservée")
                return (brut, "ChatGPT a rendu une réponse vide")
            }
            if module.ditLaReponse {
                // La réponse est en main, finie et copiée : ce qui fait défaut
                // ici, c'est le son seul, et le texte remanié s'insère quand
                // même. La touche ne fait plus que cesser d'attendre : traitée
                // en abandon, elle jetait une réponse obtenue — et payée sur le
                // quota.
                guard avancer(g, .lecture) else { throw CancellationError() }
                await scenario.faireLire(dejaFinie: true)
            }
            Log.info("relais : \(module.identifiant) — \(brut.count) → \(texte.count) caractères")
            return (texte, nil)
        } catch {
            // Une attente interrompue peut finir sur une autre erreur que
            // l'annulation — un appel au pont coupé, une copie jamais venue.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Log.error("relais : \(module.identifiant) a échoué (\(error.localizedDescription)) "
                      + "— transcription brute conservée")
            // Le brut est rendu, mais pas en silence. Un quota atteint surtout
            // doit se lire — sans quoi on relance, et le même refus revient.
            // Une session fermée aussi, et un envoi sans effet : le message
            // attend dans la page.
            let erreur = error as? RelaisErreur
            switch erreur {
            case .refusParChatGPT?, .pasConnecte?, .envoiSansEffet?: return (brut, erreur?.raisonCourte)
            default: return (brut, "\(module.nom) n'a pas abouti")
            }
        }
    }

    /// Un module qui n'écrit nulle part : envoyer, faire lire la réponse s'il
    /// le demande, et ouvrir la discussion.
    ///
    /// La réponse est déjà à l'écran, dans la page que l'utilisateur a sous
    /// les yeux. Rien à insérer, rien à archiver — l'historique est un filet
    /// pour retrouver un texte qu'une insertion aurait perdu, et une
    /// conversation n'est pas une dictée qu'on range. Et **sans ouvrir de fil
    /// neuf** : le contexte de la conversation est ce qu'on veut garder.
    private func discuter(_ brut: String, _ module: RelaisModule,
                          _ scenario: RelaisDictee, _ g: Int) async -> Issue? {
        var avertissement: String?
        var parti = false
        if module.demandeUnAllerRetour, module.estUtilisable(RelaisSelecteurs.charger()) {
            _ = avancer(g, .envoi)
            do {
                try await scenario.envoyer(avant: module.avant, apres: module.apres, brut: brut)
                parti = true
            } catch {
                // Abandonné avant l'envoi : rien n'est parti, et c'est un
                // abandon, pas un échec à afficher.
                guard g == generation, !(error is CancellationError) else { return nil }
                Log.error("relais : \(module.identifiant) n'a pas pu envoyer "
                          + "(\(error.localizedDescription))")
                avertissement = (error as? RelaisErreur)?.raisonCourte
                    ?? "\(module.nom) n'a pas pu envoyer"
            }
        }
        if parti {
            Log.info("relais : \(module.identifiant) — envoyé, réponse à l'écran")
            // Passé ce point, il n'y a plus rien à abandonner : l'envoi ne se
            // défait pas, et ChatGPT répond déjà. Traitée en abandon, la
            // touche laissait la discussion fermée, et la fin du cycle
            // rechargeait la page sous la réponse de ChatGPT.
            if module.ditLaReponse {
                guard avancer(g, .lecture) else { return nil }
                // Un refus — un quota —, une session fermée se disent dans la
                // barre : sans quoi on attend une voix qui ne viendra pas.
                avertissement = await scenario.faireLire(dejaFinie: false)?.raisonCourte
                if scenario.lectureInterrompue {
                    Log.info("relais : attente de la lecture interrompue, discussion conservée")
                }
            }
            // WebKit a tué la page après l'envoi : rechargée, elle porte une
            // conversation vierge. « Dictée perdue » serait faux : ChatGPT a
            // reçu le message.
            if scenario.pageMorte {
                avertissement = "La page ChatGPT s'est fermée — la réponse est "
                    + "dans l'historique de ChatGPT"
            }
        }
        guard g == generation else { return nil }
        // Parti, le message n'a plus rien à insérer : le brut gardé pour le
        // menu promettrait un recours sans objet. Resté dans la zone — un
        // envoi impossible —, il reste à portée.
        if parti { livraison.oublierLeRecours() }
        // Sans voix ni texte à insérer, la barre est le seul endroit où lire
        // un refus. L'avertissement se suffit, en une ligne.
        let issue: Issue
        if let avertissement {
            overlay.showFailure(avertissement, hint: parti ? nil
                : "Rien n'est perdu : insérer la transcription brute, dans le menu de Caspr.")
            issue = ("\(avertissement).", false)
        } else {
            overlay.hide()
            issue = (nil, false)
        }
        relais.entrerEnDiscussion(module, pageMorte: scenario.pageMorte)
        return issue
    }
}
