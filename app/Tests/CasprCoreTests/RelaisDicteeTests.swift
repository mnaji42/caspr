import Foundation
import Testing
@testable import CasprCore

/// Une dictée ChatGPT entière, rejouée sans WebKit : une page factice qui
/// avance avec une horloge qu'on tient à la main.
///
/// C'est le filet de la règle qui commande tout (RELAIS.md, sixième règle) :
/// une attente de ChatGPT ne finit que par l'utilisateur ou par un échec que
/// la page prouve, jamais par le temps. Cinq minutes de transcription s'y
/// rejouent en un instant.
@Suite("Scénario d'une dictée ChatGPT")
@MainActor
struct RelaisDicteeTests {

    // MARK: - Le banc

    /// Le temps des tests : `dormir` l'avance, sans attendre.
    final class HorlogeManuelle: RelaisHorloge {
        let depart = ContinuousClock.now
        var maintenant: ContinuousClock.Instant
        init() { maintenant = depart }
        var ecoule: Duration { maintenant - depart }
        func dormir(_ duree: Duration) async throws {
            try Task.checkCancellation()
            maintenant += duree
            await Task.yield()
        }
    }

    final class PressePapiersFactice: RelaisPressePapiers {
        let horloge: HorlogeManuelle
        init(_ horloge: HorlogeManuelle) { self.horloge = horloge }
        var contenu: String? = "le presse-papiers de l'utilisateur"
        private var compte = 0
        /// Une copie qui atterrit plus tard, comme celle du bouton de ChatGPT.
        var enRoute: (a: Duration, texte: String)?
        var changeCount: Int {
            if let e = enRoute, horloge.ecoule >= e.a { enRoute = nil; ecrire(e.texte) }
            return compte
        }
        func texte() -> String? { contenu }
        func ecrire(_ texte: String) { contenu = texte; compte += 1 }
        func sauvegarder() -> () -> Void {
            let garde = contenu
            return { self.ecrire(garde ?? "") }
        }
    }

    /// ChatGPT, tel que les relevés le montrent : il écoute après le clic du
    /// micro, transcrit après l'arrêt, répond après l'envoi.
    final class PageFactice: RelaisPageDictee {
        let horloge = HorlogeManuelle()
        lazy var presse = PressePapiersFactice(horloge)
        var epoque = 0
        var chargementEnCours = false
        /// WebKit tient le micro hors de toute écoute : resté pris d'avant.
        var microTenu = false
        var microOuvert: Bool { ecoute || microTenu }
        var selecteurs: RelaisSelecteurs = {
            var s = RelaisSelecteurs()
            (s.micro, s.stop, s.composeur, s.envoi, s.copier, s.lecture) = ("m", "s", "c", "e", "k", "l")
            return s
        }()

        // Ce que ChatGPT fait, et en combien de temps.
        var ecoutePrend = true
        /// La page se met à écouter ce temps après le clic du micro.
        var ecouteEnRetard: Duration = .zero
        var transcription: Duration = .seconds(2)
        /// Le texte de la zone revenue, selon le temps depuis son retour.
        var dicte: (Duration) -> String = { _ in "Bonjour tout le monde" }
        var consignePrend = true
        var envoiPrend = true
        var repond = true
        var generation: Duration = .seconds(3)
        var reponse = "Voici le texte remanié."
        /// Une réponse d'un tour précédent : une discussion.
        var reponsePrecedente = false
        var deconnecteA: Duration?
        var mortA: Duration?
        /// Une page chargée sans le pont de Caspr, à partir de cet instant.
        var pontAbsentA: Duration?
        var echec: (Duration) -> RelaisInstantane.Echec? = { _ in nil }
        /// La copie n'atterrit qu'après ce délai.
        var copieEnRetard: Duration = .zero
        var surCopie: () -> Void = {}
        var releveSuspendu = false

        private(set) var clics: [RelaisCible] = []
        private(set) var lectures = 0
        private(set) var echoArme = false
        private var ecouteA, arretA, envoiA: Duration?
        private var zone = "", avant = "", apres = ""
        private var marque: (reponses: Int, echecs: [String])?
        private var suspendus: [CheckedContinuation<RelaisInstantane, Error>] = []

