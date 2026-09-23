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
        await etatAuRepos()?["enregistrement"] as? Bool == true
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
        guard let r = await etatAuRepos() else { return nil }
        return r["conversation"] as? Bool == true
    }

    private func etatAuRepos() async -> [String: Any]? {
        await sonder("return window.__relais.etat(micro, stop, composeur);",
                     ["micro": selecteurs.micro, "stop": selecteurs.stop,
                      "composeur": selecteurs.composeur])
    }

    /// Clique le micro. La page commence à écouter.
    ///
    /// `siLaSessionTarde` : la page ne s'est pas dite connectée au premier
    /// relevé. La barre le dit alors, avec la sortie (cf.
    /// `VoieChatGPT.demarrer`) : l'attente qui suit n'a pas de fin.
    func demarrer(siLaSessionTarde: () -> Void = {}) async throws {
        lectureInterrompue = false
        try await attendreLaSession(siElleTarde: siLaSessionTarde)
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
        _ = try? await appeler("return window.__relais.vider(sel);",
                               ["sel": selecteurs.composeur])
        alertesAvant = await relever().alertes
        // Délai de geste : le bouton micro existe dès que la page s'est dite
        // connectée ; huit secondes sans lui, et il est introuvable.
        guard try await cliquerQuandDisponible(.micro, selecteurs.micro, pendant: 8) else {
            throw Erreur.introuvable(.micro)
        }
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
    /// de la page qu'on quitte.
    private func attendreLaSession(siElleTarde: () -> Void) async throws {
        var premier = true
        while true {
            try Task.checkCancellation()
            if !chargementEnCours,
               let r = try? await appeler("return window.__relais.etat(micro, stop, composeur);",
                                          ["micro": selecteurs.micro, "stop": selecteurs.stop,
                                           "composeur": selecteurs.composeur]) {
                if r["connecte"] as? Bool == true {
                    surConnexion?(.connecte)
                    return
                }
                if r["authentification"] as? Bool == true {
                    surConnexion?(.deconnecte)
                    montrer()
                    throw Erreur.pasConnecte
                }
            }
            if premier {
                premier = false
                siElleTarde()
            }
            try await Task.sleep(for: .milliseconds(400))
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
        guard try await cliquerQuandDisponible(.stop, selecteurs.stop, pendant: 15) else {
            throw Erreur.introuvable(.stop)
        }

        // La page dit parfois elle-même qu'elle a échoué : c'est la seule
        // chose, avec l'utilisateur, qui interrompe l'attente.
        let refus = { await self.erreurAffichee(nouvelles: false) }
        try await veiller(refus) { () -> Bool? in
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            return lu?["ok"] as? Bool == true ? true : nil
        }

        // La stabilisation. Une seconde pleine sans changement, et non
        // 500 ms : le flux marque entre deux fragments des pauses plus
        // longues qu'on ne l'imagine, et c'est précisément là que le seuil
        // précédent coupait la phrase. Un texte qui bouge encore n'est jamais
        // rendu : coupé au milieu, il s'insérerait sans que rien signale la
        // coupure, ce qui est pire que pas de texte.
        var precedent = ""
        var stable = 0
        var vide = 0
        return try await veiller(refus) { () -> String? in
            // Un appel qui échoue ne dit rien du texte : le compter comme une
            // zone vide finirait par conclure « rien n'a été dit » devant une
            // page qui en a.
            guard let lu = try? await appeler("return window.__relais.lire(sel);",
                                              ["sel": selecteurs.composeur])
            else { return nil }
            let texte = (lu["texte"] as? String) ?? ""
            defer { precedent = texte }

            // La zone est revenue et reste vide : il n'y avait rien à
            // transcrire. Appuyer sur la touche sans parler est un geste
            // ordinaire — on se ravise, on est interrompu — et il laissait la
            // barre sur « Transcription… » sans autre issue qu'Échap.
            //
            // Quatre secondes, et non une : dans le cas normal, la zone
            // revient déjà remplie, mais rien ne garantit que les deux
            // arrivent au même instant. C'est un jugement sur une zone
            // revenue, pas une échéance : ChatGPT a déjà rendu la main.
            guard !texte.isEmpty else {
                stable = 0
                vide += 1
                guard vide >= 16 else { return nil }
                // Sauf si la page dit pourquoi : un refus — un quota atteint,
                // par exemple — rend lui aussi la zone vide, et « avez-vous
                // parlé ? » ferait chercher la panne au micro.
                if let message = await erreurAffichee(nouvelles: true) {
                    throw Erreur.refusParChatGPT(message)
                }
                Log.info("relais : la zone est revenue vide — rien n'a été dicté")
                return ""
            }
            vide = 0
            guard texte == precedent else { stable = 0; return nil }
            stable += 1
            // ~1 s sans changement. On ne vide pas ici. `demarrer()` le fait
            // avant chaque dictée, ce qui suffit à empêcher toute
            // concaténation, et vider exige de focaliser la zone — l'opération
            // même qui détournait le curseur système. La faire à l'instant
            // précis où Caspr s'apprête à insérer au curseur serait le pire
            // moment possible. Le texte laissé dans la page est en prime un
            // filet : il reste copiable si l'insertion échoue.
            return stable >= 4 ? texte : nil
        }
    }

    /// L'attente sans fin d'une dictée : un relevé par quart de seconde,
    /// jusqu'à ce que `juger` rende une valeur.
    ///
    /// Une fois par seconde, les échecs que la page prouve : un refus selon
    /// `refus`, et l'écran d'authentification. La mort du processus se lit à
    /// chaque tour. Le reste appartient à l'utilisateur : l'annulation de la
    /// tâche tranche l'attente, appel au pont en suspens compris (cf.
    /// `appeler`).
    @discardableResult
    private func veiller<T>(_ refus: () async -> String?,
                            _ juger: () async throws -> T?) async throws -> T {
        var tour = 0
        while true {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            if let valeur = try await juger() { return valeur }
            tour += 1
            guard tour % 4 == 0 else { continue }
            if let message = await refus() { throw Erreur.refusParChatGPT(message) }
            if await sessionMontreeFermee() { throw Erreur.pasConnecte }
        }
    }

    /// La page montre-t-elle l'écran de connexion ?
    ///
    /// L'échec prouvé qu'une échéance rattrapait jusqu'ici : une session
    /// perdue en pleine attente ne rendra jamais rien, et sans ce relevé
    /// l'attente — désormais sans fin — le serait pour de bon.
    private func sessionMontreeFermee() async -> Bool {
        guard let r = try? await appeler("return window.__relais.etat(micro, stop, composeur);",
                                         ["micro": selecteurs.micro, "stop": selecteurs.stop,
                                          "composeur": selecteurs.composeur]),
              r["authentification"] as? Bool == true
        else { return false }
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
            let r = try await appeler("return window.__relais.cliquer(cible, sel);",
                                      ["cible": cible.rawValue, "sel": selecteur])
            if r["ok"] as? Bool == true {
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
        try await cliquerLEnvoi()
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
        try await cliquerLEnvoi()
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
            ? try await copierReponse(empreinteEnvoyee: empreinte(encadrement.avant))
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
        let r = try await appeler("return window.__relais.encadrer(sel, avant, apres);",
                                  ["sel": selecteurs.composeur,
                                   "avant": encadrement.avant,
                                   "apres": encadrement.apres])
        guard r["ok"] as? Bool == true else { throw Erreur.introuvable(.composeur) }
        let empreinte = empreinte(encadrement.avant)
        guard !empreinte.isEmpty else { return }
        // Délai de geste : ce qu'on vient d'écrire se relit aussitôt, ou n'a
        // pas pris ; six secondes laissent large à une machine qui rame.
        let limite = Date.now.addingTimeInterval(6)
        while Date.now < limite {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            if let texte = lu?["texte"] as? String, texte.contains(empreinte) { return }
        }
        Log.error("relais : la consigne n'a pas tenu dans la zone de saisie")
        throw Erreur.consigneNonPosee
    }

    /// Clique l'envoi, en relevant d'abord ce que la page affiche : seule une
    /// alerte ou une réponse apparue depuis compte.
    private func cliquerLEnvoi() async throws {
        (alertesAvant, reponsesAvantEnvoi) = await relever()
        // Délai de geste : le bouton d'envoi existe dès que la zone est
        // remplie ; dix secondes sans lui, et il est introuvable.
        guard try await cliquerQuandDisponible(.envoi, selecteurs.envoi, pendant: 10) else {
            throw Erreur.introuvable(.envoi)
        }
    }

    /// La dernière ligne non vide de la consigne — le délimiteur.
    ///
    /// Meilleure empreinte que le début du texte : elle est courte, très
    /// distinctive, et elle ne souffre pas de la façon dont la page replie les
    /// espaces d'un long paragraphe.
    private func empreinte(_ avant: String) -> String {
        avant.split(separator: "\n").last.map(String.init) ?? avant
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
            let lu = await sonder("return window.__relais.lire(sel);", ["sel": ""])
            if lu?["ok"] as? Bool == true { return true }
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
        let suspendus = enSuspens
        for appel in suspendus { appel.rendre(.failure(CancellationError())) }
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
        var precedent = ""
        var stable = 0
        var prete = false
        var tour = 0
        var silences = 0
        while limite.map({ Date.now < $0 }) ?? true {
            defer { tour += 1 }
            if Task.isCancelled || lectureInterrompue { return nil }
            if morteDepuisLeDepart { return .pageInterrompue }
            try? await Task.sleep(for: .milliseconds(250))
            if tour % 4 == 3 {
                if let message = await refusPendantLAttente(silences: &silences) {
                    Log.error("relais : ChatGPT a refusé (« \(message) »), lecture abandonnée")
                    return .refusParChatGPT(message)
                }
                if await sessionMontreeFermee() { return .pasConnecte }
            }
            guard let r = try? await appeler("return window.__relais.etatReponse(avant);",
                                             ["avant": reponsesAvantEnvoi]),
                  r["nouvelle"] as? Bool == true
            else { stable = 0; continue }
            let texte = (r["texte"] as? String) ?? ""
            let finie = r["enCours"] as? Bool != true && !texte.isEmpty
            if dejaFinie, finie { prete = true; break }
            if finie, texte == precedent {
                stable += 1
                if stable >= 8 { prete = true; break }      // ~2 s sans changement
            } else {
                stable = 0
            }
            precedent = texte
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
                let r = try? await appeler("return window.__relais.cliquerBouton(parent, bouton);",
                                           ["parent": parent, "bouton": bouton])
                if r?["ok"] as? Bool == true { return true }
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
        _ = await sonder("return window.__relais.oublierBrouillon();")
        let limite = Date.now.addingTimeInterval(6)
        while Date.now < limite {
            if Task.isCancelled { return false }
            _ = await sonder("return window.__relais.vider(sel);", ["sel": sel])
            try? await Task.sleep(for: .milliseconds(500))
            let lu = await sonder("return window.__relais.lire(sel);", ["sel": sel])
            if let texte = lu?["texte"] as? String, texte.isEmpty { return true }
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

        // Jusqu'au clic, sans fin. Le refus se guette une fois par seconde,
        // comme ailleurs : à chaque tour, la sonde relisait le texte de
        // centaines d'éléments quatre fois par seconde — `innerText` force la
        // page à recalculer sa disposition — au risque de ralentir la
        // génération même qu'on attendait.
        var silences = 0
        let voie = try await veiller({ await refusPendantLAttente(silences: &silences) }) {
            () -> String? in
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
            let r = try? await appeler(
                "return window.__relais.copierLaReponse(selParent, selCopier, selReponse);",
                ["selParent": selecteurs.copierParent,
                 "selCopier": selecteurs.copier,
                 "selReponse": selecteurs.reponse])
            return r?["ok"] as? Bool == true ? (r?["voie"] as? String) ?? "?" : nil
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
    /// deux secondes et demie sans changement, et non une — les pauses entre
    /// deux fragments d'une longue réponse dépassent régulièrement la seconde,
    /// et un seuil trop court rendrait un texte coupé au milieu, ce qui est
    /// pire que pas de texte du tout : rien ne signale la coupure.
    private func attendreReponse() async throws -> String {
        var precedent = ""
        var stable = 0
        var silences = 0
        return try await veiller({ await refusPendantLAttente(silences: &silences) }) {
            () -> String? in
            let lu = try? await appeler("return window.__relais.lireReponse(sel);",
                                        ["sel": selecteurs.reponse])
            let texte = (lu?["texte"] as? String) ?? ""
            defer { precedent = texte }
            guard !texte.isEmpty, texte == precedent else { stable = 0; return nil }
            stable += 1
            return stable >= 10 ? texte : nil                // ~2,5 s sans changement
        }
    }

    /// Le message d'échec que ChatGPT affiche, s'il est apparu depuis le
    /// dernier relevé.
    ///
    /// Les motifs d'échec restent étroits, délibérément (cf. `erreur()` dans
    /// le pont). `nouvelles` y ajoute toute alerte apparue depuis le relevé,
    /// quelle que soit sa formulation — mais pour **expliquer** un échec déjà
    /// constaté seulement : la zone est revenue vide. Pendant l'attente d'une
    /// réponse, c'est `refusPendantLAttente` qui décide.
    private func erreurAffichee(nouvelles: Bool) async -> String? {
        let r = try? await appeler("return window.__relais.erreur(connues, nouvelles, -1);",
                                   ["connues": alertesAvant, "nouvelles": nouvelles])
        let message = (r?["message"] as? String) ?? ""
        return message.isEmpty ? nil : message
    }

    /// Un refus de ChatGPT, pendant qu'on attend sa réponse.
    ///
    /// Un échec reconnu par ses motifs interrompt l'attente sur-le-champ. Une
    /// alerte nouvelle qu'aucun motif ne connaît — un quota atteint à
    /// l'instant — ne compte, elle, que tant que ChatGPT ne répond pas :
    /// aucune réponse nouvelle, aucune génération en cours (cf. `erreur()`).
    /// Sans cette condition, une bannière « limite bientôt atteinte » apparue
    /// à l'envoi faisait jeter la réponse que ChatGPT était en train d'écrire.
    ///
    /// Et ce silence doit durer trois relevés d'affilée : juste après l'envoi,
    /// la réponse met un instant à paraître, et une bannière tombée dans ce
    /// creux passerait sinon pour un refus.
    private func refusPendantLAttente(silences: inout Int) async -> String? {
        guard let r = try? await appeler(
            "return window.__relais.erreur(connues, true, avant);",
            ["connues": alertesAvant, "avant": reponsesAvantEnvoi])
        else { return nil }
        let message = (r["message"] as? String) ?? ""
        guard !message.isEmpty else { silences = 0; return nil }
        if r["reconnue"] as? Bool == true { return message }
        silences += 1
        return silences >= 3 ? message : nil
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
        // Délai de geste : après le clic du micro, la page se met à écouter en
        // trois secondes au plus.
        let fin = Date.now.addingTimeInterval(ecouteQuiDemarre ? 3 : 0)
        var ecoute = false
        while true {
            let etat = await etatAuRepos()
            guard etat != nil || microOuvert else { return }
            ecoute = etat?["enregistrement"] as? Bool == true || microOuvert
            if ecoute || Date.now >= fin || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // Un seul essai quand rien n'écoute, comme avant. Délai de geste quand
        // la page écoute : son bouton d'arrêt paraît en cinq secondes au plus.
        let finArret = Date.now.addingTimeInterval(ecoute ? 5 : 0)
        repeat {
            let r = await sonder("return window.__relais.cliquer(cible, sel);",
                                 ["cible": RelaisCible.stop.rawValue, "sel": selecteurs.stop])
            if r?["ok"] as? Bool == true { break }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date.now < finArret && !Task.isCancelled
        // L'arrêt a pu déposer une transcription dans la zone.
        _ = await sonder("return window.__relais.vider(sel);", ["sel": selecteurs.composeur])
    }
}
