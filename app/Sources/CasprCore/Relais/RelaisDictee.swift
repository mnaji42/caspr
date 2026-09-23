import Foundation

/// La page, telle que la voit le scénario d'une dictée : ce qu'on lui
/// demande, et rien de WebKit. La vraie est `RelaisPage` ; les tests en
/// rejouent une factice, aux relevés écrits d'avance.
@MainActor
public protocol RelaisPageDictee: AnyObject {
    /// Augmente à chaque mort du processus de la page : une dictée qui la
    /// relève sait que la page qu'elle attend n'existe plus.
    var epoque: Int { get }
    /// Une page arrive : ce qu'on y verrait est celle qu'on quitte.
    var chargementEnCours: Bool { get }
    var microOuvert: Bool { get }
    var selecteurs: RelaisSelecteurs { get }
    func instantane(_ demande: RelaisDemande) async throws -> RelaisInstantane
    /// Pose la marque : ce qui apparaît ensuite est nouveau.
    func marquer() async throws
    func cliquer(_ cible: RelaisCible) async throws -> Bool
    func vider() async throws
    func encadrer(avant: String, apres: String) async throws -> Bool
    /// Clique « copier » ; la voie suivie, `nil` quand rien n'a été cliqué.
    func copier() async throws -> String?
    /// Clique l'ouvre-menu de la lecture à haute voix (`menu`), ou le bouton.
    func cliquerLecture(menu: Bool) async throws -> Bool
    /// Le texte de la dernière réponse ; `nil` quand elle est introuvable.
    func lireReponse() async throws -> String?
    func armerEcho()
    func desarmerEcho()
}

/// Le presse-papiers de l'utilisateur, où le bouton « copier » de ChatGPT
/// écrit la réponse.
@MainActor
public protocol RelaisPressePapiers: AnyObject {
    var changeCount: Int { get }
    func texte() -> String?
    /// Garde tout son contenu ; rend de quoi le remettre tel quel.
    func sauvegarder() -> () -> Void
}

/// Le scénario d'une dictée ChatGPT : écouter, rendre la transcription,
/// envoyer, récupérer la réponse, la faire lire. Un par dictée.
///
/// LA RÈGLE (RELAIS.md, sixième règle). Sur le chemin d'une dictée, une
/// attente de ChatGPT ne finit que par un geste de l'utilisateur — la touche
/// de dictée, Échap pendant l'écoute, qui annulent la tâche — ou par un échec
/// que la page PROUVE : une alerte de refus apparue depuis la demande, le
/// processus WebKit mort, l'écran d'authentification montré. Jamais par le
/// temps. Restent les délais de geste, tous dans `RelaisDelai`.
///
/// Toutes les attentes passent par `observer` : une seule façon d'attendre,
/// et une seule place pour chaque preuve.
@MainActor
public final class RelaisDictee {
    private let page: RelaisPageDictee
    private let presse: RelaisPressePapiers
    private let horloge: RelaisHorloge

    /// Le journal de l'application : le message, et s'il dit une panne.
    public var journal: (_ message: String, _ erreur: Bool) -> Void = { _, _ in }
    /// La page a **montré** la session : connectée à l'ouverture de
    /// l'écoute, fermée quand l'écran d'authentification paraît.
    public var surSession: (_ connectee: Bool) -> Void = { _ in }

    /// L'époque de la page qui s'est dite connectée ; `nil` avant.
    private var epoque: Int?
    /// La marque est posée : les échecs se relèvent depuis elle.
    private var marquee = false
    /// Le message est parti : une alerte inconnue peut alors être un refus.
    private var envoye = false
    /// Ce qui, dans la zone, signe la consigne envoyée (cf.
    /// `RelaisVeille.empreinte`).
    private var empreinte = ""
    private var lecture: Task<RelaisErreur?, Never>?

    /// L'appui a demandé de ne plus attendre la lecture à haute voix.
    public private(set) var lectureInterrompue = false

    /// La page que cette dictée a prise est-elle morte depuis ?
    public var pageMorte: Bool { epoque.map { $0 != page.epoque } ?? false }

    public init(page: RelaisPageDictee, pressePapiers: RelaisPressePapiers,
                horloge: RelaisHorloge = RelaisHorlogeReelle()) {
        self.page = page
        self.presse = pressePapiers
        self.horloge = horloge
    }

