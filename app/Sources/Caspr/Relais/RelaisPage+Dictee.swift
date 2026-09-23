import AppKit
import CasprCore

// Ce que la page fait pendant une dictée : écouter, rendre la transcription,
// envoyer, attendre et récupérer la réponse, la faire lire, et se préparer à
// la suivante. Toutes les attentes consomment l'échéance unique de la dictée
// (`RelaisAttente`) et observent la page au lieu de chronométrer.
extension RelaisPage {
    /// La page est-elle en train d'écouter ?
    ///
    /// C'est la page qui fait foi, pas un drapeau tenu de notre côté. Un
    /// drapeau local se désynchronise à la première erreur — et il l'a fait :
    /// après un échec, l'application se croyait au repos pendant que ChatGPT
    /// enregistrait toujours, si bien que le geste suivant relançait une
    /// dictée par-dessus au lieu de l'arrêter.
    func estEnEnregistrement() async -> Bool {
        let r = try? await appeler("return window.__relais.etat(micro, stop, composeur);",
                                   ["micro": selecteurs.micro, "stop": selecteurs.stop,
                                    "composeur": selecteurs.composeur])
        return r?["enregistrement"] as? Bool == true
    }

    /// La page porte-t-elle une conversation ?
    ///
    /// Posée à la page, et non déduite du module qui vient de tourner : une
    /// réorganisation qui échoue à mi-chemin a tout de même envoyé son message,
    /// et c'est la page qui le sait.
    ///
    /// `nil` quand l'appel échoue, quelle qu'en soit la raison — page figée,
    /// pont absent, processus mort : ni oui ni non, et la seule préparation
    /// qui vaille alors est de la recharger. Une page en cours de chargement
    /// n'est pas interrogée (cf. `Relais.preparer`).
    func tientUneConversation() async -> Bool? {
        guard let r = try? await appeler("return window.__relais.etat(micro, stop, composeur);",
                                         ["micro": selecteurs.micro, "stop": selecteurs.stop,
                                          "composeur": selecteurs.composeur])
        else { return nil }
        return r["conversation"] as? Bool == true
    }