        var t: Duration { horloge.ecoule }
        private var ecoute: Bool { ecouteA.map { t - $0 >= ecouteEnRetard } == true && arretA == nil }
        var arrete: Bool { arretA != nil }
        private var transcrit: Bool { arretA.map { t - $0 < transcription } ?? false }
        private var envoye: Bool { envoiA != nil && envoiPrend }
        private var enCours: Bool { envoye && repond && t - envoiA! < generation }
        private var nouvelleLa: Bool { envoye && repond && t - envoiA! >= .milliseconds(500) }
        private var reponses: Int { (reponsePrecedente ? 1 : 0) + (nouvelleLa ? 1 : 0) }
        private var texteDeLaZone: String {
            if envoye { return "" }
            if let a = arretA, !transcrit { return avant + dicte(t - a - transcription) + apres }
            return zone
        }

        func instantane(_ demande: RelaisDemande) async throws -> RelaisInstantane {
            if releveSuspendu { return try await withCheckedThrowingContinuation { suspendus.append($0) } }
            if let m = mortA, t >= m, epoque == 0 { epoque = 1 }
            if let p = pontAbsentA, t >= p { throw RelaisErreur.pontAbsent }
            var vu = RelaisInstantane()
            vu.authentification = deconnecteA.map { t >= $0 } ?? false
            vu.composeur = !ecoute && !transcrit
            vu.micro = vu.composeur
            vu.stop = ecoute
            vu.enregistrement = ecoute
            vu.conversation = envoye
            if demande.contains(.texte), vu.composeur { vu.texte = texteDeLaZone }
            if demande.contains(.reponse), let marque {
                let nouvelles = max(0, reponses - marque.reponses)
                vu.reponse = .init(nouvelles: nouvelles, enCours: enCours,
                                   longueur: nouvelles > 0 ? (enCours ? Int(t / .milliseconds(100)) : reponse.count) : 0,
                                   // Le bouton « copier » du dernier tour visible : celui
                                   // de la réponse d'avant tant que la nouvelle n'est pas là.
                                   copierPret: nouvelleLa ? !enCours : reponsePrecedente)
            }
            if demande.contains(.alertes), let marque, let e = echec(t), !marque.echecs.contains(e.texte) {
                vu.echec = e
            }
            return vu
        }

        func marquer() async throws { marque = (reponses, echec(t).map { [$0.texte] } ?? []) }

        func cliquer(_ cible: RelaisCible) async throws -> Bool {
            clics.append(cible)
            switch cible {
            case .micro:
                if ecoutePrend { ecouteA = t }
            case .stop:
                guard ecoute else { return false }
                arretA = t
            case .envoi:
                envoiA = t
            default: break
            }
            return true
        }

        func vider() async throws { zone = "" }

        func encadrer(avant: String, apres: String) async throws -> Bool {
            guard consignePrend else { return true }
            (self.avant, self.apres) = (avant, apres)
            return true
        }

        func copier() async throws -> String? {
            // Le dernier bouton « copier » de la page : celui de la réponse
            // précédente tant que la nouvelle n'est pas là.
            let texte = nouvelleLa ? reponse : "La réponse d'avant."
            presse.enRoute = (t + copieEnRetard, texte)
            surCopie()
            return "paire"
        }

        func cliquerLecture(menu: Bool) async throws -> Bool {
            lectures += 1
            return true
        }

        func lireReponse() async throws -> String? { reponses > 0 ? reponse : nil }
        func armerEcho() { echoArme = true }
        func desarmerEcho() { echoArme = false }

        func liberer() {
            releveSuspendu = false
            for s in suspendus { s.resume(throwing: CancellationError()) }
            suspendus = []
        }
    }

    private static func dictee(_ page: PageFactice) -> RelaisDictee {
        RelaisDictee(page: page, pressePapiers: page.presse, horloge: page.horloge)
    }

    // MARK: - Aucune limite de temps

    @Test("ChatGPT met cinq minutes à transcrire : Caspr attend, sans erreur")
    func transcriptionDeCinqMinutes() async throws {
        let page = PageFactice()
        page.transcription = .seconds(300)
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        #expect(page.echoArme)
        #expect(try await dictee.arreterEtLire() == "Bonjour tout le monde")
        #expect(page.horloge.ecoule >= .seconds(300))
        #expect(page.clics == [.micro, .stop])
        #expect(!page.echoArme)
    }