    // MARK: - Écouter

    /// Attend la session, vide la zone, pose la marque et clique le micro.
    ///
    /// La session s'attend **sans fin**. Au tout premier appui d'une session,
    /// chatgpt.com se charge encore, à froid ; conclure « pas connecté » à cet
    /// instant-là demandait un second appui, et le conclure faute de réponse
    /// envoyait chercher un mot de passe devant une page seulement lente. Seul
    /// l'écran d'authentification fait échouer : une page qui ne dit rien est
    /// attendue, et la touche de dictée en sort.
    ///
    /// `siElleTarde` : la page ne s'est pas dite connectée tout de suite, ou
    /// ne s'est pas mise à écouter peu après. La barre le dit alors, avec la
    /// sortie : l'attente qui suit n'a pas de fin.
    public func ouvrirLEcoute(siElleTarde: @escaping @MainActor () -> Void = {}) async throws {
        // L'annonce ne dépend pas du retour d'un relevé. Sur un fil JavaScript
        // figé, le premier ne revient jamais : annoncer à son retour, c'était
        // laisser la barre muette, sans la sortie, aussi longtemps que la page
        // restait figée. Une fois la session dite, la page peut encore se
        // figer au vidage ou au clic du micro : l'annonce reste armée, un peu
        // plus tard, pour ne pas faire clignoter « se prépare » devant un
        // démarrage ordinaire. Ces délais ne sont qu'un affichage, au temps
        // réel : ils ne mettent fin à rien.
        var annonce = annoncer(apres: .milliseconds(400), siElleTarde)
        defer { annonce.cancel() }
        try await observer([]) { RelaisVeille.session($0) == true ? () : nil }
        surSession(true)
        annonce.cancel()
        if await annonce.value == false { annonce = annoncer(apres: .milliseconds(1500), siElleTarde) }
        // La page que cette dictée va attendre est celle qui vient de se dire
        // connectée. Relevée avant l'attente, une mort survenue pendant celle-
        // ci — déjà réparée par le rechargement — faisait annoncer « dictée
        // perdue » à qui n'avait encore rien dit.
        epoque = page.epoque
        // Vider la zone **avant** d'écouter. Une dictée dont la lecture a
        // échoué laisse son texte dans la page — délibérément, pour qu'il reste
        // récupérable à la main. Mais ChatGPT ajoute la dictée suivante à la
        // suite au lieu de remplacer, si bien que le texte suivant arrivait
        // collé au précédent, et le suivant encore aux deux.
        _ = try await essayer { try await self.page.vider() }
        // Ce que la page affiche déjà n'est pas un échec de cette dictée.
        try await marquer()
        // L'écho doit être prêt quand la page demandera le micro, au clic.
        page.armerEcho()
        var clique = false
        defer { if !clique { page.desarmerEcho() } }
        // Délai de geste : le bouton micro existe dès que la page s'est dite
        // connectée.
        //
        // Cliqué jusqu'à ce qu'il prenne, et non une fois : la fenêtre de la
        // page vit hors champ, le système diffère ses rendus, et un bouton
        // créé en réaction à un geste arrive parfois après la question.
        try await observer([], delai: .micro) { _ in try await self.cliquer(.micro) }
        clique = true
    }

    // MARK: - Transcrire

