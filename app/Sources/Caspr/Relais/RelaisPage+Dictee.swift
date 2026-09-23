import AppKit
import CasprCore

// Ce que la page fait pendant une dictée : écouter, rendre la transcription,
// envoyer, attendre et récupérer la réponse, la faire lire, et se préparer à
// la suivante.
//
// LA RÈGLE (RELAIS.md, sixième règle). Sur le chemin d'une dictée, une
// attente de ChatGPT ne finit que par un geste de l'utilisateur — la touche
// de dictée, Échap pendant l'écoute — ou par un échec que la page PROUVE :
// une alerte de refus apparue depuis la demande, le processus WebKit mort,
// l'écran d'authentification montré. Jamais par le temps. Le propriétaire,
// le 24 septembre 2026 : « Des fois ça prend dix, vingt, trente secondes…
// Donc non, il n'y a pas de limite. »
//
// Restent seulement des délais de geste, qui prouvent l'effet d'un geste de
// Caspr — un bouton qui doit exister, un clic qui doit prendre — et chacun le
// dit par un commentaire « délai de geste : … ». Dans le doute, pas de délai.
// Au repos, un silence peut se constater : c'est `sonder`, qui ne sert
// jamais ici qu'à préparer ou arrêter la page.
extension RelaisPage {
    /// La page est-elle en train d'écouter ? Au repos : l'arrêt après un
    /// abandon, le diagnostic.
    ///
    /// C'est la page qui fait foi, pas un drapeau tenu de notre côté. Un
    /// drapeau local se désynchronise à la première erreur — et il l'a fait :
    /// après un échec, l'application se croyait au repos pendant que ChatGPT
    /// enregistrait toujours, si bien que le geste suivant relançait une
    /// dictée par-dessus au lieu de l'arrêter.
    func estEnEnregistrement() async -> Bool {
        await etatAuRepos()?.enregistrement == true
    }

    /// La page porte-t-elle une conversation ?
    ///
    /// Posée à la page, et non déduite du module qui vient de tourner : une
    /// réorganisation qui échoue à mi-chemin a tout de même envoyé son message,
    /// et c'est la page qui le sait.
    ///
    /// `nil` quand elle ne répond pas, quelle qu'en soit la raison — page
    /// muette, pont absent : ni oui ni non, et la seule préparation qui vaille
    /// alors est de la reconstruire. Une page en cours de chargement n'est pas
    /// interrogée (cf. `Relais.preparer`).
    func tientUneConversation() async -> Bool? {
        await etatAuRepos()?.conversation
    }

    private func etatAuRepos() async -> RelaisInstantane? {
        await sonder { try await self.instantane() }
    }

    /// Clique le micro. La page commence à écouter.
    ///
    /// `siElleTarde` : la page ne s'est pas dite connectée au premier relevé,
    /// ou ne s'est pas mise à écouter peu après. La barre le dit alors, avec
    /// la sortie (cf. `VoieChatGPT.demarrer`) : l'attente qui suit n'a pas de
    /// fin.
    func demarrer(siElleTarde: @escaping @MainActor () -> Void = {}) async throws {
        lectureInterrompue = false
        // L'annonce ne dépend pas du retour d'un relevé. Sur un fil JavaScript
        // figé, le premier ne revient jamais : annoncer à son retour, c'était
        // laisser la barre muette, sans la sortie, aussi longtemps que la page
        // restait figée. Une fois la session dite, la page peut encore se
        // figer au vidage ou au clic du micro : l'annonce reste armée, un peu
        // plus tard, pour ne pas faire clignoter « se prépare » devant un
        // démarrage ordinaire. Ce délai n'est qu'un affichage : il ne met fin
        // à rien (cf. la règle en tête de ce fichier).
        var annonce = annoncer(apres: .milliseconds(400), siElleTarde)
        defer { annonce.cancel() }
        try await attendreLaSession()
        annonce.cancel()
        if await annonce.value == false {
            annonce = annoncer(apres: .milliseconds(1500), siElleTarde)
        }
        // La page que cette dictée va attendre est celle qui vient de se dire
        // connectée. Relevé avant l'attente, une mort survenue pendant celle-ci
        // — déjà réparée par le rechargement — faisait annoncer « dictée
        // perdue » à qui n'avait encore rien dit.
        mortsAuDepart = morts
        // Vider la zone **avant** d'écouter. Une dictée dont la lecture a
        // échoué laisse son texte dans la page — délibérément, pour qu'il reste
        // récupérable à la main. Mais ChatGPT ajoute la dictée suivante à la
        // suite au lieu de remplacer, si bien que le texte suivant arrivait
        // collé au précédent, et le suivant encore aux deux.
        try? await vider(sel: selecteurs.composeur)
        // Ce que la page affiche déjà n'est pas un échec de cette dictée.
        try? await marquer()
        // L'écho doit être prêt quand la page demandera le micro, au clic.
        echo.armer()
        var clique = false
        defer { if !clique { echo.desarmer() } }
        // Délai de geste : le bouton micro existe dès que la page s'est dite
        // connectée ; huit secondes sans lui, et il est introuvable.
        clique = try await cliquerQuandDisponible(.micro, selecteurs.micro, pendant: 8)
        guard clique else { throw Erreur.introuvable(.micro) }
        echo.ecouter()
    }

