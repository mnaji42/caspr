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
            return "La voie ChatGPT n'est pas encore calibrée — "
                + "voir Réglages › Voie."
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
        // La page n'est pas prête sur-le-champ — elle se prépare encore, ne
        // s'est pas dite connectée au premier relevé, ou ne s'est pas mise à
        // écouter : on le dit, plutôt que de laisser l'écran muet. Avec le chrono et la sortie dès dix
        // secondes, comme les attentes d'après l'arrêt : celle-ci n'a pas de
        // fin non plus, et seule la touche de dictée l'interrompt.
        let appui = Date.now
        let libelle = "ChatGPT se prépare…"
        try await relais.demarrer(patienter: { [overlay] in
            overlay.showProcessing(libelle, progress: {
                .init(label: libelle, elapsed: Date.now.timeIntervalSince(appui),
                      exitHint: "touche de dictée pour abandonner")
            })
        })
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
    /// écouter entre-temps : on l'arrête, comme Échap le fait pendant l'écoute
    /// — sauf si elle n'a pas encore été touchée (cf.
    /// `Relais.interrompreLeDemarrage`).
    func demarrageInterrompu() {
        relais.interrompreLeDemarrage()
    }

    /// Le démarrage a échoué sur la page.
    func demarrageManque(_ error: Error) {
        // La barre dit pourquoi, quand la raison tient en une ligne ; elle
        // s'efface sinon, au lieu de rester sur « ChatGPT se prépare… » devant
        // une dictée qui n'aura pas lieu.
        //
        // Et ce que l'appui a ouvert de ChatGPT se range avec elle. Ouvert
        // avant l'écoute, il restait au-dessus du travail, sans rapport
        // visible avec le message d'échec. Sauf la fenêtre où l'on doit se
        // connecter, et celle d'une discussion déjà en cours.
        if let courte = (error as? RelaisPage.Erreur)?.raisonCourte {
            overlay.showFailure(courte)
        } else {
            overlay.hide()
        }
        relais.rangerApresUnDemarrageManque(error)
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

    /// Plus rien à abandonner — le message de « Discuter » est parti, ou la
    /// réponse d'un module qui écrit est en main : il ne reste qu'à attendre
    /// la lecture à haute voix.
    var seuleLaLectureEnAttente: Bool { relais.seuleLaLectureEnAttente }

    /// L'appui ne fait plus que cesser d'attendre la lecture.
    func cesserDAttendreLaLecture() { relais.cesserDAttendreLaLecture() }

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
        // La transcription de ChatGPT a-t-elle été gardée pour le menu ?
        var brutGarde = false
        // La réponse de ChatGPT, quand elle diffère du brut : le menu ne
        // garde que ce dernier, et un échec d'insertion doit savoir s'il
        // reste autre chose à sauver (cf. le `catch` plus bas).
        var remanie: String?
        do {
            let brut = try await relais.arreterEtLire()
            // Rien n'a été dit : on s'arrête là, quel que soit le module.
            // Testé après les modules qui n'écrivent nulle part, ce cas ouvrait
            // en silence une discussion où aucun message n'était parti — la
            // fenêtre prenait le clavier, et le menu proposait de quitter un
            // fil jamais commencé. Rien à conserver, donc rien à promettre
            // sous le message : il n'y a pas d'audio de ce côté-ci, et
            // « Réessayer » n'existe pas sur cette voie.
            guard !brut.isEmpty else {
                guard estEnCours() else { return .sansSuite }
                Log.error("ChatGPT a rendu un texte vide (\(Log.ms(depuis: debut)) ms)")
                overlay.showFailure("Rien n'a été entendu")
                return .echec("ChatGPT n'a rien transcrit — avez-vous parlé ?")
            }
            // Le filet, posé dès que le brut est lu et avant la seconde passe :
            // ce qui échoue ensuite — l'insertion, une attente abandonnée à la
            // touche — ne le perd plus. Pas pour un cycle qui n'est plus le
            // sien : le recours appartient à la dictée d'après.
            if estEnCours() {
                livraison.garderLeBrut(brut)
                brutGarde = true
            }
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
                // Abandonnée avant l'envoi, la dictée n'arrive pas ici : son
                // cycle n'est plus le sien. Après l'envoi, l'appui n'a fait que
                // cesser d'attendre, et le fil parti doit rester ouvert — sans
                // quoi la fin du cycle rechargeait la page sous la réponse de
                // ChatGPT.
                //
                // Parti, le message n'a plus rien à insérer : le brut gardé
                // pour le menu promettrait un recours sans objet. Resté dans
                // la zone — un envoi impossible —, il reste à portée.
                if relais.messageParti { livraison.oublierLeRecours() }
                // Sauf un refus — un quota, un envoi impossible : sans voix
                // ni texte à insérer, la barre est le seul endroit où le lire.
                // L'avertissement se suffit, en une ligne : un titre au-dessus
                // de lui ne ferait que le répéter.
                let issue: Issue
                if let avertissement = relais.prendreAvertissement() {
                    // Resté dans la zone, le message a encore son recours.
                    overlay.showFailure(avertissement, hint: relais.messageParti || !brutGarde
                        ? nil
                        : "Rien n'est perdu : insérer la transcription brute, dans le menu de Caspr.")
                    issue = .echec("\(avertissement).")
                } else {
                    overlay.hide()
                    issue = .reussie
                }
                relais.entrerEnDiscussion(module)
                return issue
            }
            // Pas de texte vide ici : la transformation rend le brut quand elle
            // échoue ou que la réponse est vide, et le brut vide s'est arrêté
            // plus haut.
            if texte != brut { remanie = texte }
            relais.masquerBarre()
            overlay.hide()
            // Le brut va à l'historique à côté du texte remanié, quand ils
            // diffèrent (cf. `TranscriptionHistory.Entry.brut`).
            // Réussie, elle oublie le brut gardé plus haut, même si l'appui a
            // repris le cycle pendant l'insertion (cf. `Livraison.ecrire`).
            try await livraison.livrer(texte, dictee, brut: brut)
            // Abandonné pendant l'insertion : le texte est écrit, et c'est
            // tout ce qui reste de ce cycle. L'état appartient au suivant.
            guard estEnCours() else { return .sansSuite }
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
        } catch let echec as Livraison.EchecDInsertion {
            // Seule l'écriture a échoué : la page n'y est pour rien. Le brut
            // reste au menu : rien n'a été écrit.
            guard estEnCours() else { return .sansSuite }
            Log.error("échec d'insertion : \(echec.localizedDescription)")
            // L'historique a gardé le texte, ou il n'y avait que le brut, que
            // le menu garde : pas de fenêtre à ouvrir, la page est préparée
            // pour la suivante comme après une réussite.
            guard !echec.enHistorique, remanie != nil else {
                overlay.showFailure("Insertion impossible", hint: echec.enHistorique
                    ? "Le texte est dans l'historique, menu de Caspr."
                    : "La transcription brute est dans le menu de Caspr.")
                return .echec(echec.localizedDescription)
            }
            // Historique désactivé, texte remanié : la réponse de ChatGPT
            // n'est plus que dans la page. La préparer pour la suivante l'y
            // détruisait — ni l'historique ni le menu ne l'avaient. La fenêtre
            // s'ouvre donc sur elle, et la préparation attend qu'on en ait
            // fini (cf. `Relais.apresLivraison`).
            overlay.showFailure("Insertion impossible",
                                hint: "Le texte est dans la fenêtre de ChatGPT.")
            relais.ouvrirFenetre()
            return .echec("\(echec.localizedDescription) — le texte est dans la "
                          + "fenêtre du relais, la transcription brute dans le menu de Caspr.",
                          texteLaisseDansLaPage: true)
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
            // barre la montre telle quelle. Et quand le brut a été lu, rien
            // n'est perdu : c'est le recours qu'on nomme d'abord, celui qui
            // ne demande pas d'aller fouiller une page.
            let recours: String? = brutGarde
                ? "Rien n'est perdu : insérer la transcription brute, dans le menu de Caspr."
                : recuperable ? "Le texte est peut-être encore dans la fenêtre de ChatGPT."
                              : nil
            overlay.showFailure(
                (error as? RelaisPage.Erreur)?.raisonCourte ?? "Transcription impossible",
                hint: recours)
            let dansLeMenu = "la transcription brute est dans le menu de Caspr"
            guard recuperable else {
                return .echec(brutGarde ? "\(error.localizedDescription) — \(dansLeMenu)."
                                        : error.localizedDescription)
            }
            // La fenêtre du relais s'ouvre sur la page : quand la lecture
            // échoue, le texte y est encore, et c'est le seul moyen de le
            // récupérer. Elle redevient donc utilisable au clavier, pour qu'un
            // ⌘C y soit possible. Rien n'est rechargé, et rien ne se collera à
            // la dictée suivante — celle-ci vide la zone avant d'écouter.
            relais.ouvrirFenetre()
            return .echec("\(error.localizedDescription) — "
                          + (brutGarde ? "\(dansLeMenu), et le texte " : "le texte est ")
                          + "peut-être encore dans la fenêtre du relais.",
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