    /// Clique l'arrêt, puis attend que le texte revienne et se stabilise.
    ///
    /// Deux attentes distinctes, et aucune n'a de fin (cf.
    /// `RelaisVeille.Stabilisation`) : une transcription se juge sur la zone,
    /// jamais sur le temps qu'elle a pris.
    ///
    /// Après l'arrêt, ChatGPT passe par un état intermédiaire — le mot
    /// « Transcription » et une roue — pendant lequel la zone n'est toujours
    /// pas là. Sa durée suit celle de la dictée : quelques secondes pour trente
    /// secondes de parole, bien plus pour dix minutes. Une version qui
    /// guettait la disparition de l'arrêt concluait, sur une dictée longue,
    /// que l'arrêt n'avait pas répondu, rechargeait, et détruisait une
    /// transcription en train d'aboutir. Le seul signal fiable est le retour
    /// de la zone, et il signifie exactement ce qu'on attend.
    public func arreterEtLire() async throws -> String {
        // L'écho se désarme à la sortie du clic, quelle qu'elle soit : une
        // erreur du pont ne passe pas par l'abandon, et l'écho armé
        // continuerait d'accumuler le son jusqu'à la dictée suivante.
        do {
            defer { page.desarmerEcho() }
            // Délai de geste : le bouton d'arrêt existe pendant l'écoute.
            // Une page qui a cessé d'elle-même — ni arrêt, ni micro tenu —
            // n'a rien à arrêter : la cliquer ne trouverait rien.
            try await observer([], delai: .arret) { vu -> Void? in
                if !vu.stop, !self.page.microOuvert { return () }
                return try await self.cliquer(.stop)
            }
        }
        var stabilisation = RelaisVeille.Stabilisation()
        switch try await observer(.texte, { stabilisation.juger($0.texte) }) {
        case .texte(let texte):
            // On ne vide pas ici : l'ouverture de l'écoute le fait avant chaque
            // dictée, et vider exige de focaliser la zone — l'opération même qui
            // détournait le curseur système, au pire moment, celui où Caspr
            // s'apprête à insérer. Le texte laissé dans la page est en prime un
            // filet : il reste copiable si l'insertion échoue.
            return texte
        case .vide:
            // Sauf si la page dit pourquoi : un refus — un quota atteint, par
            // exemple — rend lui aussi la zone vide, et « avez-vous parlé ? »
            // ferait chercher la panne au micro.
            if let message = await alerteNouvelle() { throw RelaisErreur.refusParChatGPT(message) }
            journal("relais : la zone est revenue vide — rien n'a été dicté", false)
            return ""
        }
    }

    // MARK: - Envoyer

    /// Ajoute la consigne aux deux bouts de la transcription déjà présente,
    /// l'envoie, et vérifie que le message est parti.
    ///
    /// Aucun rechargement, et on ne réécrit pas la transcription : la
    /// repousser entière avec la consigne devant demandait à un éditeur
    /// ProseMirror d'avaler dix minutes de texte d'un coup, et le moindre
    /// accroc laissait la zone dans un état qu'on ne savait plus nommer. Le
    /// fil neuf est ouvert **après**, par la préparation de la dictée suivante.
    ///
    /// `brut` signe le message quand il n'y a pas de consigne.
    public func envoyer(avant: String, apres: String, brut: String) async throws {
        empreinte = RelaisVeille.empreinte(avant)
        if !avant.isEmpty || !apres.isEmpty {
            guard try await AppelAnnulable.appeler({ try await self.page.encadrer(avant: avant, apres: apres) })
            else { throw RelaisErreur.introuvable(.composeur) }
            // Attendre de relire la consigne, et non une demi-seconde décidée
            // d'avance : l'envoi partait avant que l'éditeur ait validé le
            // texte ajouté, et seule la transcription brute était expédiée. Un
            // délai fixe marcherait jusqu'au jour où la machine rame.
            if !empreinte.isEmpty {
                let signe = empreinte
                do {
                    // Délai de geste : la consigne écrite se relit aussitôt.
                    try await observer(.texte, delai: .consigne) { $0.texte?.contains(signe) == true ? () : nil }
                } catch RelaisErreur.consigneNonPosee {
                    journal("relais : la consigne n'a pas tenu dans la zone de saisie", true)
                    throw RelaisErreur.consigneNonPosee
                }
            }
        }
        // Seule une alerte ou une réponse apparue depuis la marque compte.
        try await marquer()
        let signe = empreinte.isEmpty ? brut : empreinte
        // Délai de geste : le bouton d'envoi existe dès que la zone est remplie.
        try await observer([], delai: .envoi) { _ in try await self.cliquer(.envoi) }
        envoye = true
        // Un clic sans effet — bouton désactivé, clic avalé par l'éditeur —
        // rend ok quand même, et l'attente de la réponse qui suit n'a pas de
        // fin : elle aurait attendu une réponse à un message jamais parti. Une
        // zone absente ne prouve rien.
        do {
            // Délai de geste : ChatGPT vide la zone à l'instant du clic.
            try await observer([.texte, .reponse], delai: .depart) { vu -> Void? in
                if let r = vu.reponse, r.nouvelles > 0 || r.enCours { return () }
                guard let zone = vu.texte, !signe.isEmpty, !zone.contains(signe) else { return nil }
                return ()
            }
        } catch RelaisErreur.envoiSansEffet {
            // Une alerte apparue depuis la marque dit pourquoi, mieux que nous.
            if let message = await alerteNouvelle() { throw RelaisErreur.refusParChatGPT(message) }
            journal("relais : le clic d'envoi est resté sans effet — message toujours dans la zone", true)
            throw RelaisErreur.envoiSansEffet
        }
    }