    @Test("Un relevé qui ne revient jamais : annulée, l'attente rend la main en moins de 200 ms")
    func releveSuspenduAnnule() async throws {
        let page = PageFactice()
        page.releveSuspendu = true
        let dictee = Self.dictee(page)
        let tache = Task { try await dictee.arreterEtLire() }
        try await Task.sleep(for: .milliseconds(50))
        let debut = ContinuousClock.now
        tache.cancel()
        await #expect(throws: CancellationError.self) { try await tache.value }
        #expect(ContinuousClock.now - debut < .milliseconds(200))
        page.liberer()
    }

    @Test("La réponse la plus longue s'attend sans fin, et Réorganiser rend la réponse")
    func reorganiser() async throws {
        let page = PageFactice()
        page.generation = .seconds(240)
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        try await dictee.envoyer(avant: "Réorganise ce texte.\n---\n", apres: "", brut: brut)
        #expect(try await dictee.recuperer() == "Voici le texte remanié.")
        #expect(page.clics == [.micro, .stop, .envoi])
        // Rendu tel qu'il était juste avant le clic.
        #expect(page.presse.contenu == "le presse-papiers de l'utilisateur")
    }

    // MARK: - Les échecs que la page prouve

    @Test("WebKit tue la page pendant la transcription : la dictée échoue sur-le-champ")
    func mortPendantLAttente() async throws {
        let page = PageFactice()
        page.transcription = .seconds(60)
        page.mortA = .seconds(10)
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        await #expect(throws: RelaisErreur.pageInterrompue) { try await dictee.arreterEtLire() }
        #expect(dictee.pageMorte)
        #expect(page.horloge.ecoule < .seconds(11))
    }

    @Test("Un pont absent d'une page chargée pendant l'attente : échec prouvé, et non attente sans fin")
    func pontAbsentPendantLAttente() async throws {
        let page = PageFactice()
        page.transcription = .seconds(60)
        page.pontAbsentA = .seconds(10)
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        await #expect(throws: RelaisErreur.pontAbsent) { try await dictee.arreterEtLire() }
        #expect(page.horloge.ecoule < .seconds(11))
    }

    @Test("L'écran d'authentification pendant l'attente : session déconnectée, et dite")
    func authentification() async throws {
        let page = PageFactice()
        page.transcription = .seconds(60)
        page.deconnecteA = .seconds(20)
        let dictee = Self.dictee(page)
        var sessions: [Bool] = []
        dictee.surSession = { sessions.append($0) }
        try await dictee.ouvrirLEcoute()
        await #expect(throws: RelaisErreur.pasConnecte) { try await dictee.arreterEtLire() }
        #expect(sessions == [true, false])
    }

    @Test("Une bannière déjà là à la marque n'interrompt jamais la dictée")
    func banniereDejaLa() async throws {
        let page = PageFactice()
        page.echec = { _ in .init(texte: "Something went wrong", reconnue: true) }
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        try await dictee.envoyer(avant: "Consigne\n---\n", apres: "", brut: brut)
        #expect(try await dictee.recuperer() == "Voici le texte remanié.")
    }

