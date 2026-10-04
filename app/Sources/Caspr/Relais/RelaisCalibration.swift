import AppKit
import CasprCore

/// La calibration : apprendre les boutons de la page, par l'automate ou par
/// la main — un seul cycle de vie pour les deux parcours.
///
/// Ils étaient deux méthodes de `Relais`, chacune avec ses gardes, sa sortie
/// et ses oublis. Le parcours manuel n'oubliait pas la préparation en vol au
/// départ : elle pouvait recharger la page pendant qu'on désignait le micro,
/// et la dictée suivante poursuivait un fil disparu. Il ne préparait pas non
/// plus la dictée suivante à la fin. Une seule entrée (`lancer`) et une seule
/// sortie (`sortir`) : ce qu'un parcours doit à la page, l'autre le lui doit
/// aussi, et l'oubli n'a plus de place où se loger.
///
/// La calibration n'est pas une dictée : une main humaine y lit une consigne
/// et cherche un bouton, et ses attentes gardent leurs bornes.
@MainActor
final class RelaisCalibration {
    enum Parcours { case automatique, manuel }

    /// Le message d'essai des deux parcours.
    ///
    /// Court et explicite : il part réellement dans la conversation de
    /// l'utilisateur, et il vaut mieux qu'on comprenne pourquoi en le relisant
    /// six mois plus tard.
    static let essai = "Bonjour — message d'essai envoyé par Caspr pour repérer les "
                     + "boutons de la page. Réponds simplement « c'est noté »."

    /// Un fragment du message d'essai, pour le reconnaître là où la page l'a
    /// réécrit : ni apostrophe ni guillemet, que l'éditeur pourrait rendre
    /// autrement.
    static let empreinte = "Caspr pour repérer les boutons"

    /// Le relais, par ses deux portes seulement : `prendrePourCalibrer` au
    /// départ, `rendreApresCalibration` à la sortie. Ce qu'elles gardent —
    /// l'occupation, la préparation, le premier plan — reste privé chez lui.
    private unowned let relais: Relais

    /// Le parcours en cours et sa page, retenus pour pouvoir y renoncer.
    ///
    /// Un drapeau ne suffisait pas : fermer la fenêtre en pleine calibration
    /// laissait la tâche attendre un clic qui ne viendrait jamais, le drapeau
    /// restait levé, et plus rien ne repartait jusqu'au redémarrage de
    /// l'application.
    private var enCours: (tache: Task<Void, Never>, page: RelaisPage)?

    /// Le numéro du parcours en cours, changé aussi par l'abandon : un
    /// parcours abandonné qui finit plus tard — une copie attendue jusqu'à
    /// cinq secondes, un appel au pont en suspens — ne rend pas la main à la
    /// place de celui qui a commencé depuis. L'occupation ne suffisait pas à
    /// le dire : un parcours lancé entre-temps la remet à `.calibration`, et
    /// l'ancienne tâche la lui retirait.
    private var numero = 0

    init(relais: Relais) { self.relais = relais }

    // MARK: - Le cycle de vie

    /// Lance `parcours`, s'il est temps. Ce qu'il apprend passe par le
    /// magasin, que les écrans observent : ils n'ont pas à être prévenus.
    ///
    /// L'automatique cède au manuel dans la même course, quand son rapport le
    /// propose : même numéro, même page, une seule sortie.
    func lancer(_ parcours: Parcours) {
        guard let page = relais.prendrePourCalibrer() else { return }
        numero &+= 1
        let jeton = numero
        page.montrer()
        let tache = Task {
            defer { if numero == jeton { sortir() } }
            let relance = parcours == .automatique ? "« Calibrer automatiquement »" : "la calibration"
            guard await obtenirLaSession(page, relance: relance) else { return }
            if parcours == .automatique {
                guard await automatique(page), !Task.isCancelled else { return }
            }
            await manuel(page)
        }
        enCours = (tache, page)
    }

    /// Met fin à la calibration, d'où qu'on le demande : la fenêtre fermée,
    /// le passage à macOS. La sortie a lieu tout de suite, sans attendre que
    /// le parcours s'en aperçoive — la page peut être détruite juste après.
    func abandonner() {
        guard let enCours else { return }
        numero &+= 1
        enCours.tache.cancel()
        Log.info("relais : calibration abandonnée")
        sortir()
    }