    // MARK: - Récupérer

    /// La réponse de ChatGPT, entière : par son bouton « copier » quand on
    /// sait où il est, par la lecture de la page sinon — pour ne pas casser
    /// une configuration antérieure.
    public func recuperer() async throws -> String {
        guard page.selecteurs.saitCopier else {
            // Deux secondes et demie sans changement, et non une : ChatGPT
            // écrit par flux, et rien ne signale un texte coupé. Le calme se
            // juge sur la longueur, et la réponse n'est lue qu'une fois, finie
            // : relire tout son texte quatre fois par seconde forçait la page
            // à se redisposer pendant qu'elle l'écrivait.
            var finie = RelaisVeille.ReponseFinie(seuil: 10)
            return try await observer(.reponse) { vu -> String? in
                guard finie.juger(vu.reponse) else { return nil }
                let texte = try await essayer { try await self.page.lireReponse() } ?? nil
                return texte?.isEmpty == false ? texte : nil
            }
        }
        return try await copier()
    }

    /// Clique « copier » sous la réponse, et la lit dans le presse-papiers.
    ///
    /// Le bouton n'apparaît qu'une fois la génération terminée : sa présence
    /// est à la fois le signal de fin et le moyen d'extraction — la réponse
    /// entière, dans la mise en forme voulue par ChatGPT, là où la lecture du
    /// DOM rendait parfois un seul paragraphe sans rien signaler.
    ///
    /// Seulement sous une réponse **nouvelle**, postérieure à l'envoi : dans
    /// un fil de discussion, le dernier bouton « copier » visible est celui de
    /// la réponse précédente, et le cliquer aussitôt insérait l'ancienne.
    ///
    /// Le presse-papiers est rendu tel qu'il était juste avant le clic, tous
    /// types compris : il appartient à l'utilisateur. Sauvegardé au début de
    /// l'attente — désormais sans fin —, il prenait pour la réponse ce que
    /// l'utilisateur copiait entre-temps, et rendait une chaîne seule.
    private func copier() async throws -> String {
        var avant = 0
        var restaurer: (() -> Void)?
        do {
            let voie = try await observer(.reponse) { vu -> String? in
                guard let r = vu.reponse, r.nouvelles > 0, r.copierPret else { return nil }
                avant = self.presse.changeCount
                restaurer = self.presse.sauvegarder()
                // Annulé pendant cet appel, le clic a pu partir : la copie est
                // attendue plus bas, le temps de la défaire.
                let voie = try await self.essayer { try await self.page.copier() } ?? nil
                if voie == nil { restaurer = nil }
                return voie
            }
            // La voie suivie, pour que le prochain défaut se lise dans le
            // journal plutôt que dans une capture.
            journal("relais : copier cliqué (\(voie))", false)
        } catch is CancellationError where restaurer != nil {}
        guard let restaurer else { throw CancellationError() }

        // Le clic est asynchrone côté page : on attend que le presse-papiers
        // change plutôt que de le lire aussitôt.
        //
        // Sauf l'abandon, qui ne rend jamais de texte. Mais il ne sort pas
        // sur-le-champ : le clic est parti, et la copie qu'il déclenche
        // atterrit quand même, une fraction de seconde plus tard. Sortir
        // avant, c'était la laisser écraser le presse-papiers sans plus
        // personne pour le rendre. Il attend donc cette copie une seconde
        // encore, la défait, et seulement alors lève.
        let fin = horloge.maintenant + RelaisDelai.copie.duree
        var finAbandon: ContinuousClock.Instant?
        while horloge.maintenant < (finAbandon ?? fin) {
            if finAbandon == nil, Task.isCancelled { finAbandon = min(fin, horloge.maintenant + .seconds(1)) }
            if finAbandon == nil {
                try? await horloge.dormir(.milliseconds(250))
            } else {
                // Le sommeil d'une tâche annulée rend la main aussitôt : on
                // dort dans une tâche à part, que l'annulation n'atteint pas.
                let horloge = horloge
                await Task { try? await horloge.dormir(.milliseconds(100)) }.value
            }
            guard presse.changeCount != avant else { continue }
            let texte = presse.texte() ?? ""
            restaurer()
            try Task.checkCancellation()
            guard !texte.isEmpty else { throw RelaisErreur.pasDeReponse }
            // Garde-fou : le délimiteur de la consigne ne figure jamais dans
            // une réponse, et sa présence signe un bouton « copier » pris sous
            // le mauvais message — c'est le prompt lui-même qui s'écrivait
            // dans l'éditeur, sans que rien ne trahisse la méprise.
            if !empreinte.isEmpty, texte.contains(empreinte) {
                journal("relais : copie de la demande au lieu de la réponse", true)
                throw RelaisErreur.pasDeReponse
            }
            return texte
        }
        try Task.checkCancellation()
        throw RelaisDelai.copie.erreur
    }

