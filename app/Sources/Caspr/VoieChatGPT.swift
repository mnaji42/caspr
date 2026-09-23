import AppKit
import CasprCore

/// La voie ChatGPT : la page écoute, ChatGPT transcrit, et le module choisi
/// remanie le texte ou y répond.
///
/// Le pendant de `VoieApple`, et rien ne s'y ressemble. Caspr n'ouvre pas son
/// micro : la page a le son, elle seule. L'attente dure des minutes au lieu
/// d'une seconde, la dictée peut ne rien écrire du tout, et quand elle échoue
/// son texte est peut-être encore dans la page. Tout ce qu'elle fait sur la
/// page passe par `Relais` ; ce qu'elle ne sait pas, c'est quel cycle est en
/// cours, et c'est le contrôleur qui le lui dit.
@MainActor
final class VoieChatGPT {
    private let relais = Relais.partage
    private let overlay: RecordingOverlay
    private let livraison: Livraison

    init(overlay: RecordingOverlay, livraison: Livraison) {
        self.overlay = overlay
        self.livraison = livraison
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
    func choisirModule(_ index: Int, enEcoute: Bool) {
        let modules = RelaisCatalogue.proposes
        guard modules.indices.contains(index) else { return }
        RelaisCatalogue.courant = modules[index]
        // L'affichage appartient au module : changer de module en pleine
        // dictée doit le faire suivre. C'était le seul réglage figé à l'appui
        // de la touche, et c'est le cas courant — on change d'avis parce qu'on
        // a déjà commencé à parler.
        if enEcoute { relais.afficherBarre() }
    }

    // MARK: - Écoute

    /// Prend la page pour une dictée ; rend la raison du refus sinon.
    ///
    /// Une seule chose à la fois sur la page. La dictée et la calibration
    /// pilotent le même document. Les laisser tourner ensemble faisait
    /// intercepter par la calibration les clics que la dictée envoyait par
    /// programme : Caspr prenait ses propres commandes pour des gestes de
    /// l'utilisateur.
    func prendre() -> String? {
        guard relais.prendreLaMainPourDictee() else {
            return relais.occupation.raison ?? "Relais occupé."
        }
        guard relais.estCalibre else {
            relais.rendreLaMain()
            return "ChatGPT Web Preview est actif mais pas configuré — "
                + "voir Réglages › Moteur IA."
        }
        return nil
    }

    /// Rend la page sans avoir écouté — un démarrage manqué.
    func rendre() {
        relais.rendreLaMain()
    }

    /// Attend que la page écoute.
    ///
    /// Caspr n'ouvre pas son micro pendant une dictée ChatGPT. Il l'a fait, et
    /// c'était nuisible sans être utile. Sans utilité, parce que la
    /// transcription vient du micro ouvert par la page : l'audio capté ici
    /// n'aurait servi qu'à l'aperçu en direct. Et nuisible, parce que les deux
    /// captures ne cohabitent pas — mesuré au niveau crête, 0.000 sur toutes
    /// les dictées dès qu'une page ChatGPT existe.
    func demarrer() async throws {
        // La barre s'ouvre avant l'écoute : on voit ChatGPT démarrer, et la
        // page, enfin à l'écran, cesse d'être différée par le système.
        relais.afficherBarre()
        // La page se prépare encore : on le dit, plutôt que de laisser l'écran
        // muet le temps qu'elle soit prête.
        if relais.preparationEnCours {
            overlay.showProcessing("ChatGPT se prépare…")
        }
        try await relais.demarrer()
        // Interrompu à l'instant où la page commençait à écouter :
        // l'annulation l'emporte, la page est arrêtée par l'appelant.
        try Task.checkCancellation()
    }

    /// La page écoute, et la barre vient de s'ouvrir sur l'enregistrement.
    func ecouteOuverte() {
        // L'aperçu en direct est impossible ici, et c'est définitif : il
        // faudrait un second flux micro, celui-là même qui prive la page de
        // son.
        overlay.setPreviewNotice("ChatGPT transcrit à la fin de la dictée")
    }

    /// La touche a interrompu l'attente de la page. Elle a pu se mettre à
    /// écouter entre-temps : on l'arrête, comme Échap le fait pendant l'écoute.
    func demarrageInterrompu() {
        relais.interrompre()
    }

    /// Le démarrage a échoué sur la page.
    func demarrageManque(_ error: Error) {
        // La barre dit pourquoi, quand la raison tient en une ligne ; elle
        // s'efface sinon, au lieu de rester sur « ChatGPT se prépare… » devant
        // une dictée qui n'aura pas lieu.
        //
        // Et la barre de ChatGPT se range avec elle. Ouverte avant l'écoute,
        // elle restait à flotter au-dessus du travail, sans rapport visible
        // avec le message d'échec. Pas la grande fenêtre, si elle vient de
        // s'ouvrir : c'est là qu'on se connecte.
        if let courte = (error as? RelaisPage.Erreur)?.raisonCourte {
            overlay.showFailure(courte)
        } else {
            overlay.hide()
        }
        relais.rangerLaBarre()
    }

    /// WebKit a tué la page pendant qu'on parlait ; rend le message d'échec.
    func pageInterrompue() -> String {
        let erreur = RelaisPage.Erreur.pageInterrompue
        Log.error("relais : la page est morte pendant l'écoute")
        relais.rendreLaMain()
        relais.masquerBarre()
        overlay.showFailure(erreur.raisonCourte ?? "La page ChatGPT s'est fermée")
        return erreur.localizedDescription
    }

    /// Le temps d'écoute de la page, et non depuis l'appui : ce qui précède —
    /// attendre qu'elle soit prête — n'a rien à transcrire.
    var secondesEcoutees: TimeInterval { relais.secondesEcoulees }

    /// Le message de « Discuter » est parti : il n'y a plus rien à abandonner,
    /// ChatGPT répond dans le fil.
    var messageParti: Bool { relais.messageParti }

    /// Abandonne la dictée en cours sur la page : la rendre, l'arrêter, la
    /// préparer pour la suivante — jusqu'à quitter la discussion quand la
    /// dictée devait écrire ailleurs, comme `apresLivraison` l'aurait fait.
    ///
    /// `dictee` : `nil` pendant l'écoute, où rien n'est encore figé ; c'est
    /// alors le module du moment qui dit où la dictée devait aller.
    func abandonner(_ dictee: DicteeEnCours?) {
        let nEcritNullePart = dictee?.nEcritNullePart
            ?? (RelaisCatalogue.courant.sortieParDefaut == .aucune)
        relais.rendreLaMain()
        relais.interrompre(quitterLaDiscussion: !nEcritNullePart)
    }

    // MARK: - Terminer

    /// Ce qu'une dictée ChatGPT laisse au contrôleur.
    enum Issue {
        case reussie
        /// Le message pour le menu, et si le texte est resté dans la page, à
        /// récupérer dans la fenêtre ouverte pour cela.
        case echec(String, texteLaisseDansLaPage: Bool = false)
        /// L'abandon a tout défait (cf. `abandonner`), ou le cycle n'est plus
        /// le sien : l'état appartient à qui l'a repris.
        case sansSuite
    }

    /// Arrête la page, lit la transcription, la transforme, puis ouvre la
    /// discussion ou livre.
    ///
    /// Rien n'a été enregistré de notre côté : ni durée minimale à vérifier,
    /// ni audio à conserver pour un « Réessayer » qui n'aurait rien à rejouer.
    ///
    /// `estEnCours` : vrai tant que le cycle de cette dictée est celui du
    /// contrôleur. Un cycle abandonné finit de se dérouler après coup, et ne
    /// doit plus rien écrire ni rien afficher.
    func terminer(_ dictee: DicteeEnCours, module: RelaisModule,
                  estEnCours: () -> Bool) async -> Issue {
        // La phase et le chrono, relus sur l'attente du relais : elle peut
        // durer des minutes, et la touche de dictée en est la sortie — encore
        // faut-il le dire.
        overlay.showProcessing(RelaisAttente.Phase.transcription.libelle,
                               progress: { [relais] in relais.avancement })
        Log.info("fin de dictée relais : \(String(format: "%.1f", dictee.duree)) s")
        let debut = ContinuousClock.now
        do {
            let brut = try await relais.arreterEtLire(secondesDictees: dictee.duree)
            // La seconde passe, quand le module la demande. Elle rend le brut
            // si elle échoue : rien de ce qui a été dit ne se perd.
            let texte = try await relais.transformer(brut, module: module)
            guard estEnCours() else { return .sansSuite }

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
                if Task.isCancelled, !relais.messageParti {
                    throw CancellationError()
                }
                // Sauf un refus — un quota, un envoi impossible : sans voix
                // ni texte à insérer, la barre est le seul endroit où le lire.
                // L'avertissement se suffit, en une ligne : un titre « n'a pas
                // répondu » au-dessus de « n'a pas répondu en 3 min » ne
                // faisait que le répéter.
                let issue: Issue
                if let avertissement = relais.prendreAvertissement() {
                    overlay.showFailure(avertissement)
                    issue = .echec("\(avertissement).")
                } else {
                    overlay.hide()
                    issue = .reussie
                }
                relais.entrerEnDiscussion(module)
                return issue
            }
            guard !texte.isEmpty else {
                // Rien à conserver, donc rien à promettre sous le message : il
                // n'y a pas d'audio de ce côté-ci, et « Réessayer » n'existe
                // pas sur cette voie.
                Log.error("ChatGPT a rendu un texte vide (\(Log.ms(depuis: debut)) ms)")
                overlay.showFailure("Rien n'a été entendu")
                return .echec("ChatGPT n'a rien transcrit — avez-vous parlé ?")
            }
            relais.masquerBarre()
            overlay.hide()
            // Rendre le clavier avant d'écrire. Après une discussion, ou si
            // l'on bascule vers un module qui écrit en pleine dictée, la
            // fenêtre du relais est au premier plan : le texte y partirait.
            //
            // Ici et non dans `Livraison` : seule cette fenêtre peut tenir le
            // clavier, et la cacher sous une dictée macOS masquerait la
            // calibration qu'ouvre un passage à ChatGPT fait en pleine phrase.
            await relais.rendreLeClavier()
            try await livraison.livrer(texte, vers: dictee.destination,
                                       depuis: dictee.applicationVisee)
            // Abandonné pendant l'insertion : le texte est écrit, et c'est
            // tout ce qui reste de ce cycle. L'état appartient au suivant.
            guard estEnCours() else { return .sansSuite }
            livraison.oublierLeRecours()
            Log.info("transcrit en \(Log.ms(depuis: debut)) ms, \(texte.count) caractères")
            // La transformation a échoué et c'est le brut qui vient d'être
            // inséré : le dire, là où l'on regarde. Sans quoi un texte non
            // remanié passe pour la réponse de ChatGPT, et un quota atteint
            // pour une consigne mal suivie.
            if let avertissement = relais.prendreAvertissement() {
                overlay.showFailure("Transcription brute insérée", hint: avertissement)
                return .echec("Transcription brute insérée — \(avertissement).")
            }
            return .reussie
        } catch is CancellationError {
            // L'abandon a tout défait (cf. `abandonner`).
            return .sansSuite
        } catch {
            guard estEnCours() else { return .sansSuite }
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
            guard recuperable else { return .echec(error.localizedDescription) }
            // La fenêtre du relais s'ouvre sur la page : quand la lecture
            // échoue, le texte y est encore, et c'est le seul moyen de le
            // récupérer. Elle redevient donc utilisable au clavier, pour qu'un
            // ⌘C y soit possible. Rien n'est rechargé, et rien ne se collera à
            // la dictée suivante — celle-ci vide la zone avant d'écouter.
            relais.ouvrirFenetre()
            return .echec("\(error.localizedDescription) — le texte est peut-être encore "
                          + "dans la fenêtre du relais.",
                          texteLaisseDansLaPage: true)
        }
    }

    /// La fin d'une dictée prépare la suivante (cf. `Relais.apresLivraison`).
    func apresLivraison(_ module: RelaisModule, issue: Issue) {
        let texteLaisse = switch issue {
        case .echec(_, let laisse): laisse
        case .reussie, .sansSuite: false
        }
        relais.apresLivraison(module, texteLaisseDansLaPage: texteLaisse)
    }
}