    /// LA sortie d'une calibration — fin, abandon, fenêtre fermée, passage à
    /// macOS.
    ///
    /// L'occupation rendue, pour que la dictée et les réglages repartent ; la
    /// page rangée, toujours, et le premier plan rendu s'il était à elle ;
    /// puis la dictée suivante préparée comme après une dictée : le parcours a oublié
    /// discussion et préparation en partant, et plusieurs de ses sorties —
    /// l'annonce refusée, une page qui ne répond pas, une connexion jamais
    /// venue — ne rechargent pas la page. La dictée suivante partait alors
    /// dans l'ancien fil. C'est la préparation qui retire le guetteur resté
    /// sur la page, rend le micro et recharge une page laissée à l'écoute (cf.
    /// `Relais.rendreApresCalibration`) : l'appui suivant l'attend avant de
    /// cliquer quoi que ce soit.
    private func sortir() {
        guard let page = enCours?.page else { return }
        enCours = nil
        relais.rendreApresCalibration(page)
    }

    // MARK: - La session

    /// La session qu'exigent les deux parcours, en l'expliquant si elle
    /// manque ; vrai quand elle est ouverte. `relance` : le bouton qui la
    /// relance, dit dans les alertes.
    ///
    /// Trente secondes : choisir ChatGPT vient souvent de construire la page,
    /// qui se charge encore. Et selon le filet, pas selon le calibrage qu'on
    /// vient peut-être remplacer parce qu'il est faux — il faisait passer une
    /// session ouverte pour fermée, et la calibration refusait de réparer
    /// justement ce qu'on lui demandait de réparer. « Déconnecté » seulement
    /// quand la page l'a dit (cf. `RelaisPage.connexion`) : une page qui se
    /// tait est rechargée, et personne n'est envoyé chercher un mot de passe.
    private func obtenirLaSession(_ page: RelaisPage, relance: String) async -> Bool {
        switch await page.connexion(secondes: 30, reperes: RelaisSelecteurs()) {
        case .connecte:
            return true
        case .inconnu:
            guard !Task.isCancelled else { return false }
            page.charger()
            RelaisDialogues.alerter("La page ChatGPT ne répond pas", RelaisDialogues.pageMuette(relance: relance))
            return false
        case .deconnecte:
            guard !Task.isCancelled else { return false }
        }
        RelaisDialogues.alerter("D'abord, se connecter à ChatGPT", RelaisDialogues.seConnecter)
        // Attendre la connexion plutôt que s'arrêter : c'est le parcours de
        // qui choisit ChatGPT pour la première fois, et le renvoyer chercher
        // un bouton une fois connecté lui faisait croire le travail fini. Dix
        // minutes : le temps de retrouver un mot de passe, ou de créer un
        // compte. Fermer la fenêtre abandonne la calibration, et l'attente
        // avec elle.
        if (try? await page.observer(auPlus: .seconds(600), toutes: .seconds(1)) {
            await page.connexion(secondes: 2, reperes: RelaisSelecteurs()) == .connecte
        }) == true { return true }
        guard !Task.isCancelled else { return false }
        // L'alerte a promis une reprise : s'arrêter sans le dire laissait
        // attendre, connecté, une suite qui ne viendrait plus.
        RelaisDialogues.alerter("Toujours pas connecté", RelaisDialogues.toujoursPasConnecte(relance: relance))
        return false
    }

    // MARK: - Les deux parcours

    /// L'automatique, de l'annonce au rapport (cf. `RelaisCalibrationAuto`) ;
    /// vrai quand l'utilisateur choisit de finir à la main.
    ///
    /// Rien n'est enregistré tant que l'aller-retour entier n'est pas prouvé :
    /// un automate qui écrirait repère par repère et échouerait à mi-chemin
    /// détruirait en silence un calibrage qui marchait.
    private func automatique(_ page: RelaisPage) async -> Bool {
        let ancien = RelaisMagasin.partage.selecteurs
        // Un abandon lève : il n'y a rien à rapporter, et la sortie remet la
        // page d'aplomb. Fermer la fenêtre arrête tout, comme l'annonce l'a
        // promis — y compris l'écriture d'un parcours qui venait d'aboutir.
        guard RelaisDialogues.demander("Calibrer automatiquement", RelaisDialogues.annonce),
              let issue = try? await RelaisCalibrationAuto(page: page, ancien: ancien).mener(),
              !Task.isCancelled
        else { return false }
        await page.rendreLeMicro()
        // Rendre le micro peut attendre : la fenêtre a pu se fermer entre-temps.
        guard !Task.isCancelled else { return false }

        guard let nouveau = issue.preuves.calibrage(remplacant: ancien) else {
            Log.error("relais : calibration automatique incomplète — manquent "
                      + issue.preuves.manquants.map(\.rawValue).joined(separator: ", "))
            let rapport = RelaisDialogues.rapport(issue, ancien: ancien, enregistre: false)
            return RelaisDialogues.choisir("Calibration automatique inachevée", rapport,
                                           ["Montrer les boutons à la main…", "Fermer"]) == 0
        }
        // La seule écriture du parcours automatique.
        RelaisMagasin.partage.selecteurs = nouveau
        Log.info("relais : calibration automatique enregistrée — "
                 + RelaisPreuves.parcours.map { "\($0.rawValue) \(nouveau[$0])" }.joined(separator: ", "))

        // La réponse au message d'essai est encore à l'écran : c'est le
        // moment de montrer « Lire à haute voix », s'il sert. Deux clics au
        // plus, et le seul que l'automate ne fera pas.
        let rapport = RelaisDialogues.rapport(issue, ancien: ancien, enregistre: true)
        if RelaisDialogues.choisir("C'est appris", rapport, ["Terminé", "Montrer « Lire à haute voix »…"]) == 1,
           RelaisDialogues.demander("Lire à haute voix", RelaisDialogues.lectureApresAutomatique) {
            do { try await apprendre(page, .lecture) }
            catch where !(error is CancellationError) && !Task.isCancelled {
                RelaisDialogues.alerter("Relais", error.localizedDescription)
            } catch {}
        }
        return false
    }