    // MARK: - Faire lire

    /// Attend que la réponse soit finie, puis la fait lire à haute voix.
    ///
    /// Un module de traduction peut ainsi parler : on dicte en français,
    /// l'interlocuteur entend la réponse. Le bouton se cache parfois derrière
    /// un menu : la calibration a retenu le chemin complet, on le refait.
    ///
    /// Rend un échec prouvé — refus, session fermée, page morte —, pour que
    /// la barre le dise ; tout autre échec se tait : la réponse est à l'écran,
    /// seul le son manque, et faire échouer la dictée pour un haut-parleur
    /// muet serait disproportionné. L'attente de la réponse finie n'a pas de
    /// fin : la touche de dictée la fait cesser (`cesserDAttendreLaLecture`),
    /// et seule la voix est abandonnée.
    ///
    /// `dejaFinie` : la réponse vient d'être copiée, et le texte attend ce
    /// clic pour s'insérer. Le premier relevé qui la montre suffit.
    /// `quandFinie` : la réponse est finie, les clics commencent.
    public func faireLire(dejaFinie: Bool,
                          quandFinie: @escaping @MainActor () -> Void = {}) async -> RelaisErreur? {
        guard page.selecteurs.saitLire, !lectureInterrompue else { return nil }
        // Une tâche à elle, la seule que la touche de dictée fait taire : la
        // dictée a encore à ouvrir la discussion ou à insérer le texte, et une
        // tâche annulée n'insère rien.
        let tache = Task { await self.lire(dejaFinie: dejaFinie, quandFinie: quandFinie) }
        lecture = tache
        defer { lecture = nil }
        return await withTaskCancellationHandler { await tache.value } onCancel: { tache.cancel() }
    }

    /// L'appui ne fait plus que cesser d'attendre la lecture à haute voix.
    public func cesserDAttendreLaLecture() {
        lectureInterrompue = true
        lecture?.cancel()
    }

    private func lire(dejaFinie: Bool, quandFinie: @MainActor () -> Void) async -> RelaisErreur? {
        // La fin se lit sans calibrage : une réponse **nouvelle**, plus en
        // cours d'écriture, immobile depuis deux secondes. Le bloc du bouton
        // « copier », facultatif de bout en bout, faisait attendre trois
        // minutes pour rien quand il était vide.
        var finie = RelaisVeille.ReponseFinie(seuil: dejaFinie ? 0 : 8)
        do {
            // Délai de geste, pour une réponse qu'on vient de copier
            // seulement : il ne reste qu'à la voir dans la page.
            try await observer(.reponse, delai: dejaFinie ? .reponseCopiee : nil) {
                finie.juger($0.reponse) ? () : nil
            }
        } catch let erreur as RelaisErreur where erreur != RelaisDelai.reponseCopiee.erreur {
            journal("relais : \(erreur.raisonCourte ?? "\(erreur)"), lecture à haute voix abandonnée", true)
            return erreur
        } catch {
            if !Task.isCancelled {
                journal("relais : réponse copiée introuvable dans la page, lecture à haute voix abandonnée", true)
            }
            return nil
        }
        quandFinie()
        if !page.selecteurs.lectureMenu.isEmpty {
            guard await cliquerLecture(menu: true) else {
                journal("relais : menu de la lecture à haute voix introuvable", true)
                return nil
            }
            // Le menu s'ouvre : une pause, et non une attente de ChatGPT.
            guard (try? await horloge.dormir(.milliseconds(600))) != nil else { return nil }
        }
        let lancee = await cliquerLecture(menu: false)
        journal("relais : lecture à haute voix \(lancee ? "lancée" : "refusée")", false)
        return nil
    }