    /// Attend que la page se dise connectée — **sans fin**.
    ///
    /// Au tout premier appui d'une session, chatgpt.com se charge encore, à
    /// froid ; conclure « pas connecté » à cet instant-là demandait un second
    /// appui, et le conclure faute de réponse envoyait chercher un mot de
    /// passe devant une page seulement lente. Seul l'écran d'authentification
    /// fait échouer : une page qui ne dit rien est attendue, et la touche de
    /// dictée en sort.
    ///
    /// Rien n'est demandé pendant un chargement : une zone vue alors est celle
    /// de la page qu'on quitte. Une page chargée sans son pont, elle, a dit
    /// tout ce qu'elle dira (`Erreur.pontAbsent`).
    private func attendreLaSession() async throws {
        while true {
            try Task.checkCancellation()
            var vu: RelaisInstantane?
            do { vu = chargementEnCours ? nil : try await instantane() }
            catch Erreur.pontAbsent { throw Erreur.pontAbsent } catch {}
            switch vu.flatMap(session) {
            case .connecte?:
                return
            case .deconnecte?:
                montrer()
                throw Erreur.pasConnecte
            default:
                try await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Fait `annonce` après `delai`, sauf annulation d'ici là ; la tâche rend
    /// si l'annonce a été faite.
    private func annoncer(apres delai: Duration,
                          _ annonce: @escaping @MainActor () -> Void) -> Task<Bool, Never> {
        Task { @MainActor in
            guard (try? await Task.sleep(for: delai)) != nil else { return false }
            annonce()
            return true
        }
    }

    /// Clique l'arrêt, puis attend que le texte apparaisse et se stabilise.
    ///
    /// Deux attentes distinctes, et c'est tout l'objet de cette méthode.
    ///
    /// **La zone de saisie doit d'abord revenir.** Pendant la dictée, ChatGPT
    /// la retire du DOM au profit de la barre d'onde. Au moment où l'on clique
    /// l'arrêt, elle n'existe donc pas — et la première version en concluait
    /// « introuvable » sur-le-champ, ce qui échouait à tous les coups.
    ///
    /// **Le texte doit ensuite cesser de bouger.** Il arrive par fragments :
    /// lire au premier caractère rendrait une phrase tronquée.
    ///
    /// Ni l'une ni l'autre n'a de fin : une transcription se juge sur la zone,
    /// jamais sur le temps qu'elle a pris.
    func arreterEtLire() async throws -> String {
        // Après l'arrêt, ChatGPT passe par un état intermédiaire — le mot
        // « Transcription » et une roue — pendant lequel la zone de saisie
        // n'est toujours pas là. Sa durée suit celle de la dictée : quelques
        // secondes pour trente secondes de parole, bien plus pour dix minutes.
        //
        // C'est ce que la version précédente n'avait pas vu. Elle vérifiait
        // « la page a-t-elle cessé d'écouter ? » en regardant si le bouton
        // d'arrêt avait disparu — or il ne disparaît pas tout de suite. Sur une
        // dictée courte la transcription arrivait dans les deux secondes
        // d'observation et tout allait bien ; sur une dictée longue, elle
        // concluait que l'arrêt n'avait pas répondu, rechargeait la page, et
        // détruisait une transcription qui était en train d'aboutir. D'où la
        // corrélation avec la longueur, qui n'en était pas une avec la taille
        // du texte mais avec le temps d'attente.
        //
        // On n'essaie plus de distinguer « écoute encore » de « transcrit » :
        // le seul signal fiable est le retour de la zone de saisie, et il
        // signifie exactement ce qu'on attend.
        //
        // Délai de geste : le bouton d'arrêt existe pendant l'écoute ; quinze
        // secondes sans lui, et il est introuvable.
        //
        // L'écho se désarme à la sortie du clic, quelle qu'elle soit : une
        // erreur du pont ne passe pas par `annuler`, et l'écho armé
        // continuerait d'accumuler le son jusqu'à la dictée suivante.
        let arrete: Bool
        do {
            defer { echo.desarmer() }
            arrete = try await cliquerQuandDisponible(.stop, selecteurs.stop, pendant: 15)
        }
        guard arrete else { throw Erreur.introuvable(.stop) }

        // La zone revient, puis son texte cesse de bouger (cf.
        // `RelaisVeille.Stabilisation`). Avant l'envoi, seul un échec que la
        // page reconnaît interrompt l'attente, avec l'utilisateur.
        var stabilisation = RelaisVeille.Stabilisation()
        switch try await veiller(.texte, apresEnvoi: false, { stabilisation.juger($0.texte) }) {
        case .texte(let texte):
            // On ne vide pas ici. `demarrer()` le fait avant chaque dictée, ce
            // qui suffit à empêcher toute concaténation, et vider exige de
            // focaliser la zone — l'opération même qui détournait le curseur
            // système. La faire à l'instant précis où Caspr s'apprête à
            // insérer au curseur serait le pire moment possible. Le texte
            // laissé dans la page est en prime un filet : il reste copiable si
            // l'insertion échoue.
            return texte
        case .vide:
            // Sauf si la page dit pourquoi : un refus — un quota atteint, par
            // exemple — rend lui aussi la zone vide, et « avez-vous parlé ? »
            // ferait chercher la panne au micro.
            if let message = await alerteNouvelle() { throw Erreur.refusParChatGPT(message) }
            Log.info("relais : la zone est revenue vide — rien n'a été dicté")
            return ""
        }
    }

    /// L'attente sans fin d'une dictée : un relevé de la page (`demande`)
    /// par quart de seconde, jusqu'à ce que `juger` rende une valeur.
    ///
    /// Un tour sur quatre, le relevé porte aussi les alertes — les chercher
    /// coûte à la page qu'on attend de voir avancer —, et les échecs que la
    /// page prouve s'y jugent : un refus (cf. `RelaisVeille.refus`), l'écran
    /// de connexion. La mort du processus se lit à chaque tour.
    ///
    /// Un relevé qui échoue ne dit rien, et l'on passe au suivant : le
    /// compter comme une zone vide finirait par conclure « rien n'a été dit »
    /// devant une page qui en a. Le reste appartient à l'utilisateur :
    /// l'annulation de la tâche tranche l'attente, appel au pont en suspens
    /// compris (cf. `appeler`).
    private func veiller<T>(_ demande: RelaisDemande, apresEnvoi: Bool,
                            _ juger: (RelaisInstantane) async throws -> T?) async throws -> T {
        var veille = RelaisVeille(apresEnvoi: apresEnvoi)
        var tour = 0
        while true {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            tour += 1
            let alertes = tour % 4 == 0
            guard let vu = try? await instantane(alertes ? demande.union(.alertes) : demande)
            else { continue }
            if let valeur = try await juger(vu) { return valeur }
            guard alertes else { continue }
            if let message = veille.refus(vu) { throw Erreur.refusParChatGPT(message) }
            if sessionMontreeFermee(vu) { throw Erreur.pasConnecte }
        }
    }

    /// La page montre-t-elle l'écran de connexion ?
    ///
    /// L'échec prouvé qu'une échéance rattrapait jusqu'ici : une session
    /// perdue en pleine attente ne rendra jamais rien, et sans ce relevé
    /// l'attente — désormais sans fin — le serait pour de bon.
    private func sessionMontreeFermee(_ vu: RelaisInstantane) -> Bool {
        guard RelaisVeille.session(vu) == false else { return false }
        Log.error("relais : la page montre l'écran de connexion pendant l'attente")
        surConnexion?(.deconnecte)
        return true
    }

    /// Clique un bouton, en lui laissant le temps d'exister.
    ///
    /// Un relevé unique supposait que la page ait fini de se remettre à jour à
    /// l'instant où on l'interroge. Elle ne l'a pas toujours fait : sa fenêtre
    /// vit hors champ, donc le système la considère cachée et diffère ses
    /// rendus. Le bouton d'arrêt, qui n'apparaît qu'en réaction au clic sur le
    /// micro, arrivait après notre question — d'où l'échec de la première
    /// dictée de chaque session, et le succès de toutes les suivantes, la
    /// fenêtre ayant entre-temps été affichée à la main.
    ///
    /// Attendre coûte quelques centaines de millisecondes dans le cas normal,
    /// où le bouton est là au premier essai. `secondes` est un délai de geste,
    /// que chaque appelant justifie.
    private func cliquerQuandDisponible(_ cible: RelaisCible, _ selecteur: String,
                                        pendant secondes: TimeInterval) async throws -> Bool {
        let limite = Date.now.addingTimeInterval(secondes)
        var essai = 0
        repeat {
            try Task.checkCancellation()
            try verifierLaPage()
            if try await cliquer(cible, sel: selecteur) {
                if essai > 0 { Log.info("relais : \(cible.rawValue) trouvé après \(essai) essais") }
                return true
            }
            essai += 1
            try? await Task.sleep(for: .milliseconds(250))
        } while Date.now < limite
        return false
    }

    /// Envoie sans rien rapatrier, et **sans ouvrir de fil neuf**.
    ///
    /// Le pendant de `reorganiserSurPlace` pour une sortie qui n'écrit nulle
    /// part. Deux différences, et toutes deux découlent de la sortie : on ne
    /// clique pas « copier » puisque rien n'est à insérer, et on ne recharge
    /// pas puisque le contexte de la conversation est précisément ce qu'on veut
    /// garder. Recharger ici détruirait ce que le module existe pour offrir.
    func envoyerSansAttendre(_ encadrement: (avant: String, apres: String),
                             attente: RelaisAttente) async throws {
        attente.entrer(.envoi)
        if !encadrement.avant.isEmpty || !encadrement.apres.isEmpty {
            try await encadrer(encadrement)
        }
        try await cliquerLEnvoi(empreinte: RelaisVeille.empreinte(encadrement.avant))
    }

    /// Encadre la transcription déjà présente, l'envoie, et rend la réponse.
    ///
    /// Aucun rechargement au milieu du chemin, et c'est le changement de fond.
    /// La version précédente rechargeait la page pour ouvrir un fil neuf, puis
    /// réécrivait la transcription entière avec la consigne devant. Trois
    /// défauts d'un coup : on interrogeait la page qu'on était en train de
    /// quitter, on demandait à un éditeur ProseMirror d'avaler dix minutes de
    /// texte d'un coup, et le moindre accroc laissait la zone dans un état
    /// qu'on ne savait plus nommer.
    ///
    /// Le texte est déjà là. On n'ajoute que la consigne, à ses deux bouts.
    ///
    /// Le fil neuf, lui, est ouvert **après** — quand la réponse est lue et que
    /// plus rien n'est en jeu. La page est alors prête pour la dictée suivante,
    /// et le contexte ne s'accumule pas d'une note à l'autre.
    func reorganiserSurPlace(_ encadrement: (avant: String, apres: String),
                             attente: RelaisAttente) async throws -> String {
        attente.entrer(.envoi)
        try await encadrer(encadrement)
        let empreinte = RelaisVeille.empreinte(encadrement.avant)
        try await cliquerLEnvoi(empreinte: empreinte)
        attente.entrer(.reponse)
        // Le bouton de ChatGPT quand on sait où il est, la lecture du DOM
        // sinon — pour ne pas casser une configuration antérieure.
        //
        // Pas de rechargement ici : la page neuve est ouverte à la fin de la
        // dictée, par la préparation de la suivante (cf.
        // `Relais.preparerLaProchaine`), pour toutes les dictées et au même
        // endroit. En recharger une seconde fois depuis ce chemin-ci, c'était
        // une deuxième politique de fil neuf — celle qui ne s'appliquait
        // qu'aux réorganisations réussies, et laissait donc la conversation en
        // place quand elles échouaient.
        return selecteurs.saitCopier
            ? try await copierReponse(empreinteEnvoyee: empreinte)
            : try await attendreReponse()
    }

    /// Ajoute la consigne aux deux bouts de la transcription, et attend de
    /// l'y relire.
    ///
    /// Attendre que l'insertion ait pris, et non une demi-seconde décidée
    /// d'avance. L'envoi partait avant que l'éditeur n'ait validé le texte
    /// ajouté : seule la transcription brute était expédiée, sans la consigne
    /// qui lui donne son sens. Un délai fixe marcherait jusqu'au jour où la
    /// machine rame ; une relecture, non.
    private func encadrer(_ encadrement: (avant: String, apres: String)) async throws {
        guard try await encadrer(sel: selecteurs.composeur, avant: encadrement.avant,
                                 apres: encadrement.apres)
        else { throw Erreur.introuvable(.composeur) }
        let empreinte = RelaisVeille.empreinte(encadrement.avant)
        guard !empreinte.isEmpty else { return }
        // Délai de geste : ce qu'on vient d'écrire se relit aussitôt, ou n'a
        // pas pris ; six secondes laissent large à une machine qui rame.
        let limite = Date.now.addingTimeInterval(6)
        while Date.now < limite {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            if let texte = try? await lire(sel: selecteurs.composeur), texte.contains(empreinte) { return }
        }
        Log.error("relais : la consigne n'a pas tenu dans la zone de saisie")
        throw Erreur.consigneNonPosee
    }

    /// Clique l'envoi, en posant d'abord la marque : seule une alerte ou une
    /// réponse apparue depuis compte. Puis vérifie que le message est parti.
    ///
    /// `empreinte` : ce qui, dans la zone, signe le message — le délimiteur
    /// de la consigne ; vide, la zone entière.
    private func cliquerLEnvoi(empreinte: String) async throws {
        try? await marquer()
        let marque = empreinte.isEmpty
            ? (try? await lire(sel: selecteurs.composeur)) ?? ""
            : empreinte
        // Délai de geste : le bouton d'envoi existe dès que la zone est
        // remplie ; dix secondes sans lui, et il est introuvable.
        guard try await cliquerQuandDisponible(.envoi, selecteurs.envoi, pendant: 10) else {
            throw Erreur.introuvable(.envoi)
        }
        try await verifierLeDepart(marque: marque)
    }

    /// Le message a-t-il quitté la zone, ou ChatGPT répond-il déjà ?
    ///
    /// Un clic sans effet — bouton désactivé, clic avalé par l'éditeur — rend
    /// ok quand même, et l'attente de la réponse qui suit n'a pas de fin :
    /// elle aurait attendu, la barre sur « ChatGPT répond… », une réponse à un
    /// message jamais parti. L'échéance qui rattrapait ce cas n'existe plus ;
    /// c'est ici qu'il se prouve.
    ///
    /// Délai de geste : ChatGPT vide la zone à l'instant du clic, sans attendre
    /// le réseau ; dix secondes sans que la marque la quitte ni qu'une réponse
    /// commence, et le clic n'a rien envoyé. Une zone absente ne prouve rien.
    private func verifierLeDepart(marque: String) async throws {
        let limite = Date.now.addingTimeInterval(10)
        while Date.now < limite {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            guard let vu = try? await instantane([.texte, .reponse]) else { continue }
            if let r = vu.reponse, r.nouvelles > 0 || r.enCours { return }
            if let zone = vu.texte, !marque.isEmpty, !zone.contains(marque) { return }
        }
        try Task.checkCancellation()
        // Une alerte apparue depuis la marque dit pourquoi, mieux que nous.
        if let message = await alerteNouvelle() { throw Erreur.refusParChatGPT(message) }
        Log.error("relais : le clic d'envoi est resté sans effet — message toujours dans la zone")
        throw Erreur.envoiSansEffet
    }

    /// Attend que la page rechargée soit prête, zone de saisie comprise — au
    /// repos, borné.
    ///
    /// **Sans se fier au calibrage.** C'est le point qui manquait : une
    /// calibration s'appuyait sur les repères qu'elle allait remplacer, et
    /// ceux-ci peuvent être absents — c'est le premier lancement — ou faux,
    /// c'est-à-dire exactement la raison pour laquelle on recalibre. On a ainsi
    /// « vidé » un bouton micro que le calibrage désignait comme la zone de
    /// texte, avant de conclure que la zone était vide parce qu'un bouton n'a
    /// pas de contenu. Les heuristiques du pont, elles, ne dépendent de rien.
    func attendreComposeurPret(secondes: Double) async -> Bool {
        let limite = Date.now.addingTimeInterval(secondes)
        while Date.now < limite {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
            guard !chargementEnCours else { continue }
            if await sonder({ try await self.lire(sel: "") }) != nil { return true }
        }
        return false
    }

    /// L'appui ne fait plus que cesser d'attendre la lecture à haute voix (cf.
    /// `Relais.cesserDAttendreLaLecture`).
    ///
    /// Un appel au pont resté en suspens retiendrait cette attente : il est
    /// rendu lui aussi, sans quoi la touche serait sans effet devant une page
    /// qui ne répond plus.
    func cesserDAttendreLaLecture() {
        lectureInterrompue = true
        rendreLesAppelsEnSuspens(CancellationError())
    }

    /// Attend que la réponse soit terminée, puis la fait lire à haute voix.
    ///
    /// Deux temps, parce que le bouton se cache parfois derrière un menu — la
    /// calibration a retenu le chemin complet, on le refait. Un module de
    /// traduction peut ainsi parler : on dicte en français, l'interlocuteur
    /// entend la réponse.
    ///
    /// La fin de la génération ne se lit plus au bloc du bouton « copier ».
    /// Ce repère est facultatif de bout en bout — la calibration l'enregistre
    /// vide quand aucun ancêtre n'est retrouvable — et, vide, il faisait
    /// attendre trois minutes à chaque dictée pour rien. Deux signaux qui ne
    /// demandent aucune calibration le remplacent : une réponse **nouvelle**
    /// existe, le bouton qui arrête la génération a disparu, et son texte ne
    /// bouge plus depuis deux secondes. Le premier écarte la réponse
    /// précédente, finie et immobile, qu'une discussion porte déjà.
    ///
    /// L'attente de la réponse finie n'a pas de fin : la touche de dictée la
    /// fait cesser (cf. `cesserDAttendreLaLecture`), et seule la voix est
    /// abandonnée.
    ///
    /// Un échec n'interrompt rien : la réponse est à l'écran, seul le son
    /// manque. Faire échouer la dictée entière pour un haut-parleur muet serait
    /// disproportionné. Sauf un échec prouvé — un refus, une session fermée,
    /// la page morte : aucune réponse ne viendra, et il est rendu pour que la
    /// barre le montre.
    ///
    /// - Parameter dejaFinie: la réponse est connue pour finie — elle vient
    ///   d'être copiée, et le texte attend ce clic pour s'insérer. Le premier
    ///   relevé qui la montre suffit, sans deux secondes de stabilité à
    ///   prouver.
    @discardableResult
    func faireLireLaReponse(attente: RelaisAttente,
                            dejaFinie: Bool = false) async -> Erreur? {
        guard selecteurs.saitLire else { return nil }
        attente.entrer(.reponse)
        // Délai de geste : la réponse vient d'être copiée, finie ; il ne reste
        // qu'à la voir dans la page, et dix secondes sans elle disent qu'on ne
        // la trouve pas — le texte s'insère alors sans la voix.
        let limite = dejaFinie ? Date.now.addingTimeInterval(10) : nil
        var veille = RelaisVeille(apresEnvoi: true)
        var finie = RelaisVeille.ReponseFinie(seuil: dejaFinie ? 0 : 8)   // ~2 s sans changement
        var prete = false
        var tour = 0
        while limite.map({ Date.now < $0 }) ?? true {
            if Task.isCancelled || lectureInterrompue { return nil }
            if morteDepuisLeDepart { return .pageInterrompue }
            try? await Task.sleep(for: .milliseconds(250))
            tour += 1
            let alertes = tour % 4 == 0
            guard let vu = try? await instantane(alertes ? [.reponse, .alertes] : .reponse) else { continue }
            if alertes {
                if let message = veille.refus(vu) {
                    Log.error("relais : ChatGPT a refusé (« \(message) »), lecture abandonnée")
                    return .refusParChatGPT(message)
                }
                if sessionMontreeFermee(vu) { return .pasConnecte }
            }
            if finie.juger(vu.reponse) { prete = true; break }
        }
        guard prete else {
            Log.error("relais : réponse copiée introuvable dans la page, lecture à haute "
                      + "voix abandonnée")
            return nil
        }

        attente.entrer(.lecture)
        // Le clic lui-même, répété quelques secondes. Délai de geste : la barre
        // d'actions de la réponse s'affiche juste après la fin de la
        // génération, pas au même instant ; cinq secondes sans elle, et le
        // bouton est introuvable.
        func cliquer(_ parent: String, _ bouton: String) async -> Bool {
            let fin = Date.now.addingTimeInterval(5)
            repeat {
                if Task.isCancelled || lectureInterrompue { return false }
                if (try? await cliquerBouton(parent: parent, bouton: bouton)) == true { return true }
                try? await Task.sleep(for: .milliseconds(300))
            } while Date.now < fin
            return false
        }
        if !selecteurs.lectureMenu.isEmpty {
            guard await cliquer(selecteurs.lectureMenuParent, selecteurs.lectureMenu) else {
                Log.error("relais : menu de la lecture à haute voix introuvable")
                return nil
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        // Sans cadrage quand un menu l'a ouvert : la page pose ses éléments de
        // menu ailleurs dans le document, hors du bloc de la réponse.
        let lancee = await cliquer(selecteurs.lectureMenu.isEmpty ? selecteurs.lectureParent : "",
                                   selecteurs.lecture)
        Log.info("relais : lecture à haute voix \(lancee ? "lancée" : "refusée")")
        return nil
    }

    /// Vide la zone de saisie, et s'assure qu'elle l'est restée — au repos.
    ///
    /// ChatGPT réinstalle le brouillon non envoyé après un rechargement, et
    /// parfois après qu'on l'a effacé : vider une fois ne suffit pas. On relit
    /// donc, et on recommence — la même précaution que pour l'écriture, et pour
    /// la même raison.
    @discardableResult
    func viderComposeur(selecteur: String? = nil) async -> Bool {
        let sel = selecteur ?? selecteurs.composeur
        // Le brouillon vit aussi dans le stockage de la page : l'effacer de la
        // zone ne suffit pas, ChatGPT le réinstalle depuis là.
        _ = await sonder { try await self.oublierBrouillon() }
        let limite = Date.now.addingTimeInterval(6)
        while Date.now < limite {
            if Task.isCancelled { return false }
            _ = await sonder { try await self.vider(sel: sel) }
            try? await Task.sleep(for: .milliseconds(500))
            if await sonder({ try await self.lire(sel: sel) })?.isEmpty == true { return true }
        }
        Log.error("relais : la zone de saisie n'a pas voulu se vider")
        return false
    }

    /// Attend la fin de la réponse, puis la récupère par le bouton de ChatGPT.
    ///
    /// Le bouton « copier » n'apparaît qu'une fois la génération terminée : sa
    /// présence est donc à la fois le signal de fin — qu'on devinait
    /// jusqu'ici en chronométrant l'arrêt du texte — et le moyen d'extraction.
    ///
    /// Extraction bien meilleure que la lecture du DOM, qui dépend du nœud
    /// désigné à la calibration : cliquer sur un paragraphe de la réponse
    /// faisait rendre ce seul paragraphe, sans que rien ne signale l'amputation.
    /// Le bouton, lui, rend la réponse entière, dans la mise en forme voulue
    /// par ChatGPT.
    ///
    /// Le presse-papiers est rendu tel qu'il était juste avant le clic, tous
    /// types compris : il appartient à l'utilisateur, et une dictée n'a pas à
    /// lui faire perdre ce qu'il y gardait.
    private func copierReponse(empreinteEnvoyee: String) async throws -> String {
        let presse = NSPasteboard.general
        var sauvegarde = PressePapiers(presse)
        var avant = presse.changeCount

        // Jusqu'au clic, sans fin, et seulement sur une réponse nouvelle,
        // finie : le bouton de son tour, qui la suit (`copierPret`).
        let voie = try await veiller(.reponse, apresEnvoi: true) { vu -> String? in
            guard vu.reponse?.copierPret == true else { return nil }
            // Le presse-papiers tel qu'il est juste avant ce clic. Relevé au
            // début de l'attente — désormais sans fin —, il prenait pour la
            // réponse ce que l'utilisateur copiait entre-temps, l'insérait, et
            // rendait à la place une chaîne seule : une image ou un texte mis
            // en forme étaient perdus. Resauvegardé seulement quand il a
            // changé : le copier quatre fois par seconde coûterait pour rien.
            if presse.changeCount != avant {
                sauvegarde = PressePapiers(presse)
                avant = presse.changeCount
            }
            return try? await copierLaReponse(parent: selecteurs.copierParent,
                                              copier: selecteurs.copier, reponse: selecteurs.reponse)
        }
        // La voie suivie — la paire, ou le repère sans bloc —, pour que le
        // prochain défaut se lise dans le journal plutôt que dans une capture.
        Log.info("relais : copier cliqué (\(voie))")

        // Le clic est asynchrone côté page : on attend que le presse-papiers
        // change plutôt que de le lire aussitôt.
        //
        // Délai de geste : la réponse est finie et le clic parti, la copie
        // atterrit dans l'instant ; dix secondes sans elle, et rien n'a été
        // copié.
        //
        // Sauf l'abandon, relevé en tête de chaque tour : il ne rend jamais de
        // texte. Sans ce contrôle, une tâche annulée tournait ici dix secondes
        // (le sommeil lève aussitôt, et `try?` l'avalait), puis rendait un
        // texte qui s'insérait. Mais il ne sort pas sur-le-champ : le clic est
        // parti, et la copie qu'il déclenche atterrit quand même, une fraction
        // de seconde plus tard. Sortir avant, c'était la laisser écraser le
        // presse-papiers sans plus personne pour le rendre. Il attend donc
        // cette copie une seconde encore, la défait, et seulement alors lève.
        let finCopie = Date.now.addingTimeInterval(10)
        var finAbandon: Date?
        while Date.now < (finAbandon ?? finCopie) {
            if finAbandon == nil, Task.isCancelled {
                finAbandon = min(finCopie, Date.now.addingTimeInterval(1))
            }
            if finAbandon == nil {
                try? await Task.sleep(for: .milliseconds(250))
            } else {
                // Le sommeil d'une tâche annulée rend la main aussitôt : on
                // dort dans une tâche à part, que l'annulation n'atteint pas.
                await Task { try? await Task.sleep(for: .milliseconds(100)) }.value
            }
            guard presse.changeCount != avant else { continue }
            let texte = presse.string(forType: .string) ?? ""
            sauvegarde.rendre(presse)
            try Task.checkCancellation()
            guard !texte.isEmpty else { throw Erreur.pasDeReponse }
            // Garde-fou : ce qu'on vient de copier ne doit pas être ce qu'on
            // vient d'envoyer. Le délimiteur de la consigne ne figure jamais
            // dans une réponse, et sa présence signe un bouton « copier » pris
            // sous le mauvais message. Un texte arrivait alors bien au curseur,
            // ce qui rendait la méprise invisible — c'est le prompt lui-même
            // qui s'écrivait dans l'éditeur.
            if !empreinteEnvoyee.isEmpty, texte.contains(empreinteEnvoyee) {
                Log.error("relais : copie de la demande au lieu de la réponse")
                throw Erreur.pasDeReponse
            }
            return texte
        }
        try Task.checkCancellation()
        throw Erreur.pasDeReponse
    }

    /// Attend que la réponse apparaisse, puis cesse de grandir — sans fin.
    ///
    /// ChatGPT écrit par flux : le texte s'allonge mot à mot. On attend donc
    /// deux secondes et demie sans changement, et non une (cf.
    /// `RelaisVeille.ReponseFinie`) : rien ne signale un texte coupé.
    ///
    /// Le calme se juge sur la longueur, et la réponse n'est lue qu'une fois,
    /// finie : relire tout son texte quatre fois par seconde forçait la page
    /// à se redisposer pendant qu'elle l'écrivait.
    private func attendreReponse() async throws -> String {
        var finie = RelaisVeille.ReponseFinie(seuil: 10)                  // ~2,5 s
        return try await veiller(.reponse, apresEnvoi: true) { vu -> String? in
            guard finie.juger(vu.reponse),
                  let texte = try? await lireReponse(sel: selecteurs.reponse), !texte.isEmpty
            else { return nil }
            return texte
        }
    }

    /// L'alerte apparue depuis la marque, reconnue ou non — pour
    /// **expliquer** un échec déjà constaté : la zone revenue vide, un envoi
    /// sans effet. Pendant une attente, c'est `RelaisVeille.refus` qui décide
    /// si une alerte en est un.
    private func alerteNouvelle() async -> String? {
        (try? await instantane(.alertes))?.echec?.texte
    }

    /// Annule une dictée en cours sans rien récupérer — au repos : l'arrêt
    /// après un abandon tourne dans une préparation (cf. `Relais.interrompre`).
    ///
    /// `ecouteQuiDemarre` : l'appui vient d'être abandonné, peut-être juste
    /// après le clic du micro. La page ne se met alors à écouter qu'une fois
    /// le micro accordé, quelques centaines de millisecondes plus tard :
    /// cliquer l'arrêt sur-le-champ ne trouvait rien, et ChatGPT se mettait
    /// ensuite à écouter hors champ, le micro de la machine avec lui.
    ///
    /// Une page muette qui ne tient pas le micro n'a rien à arrêter : la
    /// préparation qui suit la reconstruit. Tenant le micro, on essaie quand
    /// même l'arrêt — et l'appelant rend le micro de toute façon.
    func annuler(ecouteQuiDemarre: Bool = false) async {
        echo.desarmer()
        // Délai de geste : après le clic du micro, la page se met à écouter en
        // trois secondes au plus.
        let fin = Date.now.addingTimeInterval(ecouteQuiDemarre ? 3 : 0)
        var ecoute = false
        while true {
            let vu = await etatAuRepos()
            guard vu != nil || microOuvert else { return }
            ecoute = vu?.enregistrement == true || microOuvert
            if ecoute || Date.now >= fin || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // Un seul essai quand rien n'écoute, comme avant. Délai de geste quand
        // la page écoute : son bouton d'arrêt paraît en cinq secondes au plus.
        let finArret = Date.now.addingTimeInterval(ecoute ? 5 : 0)
        repeat {
            if await sonder({ try await self.cliquer(.stop, sel: self.selecteurs.stop) }) == true { break }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date.now < finArret && !Task.isCancelled
        // L'arrêt a pu déposer une transcription dans la zone.
        _ = await sonder { try await self.vider(sel: self.selecteurs.composeur) }
    }
}