    /// Clique le micro. La page commence à écouter.
    func demarrer() async throws {
        lectureInterrompue = false
        // Vingt secondes, et non huit dixièmes : au tout premier appui d'une
        // session, la page peut encore être en train de se charger. Conclure
        // « pas connecté » à cet instant-là revenait à demander un second appui.
        switch await etatConnexion(patience: 50) {
        case .connecte:
            break
        case .inconnu:
            try Task.checkCancellation()
            throw Erreur.pontMuet
        case .deconnecte:
            montrer()
            throw Erreur.pasConnecte
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
        _ = try? await appeler("return window.__relais.vider(sel);",
                               ["sel": selecteurs.composeur])
        alertesAvant = await relever().alertes
        guard try await cliquerQuandDisponible(.micro, selecteurs.micro,
                                               jusqua: .now.addingTimeInterval(8)) else {
            throw Erreur.introuvable(.micro)
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
    /// La première va jusqu'à l'échéance de la dictée, et plus jusqu'à un
    /// budget à elle. La seconde n'attend plus ChatGPT : la zone est revenue,
    /// il reste à la voir immobile. Elle a donc sa borne propre, courte —
    /// assez pour une seconde de texte stable ou quatre de zone vide — et qui
    /// peut dépasser l'échéance (cf. `RelaisAttente.limite`) : coupée net, une
    /// zone revenue dans les dernières secondes faisait dire « n'a pas
    /// transcrit » devant la transcription affichée.
    func arreterEtLire(_ attente: RelaisAttente) async throws -> String {
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
        guard try await cliquerQuandDisponible(.stop, selecteurs.stop,
                                               jusqua: attente.limite(dans: 15)) else {
            try attente.verifier()
            throw Erreur.introuvable(.stop)
        }

        // L'échéance de la dictée, qui suit sa durée avec un plancher large.
        // Une transcription ne doit jamais être abandonnée parce qu'un chiffre
        // écrit d'avance la jugeait trop lente.
        //
        // Une échéance plutôt qu'un nombre de tours : chaque tour interroge la
        // page, et un tour dont l'appel attend son délai n'aurait plus duré un
        // quart de seconde. Compter les tours laissait donc une page figée
        // multiplier la patience par vingt.
        var revenue = false
        var tour = 0
        while !attente.expiree {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            if lu?["ok"] as? Bool == true { revenue = true; break }
            // Une fois par seconde : la page dit parfois elle-même qu'elle a
            // échoué, et l'attendre trois minutes de plus n'apprend rien.
            if tour % 4 == 3, let message = await erreurAffichee(nouvelles: false) {
                throw Erreur.refusParChatGPT(message)
            }
            tour += 1
        }
        guard revenue else {
            // Une alerte apparue pendant l'attente est la meilleure explication
            // qu'on ait. Elle n'interrompt pas l'attente — une bannière sans
            // rapport aurait sinon fait jeter une transcription qui aboutissait
            // — mais elle dit pourquoi l'attente a échoué.
            if let message = await erreurAffichee(nouvelles: true) {
                throw Erreur.refusParChatGPT(message)
            }
            throw attente.epuisee()
        }

        // Phase 2 : la stabilisation. Une seconde pleine sans changement, et
        // non 500 ms : le flux marque entre deux fragments des pauses plus
        // longues qu'on ne l'imagine, et c'est précisément là que le seuil
        // précédent coupait la phrase.
        let finStabilisation = max(attente.echeance, Date.now.addingTimeInterval(5))
        var precedent = ""
        var stable = 0
        var vide = 0
        while Date.now < finStabilisation {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            // Un appel resté sans réponse ne dit rien du texte : le compter
            // comme une zone vide finirait par conclure « rien n'a été dit »
            // devant une page simplement lente.
            guard let lu = try? await appeler("return window.__relais.lire(sel);",
                                              ["sel": selecteurs.composeur])
            else { continue }
            let texte = (lu["texte"] as? String) ?? ""

            // La zone est revenue et reste vide : il n'y avait rien à
            // transcrire. Appuyer sur la touche sans parler est un geste
            // ordinaire — on se ravise, on est interrompu — et il laissait la
            // barre sur « Transcription… » jusqu'à l'expiration d'une minute,
            // sans autre issue qu'Échap.
            //
            // Quatre secondes, et non une : dans le cas normal, la zone
            // revient déjà remplie, mais rien ne garantit que les deux
            // arrivent au même instant. Attendre un peu coûte moins qu'un faux
            // « rien entendu » sur une dictée réelle.
            if texte.isEmpty {
                vide += 1
                if vide >= 16 {
                    // Sauf si la page dit pourquoi : un refus — un quota
                    // atteint, par exemple — rend lui aussi la zone vide, et
                    // « avez-vous parlé ? » ferait chercher la panne au micro.
                    if let message = await erreurAffichee(nouvelles: true) {
                        throw Erreur.refusParChatGPT(message)
                    }
                    Log.info("relais : la zone est revenue vide — rien n'a été dicté")
                    return ""
                }
            } else {
                vide = 0
            }

            if !texte.isEmpty && texte == precedent {
                stable += 1
                if stable >= 4 {                            // ~1 s sans changement
                    // On ne vide pas ici. `demarrer()` le fait avant chaque
                    // dictée, ce qui suffit à empêcher toute concaténation, et
                    // vider exige de focaliser la zone — l'opération même qui
                    // détournait le curseur système. La faire à l'instant
                    // précis où Caspr s'apprête à insérer au curseur serait le
                    // pire moment possible. Le texte laissé dans la page est
                    // en prime un filet : il reste copiable si l'insertion
                    // échoue.
                    return texte
                }
            } else {
                stable = 0
            }
            precedent = texte
        }
        // Un texte qui bouge encore après tout cela n'est pas rendu : coupé
        // au milieu, il s'insérerait sans que rien signale la coupure, ce qui
        // est pire que pas de texte. Il reste dans la page, que l'échec
        // ouvre pour qu'on l'y copie.
        throw attente.epuisee()
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
    /// où le bouton est là au premier essai.
    ///
    /// Une date de fin et non une durée : après l'arrêt de l'écoute, la borne
    /// propre au bouton ne doit jamais dépasser l'échéance de la dictée (cf.
    /// `RelaisAttente.limite`).
    private func cliquerQuandDisponible(_ cible: RelaisCible, _ selecteur: String,
                                        jusqua limite: Date) async throws -> Bool {
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
        // Une transcription qui a pris tout le temps de la dictée ne laisse
        // rien pour la suite : on n'entame pas un envoi qu'on abandonnerait à
        // mi-chemin, consigne posée dans la zone.
        try attente.verifier()
        if !encadrement.avant.isEmpty || !encadrement.apres.isEmpty {
            let r = try await appeler("return window.__relais.encadrer(sel, avant, apres);",
                                      ["sel": selecteurs.composeur,
                                       "avant": encadrement.avant,
                                       "apres": encadrement.apres])
            guard r["ok"] as? Bool == true else { throw Erreur.introuvable(.composeur) }
            guard try await attendreEncadrement(empreinte(encadrement.avant), attente) else {
                throw Erreur.consigneNonPosee
            }
        }
        (alertesAvant, reponsesAvantEnvoi) = await relever()
        guard try await cliquerQuandDisponible(.envoi, selecteurs.envoi,
                                               jusqua: attente.limite(dans: 10)) else {
            try attente.verifier()
            throw Erreur.introuvable(.envoi)
        }
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
        try attente.verifier()                     // cf. `envoyerSansAttendre`
        let r = try await appeler("return window.__relais.encadrer(sel, avant, apres);",
                                  ["sel": selecteurs.composeur,
                                   "avant": encadrement.avant,
                                   "apres": encadrement.apres])
        guard r["ok"] as? Bool == true else { throw Erreur.introuvable(.composeur) }

        // Attendre que l'insertion ait pris, et non une demi-seconde décidée
        // d'avance. L'envoi partait avant que l'éditeur n'ait validé le texte
        // ajouté : seule la transcription brute était expédiée, sans la
        // consigne qui lui donne son sens. Un délai fixe marcherait jusqu'au
        // jour où la machine rame ; une relecture, non.
        guard try await attendreEncadrement(empreinte(encadrement.avant), attente) else {
            throw Erreur.consigneNonPosee
        }

        (alertesAvant, reponsesAvantEnvoi) = await relever()
        guard try await cliquerQuandDisponible(.envoi, selecteurs.envoi,
                                               jusqua: attente.limite(dans: 10)) else {
            try attente.verifier()
            throw Erreur.introuvable(.envoi)
        }
        attente.entrer(.reponse)
        // Le bouton de ChatGPT quand on sait où il est, la lecture du DOM
        // sinon — pour ne pas casser une configuration antérieure.
        let reponse = selecteurs.saitCopier
            ? try await copierReponse(attente: attente,
                                      empreinteEnvoyee: empreinte(encadrement.avant))
            : try await attendreReponse(attente: attente)
        // Pas de rechargement ici : la page neuve est ouverte à la fin de la
        // dictée, par la préparation de la suivante (cf.
        // `Relais.preparerLaProchaine`), pour toutes les dictées et au même
        // endroit. En recharger une seconde fois depuis ce chemin-ci, c'était
        // une deuxième politique de fil neuf — celle qui ne s'appliquait
        // qu'aux réorganisations réussies, et laissait donc la conversation en
        // place quand elles échouaient.
        return reponse
    }

    /// La dernière ligne non vide de la consigne — le délimiteur.
    ///
    /// Meilleure empreinte que le début du texte : elle est courte, très
    /// distinctive, et elle ne souffre pas de la façon dont la page replie les
    /// espaces d'un long paragraphe.
    private func empreinte(_ avant: String) -> String {
        avant.split(separator: "\n").last.map(String.init) ?? avant
    }

    /// Attend que la consigne soit réellement dans la zone de saisie.
    private func attendreEncadrement(_ empreinte: String,
                                     _ attente: RelaisAttente) async throws -> Bool {
        guard !empreinte.isEmpty else { return true }
        let limite = attente.limite(dans: 6)
        while Date.now < limite {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteurs.composeur])
            if let texte = lu?["texte"] as? String, texte.contains(empreinte) { return true }
        }
        try attente.verifier()
        Log.error("relais : la consigne n'a pas tenu dans la zone de saisie")
        return false
    }

    /// Attend que la page rechargée soit prête, zone de saisie comprise.
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
            let lu = try? await appeler("return window.__relais.lire(sel);", ["sel": ""])
            if lu?["ok"] as? Bool == true { return true }
        }
        return false
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
    /// Un échec n'interrompt rien : la réponse est à l'écran, seul le son
    /// manque. Faire échouer la dictée entière pour un haut-parleur muet serait
    /// disproportionné.
    ///
    /// Sauf un refus : un quota atteint, et aucune réponse ne viendra. Le
    /// guetter comme `copierReponse`, une fois par seconde, évite d'attendre
    /// l'échéance pour rien ; il est rendu pour que la barre le montre, comme
    /// l'échéance elle-même quand elle passe sans réponse.
    ///
    /// - Parameter dejaFinie: la réponse est connue pour finie — elle vient
    ///   d'être copiée, et le texte attend ce clic pour s'insérer. Le premier
    ///   relevé qui la montre suffit, sans deux secondes de stabilité à
    ///   prouver ; et la borne est propre, dix secondes même au-delà de
    ///   l'échéance (cf. `RelaisAttente.limite`) : cette attente-là ne guette
    ///   plus ChatGPT, et la couper jetait la voix d'une réponse obtenue.
    @discardableResult
    func faireLireLaReponse(attente: RelaisAttente,
                            dejaFinie: Bool = false) async -> Erreur? {
        guard selecteurs.saitLire else { return nil }
        attente.entrer(.reponse)
        let limite = dejaFinie ? Date.now.addingTimeInterval(10) : attente.echeance
        var precedent = ""
        var stable = 0
        var prete = false
        // Une réponse nouvelle a-t-elle paru, même inachevée ?
        var reponseVue = false
        var tour = 0
        var silences = 0
        while Date.now < limite {
            defer { tour += 1 }
            if Task.isCancelled || lectureInterrompue { return nil }
            if morteDepuisLeDepart { return .pageInterrompue }
            try? await Task.sleep(for: .milliseconds(250))
            if tour % 4 == 3, let message = await refusPendantLAttente(silences: &silences) {
                Log.error("relais : ChatGPT a refusé (« \(message) »), lecture abandonnée")
                return .refusParChatGPT(message)
            }
            guard let r = try? await appeler("return window.__relais.etatReponse(avant);",
                                             ["avant": reponsesAvantEnvoi]),
                  r["nouvelle"] as? Bool == true
            else { stable = 0; continue }
            let texte = (r["texte"] as? String) ?? ""
            if !texte.isEmpty { reponseVue = true }
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
            // L'attente a expiré : une alerte apparue depuis l'envoi est la
            // meilleure explication qu'on ait.
            if let message = await erreurAffichee(nouvelles: true) {
                Log.error("relais : ChatGPT a refusé (« \(message) »), lecture abandonnée")
                return .refusParChatGPT(message)
            }
            // Une réponse qu'on a vue n'est pas une réponse absente : elle est
            // à l'écran, encore en cours peut-être, et seul le son manque.
            // « ChatGPT n'a pas répondu », en rouge devant elle, était faux.
            if reponseVue || dejaFinie {
                Log.error("relais : réponse pas finie à temps, lecture à haute voix abandonnée")
                return nil
            }
            // À défaut, l'échéance passée est l'explication, et elle se dit.
            return attente.expiree ? attente.epuisee() : nil
        }

        attente.entrer(.lecture)
        // Le clic lui-même, répété quelques secondes : la barre d'actions de
        // la réponse s'affiche juste après la fin de la génération, pas au
        // même instant. Sa borne propre, même au-delà de l'échéance : la
        // réponse est là, ce clic n'attend plus ChatGPT.
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

    /// Vide la zone de saisie, et s'assure qu'elle l'est restée.
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
        _ = try? await appeler("return window.__relais.oublierBrouillon();")
        let limite = Date.now.addingTimeInterval(6)
        while Date.now < limite {
            if Task.isCancelled { return false }
            _ = try? await appeler("return window.__relais.vider(sel);", ["sel": sel])
            try? await Task.sleep(for: .milliseconds(500))
            let lu = try? await appeler("return window.__relais.lire(sel);", ["sel": sel])
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
    /// Le presse-papiers est rendu tel qu'on l'a trouvé : il appartient à
    /// l'utilisateur, et une dictée n'a pas à lui faire perdre ce qu'il y
    /// gardait.
    private func copierReponse(attente: RelaisAttente,
                               empreinteEnvoyee: String) async throws -> String {
        let presse = NSPasteboard.general
        let avant = presse.changeCount
        let sauvegarde = presse.string(forType: .string)

        var clique = false
        var tour = 0
        var silences = 0
        while !attente.expiree {
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            let r = try? await appeler(
                "return window.__relais.copierLaReponse(selParent, selCopier, selReponse);",
                ["selParent": selecteurs.copierParent,
                 "selCopier": selecteurs.copier,
                 "selReponse": selecteurs.reponse])
            if r?["ok"] as? Bool == true {
                // La voie suivie — la paire, ou le repère sans bloc —, pour
                // que le prochain défaut se lise dans le journal plutôt que
                // dans une capture.
                Log.info("relais : copier cliqué (\(r?["voie"] ?? "?"))")
                clique = true
                break
            }
            // Une fois par seconde, comme ailleurs. À chaque tour, la sonde
            // relisait le texte de centaines d'éléments quatre fois par
            // seconde — `innerText` force la page à recalculer sa disposition
            // — au risque de ralentir la génération même qu'on attendait.
            if tour % 4 == 3, let message = await refusPendantLAttente(silences: &silences) {
                throw Erreur.refusParChatGPT(message)
            }
            tour += 1
        }
        guard clique else {
            if let message = await erreurAffichee(nouvelles: true) {
                throw Erreur.refusParChatGPT(message)
            }
            throw attente.epuisee()
        }

        // Le clic est asynchrone côté page : on attend que le presse-papiers
        // change plutôt que de le lire aussitôt.
        //
        // Dix secondes à elle, même au-delà de l'échéance : la réponse est
        // finie et copiée, il ne reste qu'à la ramasser. Couper ici jetterait
        // un texte obtenu, et laisserait la copie écraser le presse-papiers
        // sans qu'on le rende.
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
            presse.clearContents()
            if let sauvegarde { presse.setString(sauvegarde, forType: .string) }
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

    /// Attend que la réponse apparaisse, puis cesse de grandir.
    ///
    /// ChatGPT écrit par flux : le texte s'allonge mot à mot. On attend donc
    /// deux secondes et demie sans changement, et non une — les pauses entre
    /// deux fragments d'une longue réponse dépassent régulièrement la seconde,
    /// et un seuil trop court rendrait un texte coupé au milieu, ce qui est
    /// pire que pas de texte du tout : rien ne signale la coupure.
    private func attendreReponse(attente: RelaisAttente) async throws -> String {
        var precedent = ""
        var stable = 0
        var tour = 0
        var silences = 0
        while !attente.expiree {
            defer { tour += 1 }
            try Task.checkCancellation()
            try verifierLaPage()
            try? await Task.sleep(for: .milliseconds(250))
            let lu = try? await appeler("return window.__relais.lireReponse(sel);",
                                        ["sel": selecteurs.reponse])
            let texte = (lu?["texte"] as? String) ?? ""
            if !texte.isEmpty && texte == precedent {
                stable += 1
                if stable >= 10 { return texte }          // ~2,5 s sans changement
            } else {
                stable = 0
            }
            precedent = texte
            if tour % 4 == 3, let message = await refusPendantLAttente(silences: &silences) {
                throw Erreur.refusParChatGPT(message)
            }
        }
        if let message = await erreurAffichee(nouvelles: true) {
            throw Erreur.refusParChatGPT(message)
        }
        throw attente.epuisee()
    }

    /// Le message d'échec que ChatGPT affiche, s'il est apparu depuis le
    /// dernier relevé.
    ///
    /// Les motifs d'échec restent étroits, délibérément (cf. `erreur()` dans
    /// le pont). `nouvelles` y ajoute toute alerte apparue depuis le relevé,
    /// quelle que soit sa formulation — mais pour **expliquer** un échec déjà
    /// constaté seulement : l'attente a expiré, la zone est revenue vide. Elle
    /// n'interrompt alors plus rien. Pendant l'attente d'une réponse, c'est
    /// `refusPendantLAttente` qui décide.
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

    /// Annule une dictée en cours sans rien récupérer.
    ///
    /// `ecouteQuiDemarre` : l'appui vient d'être abandonné, peut-être juste
    /// après le clic du micro. La page ne se met alors à écouter qu'une fois
    /// le micro accordé, quelques centaines de millisecondes plus tard :
    /// cliquer l'arrêt sur-le-champ ne trouvait rien, et ChatGPT se mettait
    /// ensuite à écouter hors champ, le micro de la machine avec lui. On
    /// observe donc qu'elle écoute, trois secondes au plus, avant d'arrêter.
    func annuler(ecouteQuiDemarre: Bool = false) async {
        let fin = Date.now.addingTimeInterval(ecouteQuiDemarre ? 3 : 0)
        var ecoute = await estEnEnregistrement() || microOuvert
        while !ecoute, Date.now < fin, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            ecoute = await estEnEnregistrement() || microOuvert
        }
        // Un seul essai quand rien n'écoute, comme avant ; quelques secondes
        // quand la page écoute, le temps que l'arrêt paraisse.
        _ = try? await cliquerQuandDisponible(
            .stop, selecteurs.stop, jusqua: .now.addingTimeInterval(ecoute ? 5 : 0))
        // L'arrêt a pu déposer une transcription dans la zone.
        _ = try? await appeler("return window.__relais.vider(sel);",
                               ["sel": selecteurs.composeur])
    }
}