    /// Délai de geste : la barre d'actions d'une réponse finie s'affiche
    /// juste après la fin de la génération, pas au même instant.
    private func cliquerLecture(menu: Bool) async -> Bool {
        (try? await observer([], delai: .lecture) { _ in
            try await self.essayer { try await self.page.cliquerLecture(menu: menu) } == true ? () : nil
        }) != nil
    }

    // MARK: - Abandonner

    /// Arrête la page après un appui abandonné, et vide la zone — au repos :
    /// l'appelant borne l'ensemble, une page muette n'a rien à arrêter.
    ///
    /// `ecouteQuiDemarre` : l'appui vient d'être abandonné, peut-être juste
    /// après le clic du micro. La page ne se met alors à écouter qu'une fois
    /// le micro accordé, quelques centaines de millisecondes plus tard :
    /// cliquer l'arrêt sur-le-champ ne trouvait rien, et ChatGPT se mettait
    /// ensuite à écouter hors champ, le micro de la machine avec lui.
    public func arreterApresAbandon(ecouteQuiDemarre: Bool) async {
        page.desarmerEcho()
        let vu = try? await essayer { try await self.page.instantane([]) }
        var ecoute = vu?.enregistrement == true || page.microOuvert
        if !ecoute, ecouteQuiDemarre {
            // Délai de geste : après le clic du micro, la page se met à écouter.
            ecoute = (try? await observer([], delai: .ecouteApresAbandon) {
                $0.enregistrement || self.page.microOuvert ? () : nil
            }) != nil
        }
        if ecoute {
            // Délai de geste : la page écoute, son bouton d'arrêt va paraître.
            _ = try? await observer([], delai: .arretApresAbandon) { _ in try await self.cliquer(.stop) }
        } else {
            // Un seul essai quand rien n'écoute.
            _ = try? await cliquer(.stop)
        }
        // L'arrêt a pu déposer une transcription dans la zone.
        _ = try? await essayer { try await self.page.vider() }
    }

    // MARK: - La primitive d'attente

    /// LA façon d'attendre : un relevé de la page (`demande`) par quart de
    /// seconde, jusqu'à ce que `juger` rende une valeur. **Aucune échéance.**
    ///
    /// Avant de juger, les échecs que la page prouve : sa mort depuis
    /// l'ouverture de l'écoute, l'écran d'authentification, et — un tour sur
    /// quatre, les alertes coûtant à la page qu'on attend de voir avancer —
    /// un refus (cf. `RelaisVeille.refus`). Rien n'est demandé pendant un
    /// chargement : une zone vue alors est celle de la page qu'on quitte. Un
    /// relevé qui échoue ne dit rien, et l'on passe au suivant : le compter
    /// comme une zone vide finirait par conclure « rien n'a été dit » devant
    /// une page qui en a. Sauf un pont absent d'une page chargée : elle a dit
    /// tout ce qu'elle dira.
    ///
    /// Le reste appartient à l'utilisateur : annulée, l'attente rend la main
    /// dans l'instant, même si l'appel en cours ne revient jamais.
    ///
    /// `delai` : un délai de geste (cf. `RelaisDelai`), que chaque appelant
    /// justifie ; dépassé, son erreur.
    private func observer<T>(_ demande: RelaisDemande, delai: RelaisDelai? = nil,
                             _ juger: (RelaisInstantane) async throws -> T?) async throws -> T {
        var veille = RelaisVeille(apresEnvoi: envoye)
        let debut = horloge.maintenant
        var tour = 0
        while true {
            try Task.checkCancellation()
            if pageMorte { throw RelaisErreur.pageInterrompue }
            tour += 1
            let alertes = marquee && tour % 4 == 0
            if !page.chargementEnCours, let vu = try await releve(alertes ? demande.union(.alertes) : demande) {
                if pageMorte { throw RelaisErreur.pageInterrompue }
                // L'échec prouvé qu'une échéance rattrapait jadis : une session
                // perdue en pleine attente ne rendra jamais rien.
                if vu.authentification {
                    journal("relais : la page montre l'écran de connexion", true)
                    surSession(false)
                    throw RelaisErreur.pasConnecte
                }
                if alertes, let message = veille.refus(vu) {
                    journal("relais : ChatGPT a refusé (« \(message) »)", true)
                    throw RelaisErreur.refusParChatGPT(message)
                }
                if let valeur = try await juger(vu) { return valeur }
            }
            if let delai, horloge.maintenant - debut >= delai.duree { throw delai.erreur }
            try await horloge.dormir(.milliseconds(250))
        }
    }