    /// Le manuel : les étapes de `RelaisEtape.parcoursManuel`, dans l'ordre
    /// où les boutons existent, chaque repère enregistré dès qu'il est appris.
    private func manuel(_ page: RelaisPage) async {
        // Une conversation neuve, et une zone vide : ChatGPT réinstalle le
        // brouillon non envoyé au rechargement, et l'on demandait de cliquer
        // le micro devant un texte que la dictée serait venue rallonger. Par
        // le filet : le calibrage en place est peut-être celui qu'on
        // remplace parce qu'il est faux.
        guard await page.repartirAuFilet() else {
            if !Task.isCancelled { RelaisDialogues.alerter("Relais", "La page ChatGPT n'a pas fini de se charger.") }
            return
        }

        let etapes = RelaisEtape.parcoursManuel
        for (rang, etape) in etapes.enumerated() {
            guard !Task.isCancelled else { return }
            var consigne = etape.consigne
            if case .messageDEssai(let sinon) = etape.preparation {
                // Le bouton d'envoi n'existe qu'une fois la zone remplie ; la
                // page vient d'y transcrire ce qu'elle a entendu.
                page.charger()
                let ecrit = await page.attendreComposeurPret(secondes: 30) ? await Self.ecrireLEssai(page, dans: "") : false
                if !ecrit { consigne = sinon }
            }
            guard !Task.isCancelled else { return }
            guard RelaisDialogues.demander("Repère \(rang + 1) sur \(etapes.count) — \(etape.cible.libelle)", consigne) else {
                // Renoncer à l'étape facultative, c'est finir : ce qui a été
                // appris avant elle est déjà enregistré.
                if etape.facultative { break } else { return }
            }
            do {
                try await apprendre(page, etape.cible)
            } catch is CancellationError {
                return
            } catch let erreur where etape.facultative && !Task.isCancelled {
                // Son échec se dit dans le message de fin, selon ce que la
                // page sait faire — il annonçait sinon « lire à haute voix »
                // juste après l'alerte disant qu'aucun clic ne l'avait désigné.
                Log.error("relais : \(etape.cible.rawValue) non appris — \(erreur.localizedDescription)")
            } catch {
                if !Task.isCancelled { RelaisDialogues.alerter("Relais", error.localizedDescription) }
                return
            }
        }
        guard !Task.isCancelled else { return }
        RelaisDialogues.alerter("C'est appris", RelaisDialogues.finManuelle(saitLire: page.selecteurs.saitLire))
    }

    // MARK: - Ce que les parcours demandent à la page