    @Test("Une alerte inconnue pendant que ChatGPT répond n'interrompt rien ; sans réponse, trois relevés en font un refus")
    func alerteInconnue() async throws {
        for repond in [true, false] {
            let page = PageFactice()
            page.repond = repond
            page.generation = .seconds(30)
            page.echec = { t in t > .seconds(5) ? .init(texte: "Limite bientôt atteinte") : nil }
            let dictee = Self.dictee(page)
            try await dictee.ouvrirLEcoute()
            let brut = try await dictee.arreterEtLire()
            try await dictee.envoyer(avant: "Consigne\n---\n", apres: "", brut: brut)
            if repond {
                #expect(try await dictee.recuperer() == "Voici le texte remanié.")
            } else {
                await #expect(throws: RelaisErreur.refusParChatGPT("Limite bientôt atteinte")) {
                    try await dictee.recuperer()
                }
            }
        }
    }

    // MARK: - La transcription

    @Test("Une zone revenue vide seize relevés : rien n'a été dit ; une alerte nouvelle l'explique")
    func zoneVide() async throws {
        for explique in [false, true] {
            let page = PageFactice()
            page.dicte = { _ in "" }
            page.echec = { t in explique && t > .seconds(1) ? .init(texte: "Quota atteint") : nil }
            let dictee = Self.dictee(page)
            try await dictee.ouvrirLEcoute()
            if explique {
                await #expect(throws: RelaisErreur.refusParChatGPT("Quota atteint")) {
                    try await dictee.arreterEtLire()
                }
            } else {
                #expect(try await dictee.arreterEtLire() == "")
            }
        }
    }

    @Test("Un texte qui bouge encore n'est jamais rendu coupé")
    func texteQuiBouge() async throws {
        let page = PageFactice()
        // Un mot de plus toutes les 600 ms pendant une minute : des pauses
        // plus longues que le seuil de 500 ms qui coupait la phrase.
        page.dicte = { t in String(repeating: "mot ", count: min(100, Int(t / .milliseconds(600)) + 1)) }
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        #expect(try await dictee.arreterEtLire() == String(repeating: "mot ", count: 100))
    }

    // MARK: - L'envoi

    @Test("Un clic d'envoi sans effet est un échec dit, pas une attente sans fin")
    func envoiSansEffet() async throws {
        let page = PageFactice()
        page.envoiPrend = false
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        await #expect(throws: RelaisErreur.envoiSansEffet) {
            try await dictee.envoyer(avant: "", apres: "", brut: brut)
        }
    }

    @Test("Une consigne qui ne tient pas dans la zone : rien n'est envoyé")
    func consigneNonPosee() async throws {
        let page = PageFactice()
        page.consignePrend = false
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        await #expect(throws: RelaisErreur.consigneNonPosee) {
            try await dictee.envoyer(avant: "Consigne\n---\n", apres: "", brut: brut)
        }
        #expect(!page.clics.contains(.envoi))
    }

    // MARK: - La réponse

    @Test("« copier » n'est cliqué que sous une réponse nouvelle, jamais celle d'avant")
    func copierSeulementUneReponseNouvelle() async throws {
        let page = PageFactice()
        page.reponsePrecedente = true
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        try await dictee.envoyer(avant: "", apres: "", brut: brut)
        #expect(try await dictee.recuperer() == "Voici le texte remanié.")
    }

    @Test("Une copie qui contient la consigne envoyée est rejetée : c'est la demande")
    func copieDeLaDemande() async throws {
        let page = PageFactice()
        page.reponse = "Réorganise.\n---\nBonjour"
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        try await dictee.envoyer(avant: "Réorganise.\n---\n", apres: "", brut: brut)
        await #expect(throws: RelaisErreur.pasDeReponse) { try await dictee.recuperer() }
        #expect(page.presse.contenu == "le presse-papiers de l'utilisateur")
    }

    @Test("Abandonnée pendant la copie, la dictée rend le presse-papiers et n'insère rien")
    func abandonPendantLaCopie() async throws {
        let page = PageFactice()
        page.copieEnRetard = .milliseconds(300)
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        try await dictee.envoyer(avant: "", apres: "", brut: brut)
        var tache: Task<String, Error>?
        page.surCopie = { tache?.cancel() }
        tache = Task { try await dictee.recuperer() }
        await #expect(throws: CancellationError.self) { try await tache!.value }
        #expect(page.presse.contenu == "le presse-papiers de l'utilisateur")
    }

    @Test("La réponse qu'on vient de copier est lue au premier relevé qui la montre")
    func lectureDUneReponseCopiee() async throws {
        let page = PageFactice()
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        try await dictee.envoyer(avant: "", apres: "", brut: brut)
        _ = try await dictee.recuperer()
        var finie = false
        #expect(await dictee.faireLire(dejaFinie: true, quandFinie: { finie = true }) == nil)
        #expect(finie && page.lectures == 1)
    }

    @Test("Une réponse copiée que la page ne montre pas s'attend sans échéance, jusqu'à la touche")
    func reponseCopieeSansEcheance() async throws {
        let page = PageFactice()
        page.generation = .seconds(100_000)
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        try await dictee.envoyer(avant: "", apres: "", brut: brut)
        var rendue = false
        let tache = Task { () -> RelaisErreur? in
            defer { rendue = true }
            return await dictee.faireLire(dejaFinie: true)
        }
        // Bien au-delà des dix secondes que ce relevé a portées.
        while page.t < .seconds(60), !rendue { await Task.yield() }
        #expect(!rendue)
        dictee.cesserDAttendreLaLecture()
        #expect(await tache.value == nil)
        #expect(page.lectures == 0)
    }

    @Test("La touche cesse d'attendre la lecture, sur-le-champ, sans rien lever")
    func cesserDAttendreLaLecture() async throws {
        let page = PageFactice()
        page.generation = .seconds(100_000)
        let dictee = Self.dictee(page)
        try await dictee.ouvrirLEcoute()
        let brut = try await dictee.arreterEtLire()
        try await dictee.envoyer(avant: "", apres: "", brut: brut)
        let tache = Task { await dictee.faireLire(dejaFinie: false) }
        try await Task.sleep(for: .milliseconds(30))
        let debut = ContinuousClock.now
        dictee.cesserDAttendreLaLecture()
        #expect(await tache.value == nil)
        #expect(ContinuousClock.now - debut < .milliseconds(200))
        #expect(page.lectures == 0)
    }

    // MARK: - L'écoute

    @Test("Le micro cliqué sans que la page écoute : « ChatGPT n'a pas ouvert son micro » au bout de cinq secondes")
    func ecouteNonOuverte() async throws {
        let page = PageFactice()
        page.ecoutePrend = false
        let dictee = Self.dictee(page)
        await #expect(throws: RelaisErreur.ecouteNonOuverte) { try await dictee.ouvrirLEcoute() }
        #expect(page.horloge.ecoule >= .seconds(5) && page.horloge.ecoule < .seconds(6))
        #expect(page.clics == [.micro] && !page.echoArme)
    }

    @Test("Un micro que WebKit tenait déjà avant le clic ne prouve pas l'écoute")
    func microDejaTenu() async throws {
        let page = PageFactice()
        page.ecoutePrend = false
        page.microTenu = true
        let dictee = Self.dictee(page)
        await #expect(throws: RelaisErreur.ecouteNonOuverte) { try await dictee.ouvrirLEcoute() }
        // Tenu d'avant, il n'empêche pas une écoute qui prend.
        page.ecoutePrend = true
        try await Self.dictee(page).ouvrirLEcoute()
    }

    @Test("Une page qui se met à écouter une seconde après le clic est une écoute ouverte")
    func ecouteQuiTarde() async throws {
        let page = PageFactice()
        page.ecouteEnRetard = .seconds(1)
        try await Self.dictee(page).ouvrirLEcoute()
        #expect(page.microOuvert && page.echoArme)
    }

    // MARK: - L'abandon

    @Test("Abandonné juste après le clic du micro, la page qui se met à écouter est arrêtée")
    func arretApresAbandon() async throws {
        let page = PageFactice()
        page.ecouteEnRetard = .seconds(1)
        let dictee = Self.dictee(page)
        let appui = Task { try await dictee.ouvrirLEcoute() }
        // L'appui est abandonné dès le clic du micro, avant que la page écoute.
        while !page.clics.contains(.micro) { await Task.yield() }
        appui.cancel()
        _ = try? await appui.value
        await Self.dictee(page).arreterApresAbandon(auRepos: try await page.instantane([]), ecouteQuiDemarre: true)
        #expect(page.arrete && !page.microOuvert && !page.echoArme)
    }

    // MARK: - La page au repos

    @Test("La préparation de la dictée suivante, cas par cas")
    func preparation() {
        typealias P = RelaisPreparation
        for discussion in [true, false] {
            // Morte, elle se recharge ; en chargement, elle s'attend — sans
            // qu'on l'interroge, discussion ou non (73, 74).
            #expect(P.decision(enDiscussion: discussion, page: .morte) == .recharger)
            #expect(P.decision(enDiscussion: discussion, page: .enChargement) == .attendreLeChargement)
            #expect(P.decision(enDiscussion: discussion, page: .muette) == .reconstruire)
        }
        #expect(P.decision(enDiscussion: true, page: .repond(conversation: true)) == .garderLeFil)
        #expect(P.decision(enDiscussion: true, page: .repond(conversation: false)) == .garderLeFil)
        #expect(P.decision(enDiscussion: false, page: .repond(conversation: true)) == .conversationNeuve)
        #expect(P.decision(enDiscussion: false, page: .repond(conversation: false)) == .vider)
    }
}