    private func releve(_ demande: RelaisDemande) async throws -> RelaisInstantane? {
        do { return try await AppelAnnulable.appeler { try await self.page.instantane(demande) } }
        catch RelaisErreur.pontAbsent where !Task.isCancelled { throw RelaisErreur.pontAbsent }
        catch { if Task.isCancelled { throw CancellationError() }; return nil }
    }

    /// Un appel à la page dont l'échec ne dit rien — sauf l'annulation, qui
    /// tranche sur-le-champ.
    private func essayer<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T? {
        do { return try await AppelAnnulable.appeler(operation) }
        catch { if Task.isCancelled { throw CancellationError() }; return nil }
    }

    /// Un clic qui a pris, ou `nil` pour le tour suivant.
    private func cliquer(_ cible: RelaisCible) async throws -> Void? {
        try await essayer { try await self.page.cliquer(cible) } == true ? () : nil
    }

    private func marquer() async throws {
        marquee = try await essayer { try await self.page.marquer() } != nil
    }

    /// L'alerte apparue depuis la marque, reconnue ou non — pour
    /// **expliquer** un échec déjà constaté : la zone revenue vide, un envoi
    /// sans effet. Pendant une attente, c'est `RelaisVeille.refus` qui décide
    /// si une alerte en est un.
    private func alerteNouvelle() async -> String? {
        guard marquee else { return nil }
        return (try? await releve(.alertes))?.echec?.texte
    }

    private func annoncer(apres delai: Duration,
                          _ annonce: @escaping @MainActor () -> Void) -> Task<Bool, Never> {
        Task { @MainActor in
            guard (try? await Task.sleep(for: delai)) != nil else { return false }
            annonce()
            return true
        }
    }
}

/// Ce que la fin d'une dictée fait de la page, pour la suivante — au repos.
///
/// C'est **la fin d'une dictée qui prépare la suivante**, et non l'appui qui
/// découvre l'état où la précédente a laissé la page : recharger coûte une
/// seconde ou deux, qui au repos ne coûtent rien à personne, et il n'y a plus
/// rien à décider à l'appui — la page est prête, quel que soit le module qu'on
/// choisira en parlant.
public enum RelaisPreparation {
    /// Ce que la page a répondu, au repos.
    public enum Page: Equatable {
        /// Elle répond, et dit si elle porte une conversation.
        case repond(conversation: Bool)
        /// Elle ne répond pas : un fil JavaScript bloqué, un pont absent.
        case muette
        /// Son processus est mort, et elle n'a pas été rechargée.
        case morte
        case enChargement
    }

    public enum Decision: Equatable {
        case garderLeFil, conversationNeuve, vider, reconstruire, recharger, attendreLeChargement
    }

    public static func decision(enDiscussion: Bool, page: Page) -> Decision {
        switch page {
        // Morte et laissée morte (cf. la récidive dans `RelaisPage`), elle se
        // recharge ici plutôt que dans la question, qui la verrait muette.
        case .morte: .recharger
        // Une page qui se charge est déjà la page de départ neuve : il n'y a
        // qu'à l'attendre. L'interroger tombait sur un pont pas encore
        // injecté, pris pour une page figée, et la rechargeait par-dessus.
        case .enChargement: .attendreLeChargement
        // Recharger ne répare pas un fil JavaScript bloqué (mesuré) : on la
        // reconstruit, discussion comprise. Une page muette ne doit pas
        // devenir la panne de la dictée suivante.
        case .muette: .reconstruire
        // En discussion, le fil ouvert *est* la page prête — tant qu'elle
        // répond.
        case .repond where enDiscussion: .garderLeFil
        // Un message est parti, que la suite ait abouti ou non.
        case .repond(conversation: true): .conversationNeuve
        // Le cas de « Brut », qui n'envoie rien : vider la zone suffit. Une
        // zone qui refuse de se vider sur une page qui répond n'est pas une
        // page à jeter — c'est souvent une transcription encore en cours.
        case .repond(conversation: false): .vider
        }
    }
}