    /// Attend le clic de l'utilisateur sur `cible`, et enregistre aussitôt le
    /// repère qu'il désigne, avec le bloc qui le porte.
    ///
    /// Le clic n'est pas intercepté : il atteint la page. C'est nécessaire —
    /// le bouton d'arrêt n'existe que pendant l'enregistrement, donc il faut
    /// que le clic sur le micro ait réellement démarré l'écoute.
    ///
    /// Trois minutes au plus : c'est l'attente d'une main — elle lit la
    /// consigne, cherche le bouton, hésite —, et une consigne oubliée
    /// derrière une autre fenêtre laissait le parcours attendre pour
    /// toujours. À l'échéance, le guetteur est retiré de la page, sans quoi
    /// il retiendrait le prochain clic de l'utilisateur, n'importe où dans
    /// ChatGPT. Une erreur de la page passe telle quelle : ce n'est pas trois
    /// minutes sans clic.
    ///
    /// Un « copier » refusé se redemande, en disant pourquoi : la page le
    /// refuse quand il n'est pas celui de la dernière réponse, et Caspr quand
    /// le clic n'a rien copié. Le bon genre ne suffit pas à le reconnaître —
    /// le pouce, sous la même réponse, est un bouton aussi, et appris là, il
    /// ferait échouer chaque dictée à la récupération. Comme l'automatique,
    /// la main est jugée à l'effet : le presse-papiers a changé, dans les
    /// trois secondes. La copie atterrit une fraction de seconde après le
    /// clic : c'est le délai d'un geste, et non d'une réponse.
    ///
    /// Relevé avant l'attente du clic, et non à l'instant du clic : Caspr
    /// entend le clic par un aller-retour, et la copie du bon bouton peut le
    /// précéder — un relevé pris alors l'absorberait, et refuserait ce
    /// bouton à chaque essai, bloquant le parcours. En échange, une copie
    /// faite ailleurs pendant qu'on cherche le bouton passerait pour la
    /// sienne ; il faudrait encore qu'elle tombe avec un clic sur un autre
    /// bouton du tour de la réponse, que la page a déjà seul admis.
    private func apprendre(_ page: RelaisPage, _ cible: RelaisCible) async throws {
        while true {
            let reponse = page.selecteurs.reponse
            // Le clic sur « copier » y laisse la réponse de ChatGPT : rendu à
            // la fin de chaque essai, accepté ou refusé, comme l'automatique
            // le rend — c'est vers la main qu'il renvoie quand il échoue.
            let presse = NSPasteboard.general
            let sauvegarde = cible == .copier ? PressePapiers(presse) : nil
            let copies = presse.changeCount
            defer { if let sauvegarde, presse.changeCount != copies { sauvegarde.rendre(presse) } }
            guard let issue = try await page.auPlus(.seconds(180), {
                try await page.guetter(cible, reponse: reponse)
            }) else {
                await page.abandonnerCalibration()
                throw RelaisErreur.calibrationSansClic(cible)
            }
            // Le guetteur a été retiré de la page : c'est un abandon.
            guard let r = issue else { throw CancellationError() }
            let refus = cible != .copier ? nil
                : r.selecteur.isEmpty ? RelaisDialogues.copierAilleurs(r.raison)
                : (try? await page.observer(auPlus: .seconds(3), toutes: .milliseconds(100)) {
                    presse.changeCount != copies
                }) == true ? nil : RelaisDialogues.copierRien
            // Au journal aussi : un refus relu après coup vaut mieux qu'un
            // dialogue dont on ne se rappelle plus les termes exacts.
            if refus != nil {
                Log.error("relais : « copier » refusé — "
                          + (r.selecteur.isEmpty ? (r.raison.isEmpty ? "sans raison" : r.raison)
                                                 : "le clic n'a rien copié"))
            }
            try Task.checkCancellation()
            if let refus {
                guard RelaisDialogues.demander("Pas ce bouton-là", refus) else { throw CancellationError() }
                continue
            }
            guard !r.selecteur.isEmpty else {
                // Ce que la page offrait, au moment où l'on n'a rien su en
                // tirer. Sans cette ligne, « Calibrer à nouveau ? » renvoie
                // indéfiniment vers la même impasse sans rien apprendre.
                Log.error("relais : repère introuvable pour \(cible.rawValue) — "
                          + (r.raison.isEmpty ? "sans détail" : r.raison))
                throw RelaisErreur.introuvable(cible)
            }
            var s = page.selecteurs
            s[cible] = r.selecteur
            // Le bloc qui porte les boutons des barres d'actions : la page en
            // pose une sous chaque message, et seul le couple dit de laquelle
            // il s'agit.
            switch cible {
            case .copier: s.copierParent = r.parent
            case .lecture: (s.lectureParent, s.lectureMenu, s.lectureMenuParent) = (r.parent, r.menu, r.menuParent)
            default: break
            }
            RelaisMagasin.partage.selecteurs = s
            return
        }
    }

    /// Écrit le message d'essai dans `composeur` (vide : le filet), et
    /// s'assure qu'il y est ; faux s'il n'y a pas tenu en `secondes`.
    ///
    /// L'écriture est **vérifiée**, et réessayée (cf. `RelaisPage.ecrire`) :
    /// non relue, elle laissait l'utilisateur devant une zone vide, sans
    /// bouton d'envoi à désigner.
    static func ecrireLEssai(_ page: RelaisPage, dans composeur: String, pendant secondes: Double = 6) async -> Bool {
        await page.ecrire(essai, sel: composeur, pendant: secondes) { $0.contains(empreinte) }
    }
}
