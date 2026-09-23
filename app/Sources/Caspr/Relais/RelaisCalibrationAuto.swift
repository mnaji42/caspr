import AppKit
import CasprCore

/// Le parcours de la calibration automatique : essayer les boutons de la page
/// sous les yeux de l'utilisateur, et ne retenir que ceux dont l'effet se voit.
///
/// ## La preuve par l'effet, pas la confiance dans un libellé
///
/// Chaque repère a sa preuve, et c'est la même question que la dictée lui
/// posera ensuite :
///
/// | Repère | Retenu quand… |
/// |---|---|
/// | zone de texte | ce qu'on y écrit s'y relit, et elle se vide |
/// | micro | après le clic, la page enregistre |
/// | arrêt | après le clic, la zone de texte revient |
/// | envoi | après le clic, la page porte une conversation |
/// | copier | le presse-papiers change, n'est pas vide, et ne contient pas le message envoyé |
///
/// C'est ce qui rend la langue de l'interface sans objet : un libellé traduit
/// ne change pas ce que fait le bouton. Rien ne la force donc — WebKit n'offre
/// d'ailleurs aucun levier propre, et une fois connecté ChatGPT suit le réglage
/// du compte, que Caspr n'a pas à toucher.
///
/// ## Ce que l'automate s'interdit
///
/// - **Écrire le calibrage.** Le parcours ne rend que des preuves ; c'est
///   `Relais` qui enregistre, et seulement l'aller-retour entier (cf.
///   `RelaisPreuves`). Un parcours qui échoue à mi-chemin laisse le calibrage
///   d'avant intact.
/// - **Envoyer plus d'un message.** Avant chaque essai d'un bouton d'envoi, le
///   message d'essai doit être encore dans la zone : s'il en est parti, rien ne
///   se retente — on ne sait peut-être pas où il est allé, mais on sait qu'il
///   n'y en aura pas un second. Chaque message coûte sur le quota même qu'un
///   refus de ChatGPT épuise.
/// - **Ouvrir un menu.** Un bouton qui en déclare un n'est jamais candidat : le
///   menu « … » de la réponse porte « Régénérer » et « Supprimer ». D'où
///   « Lire à haute voix », qui s'y cache parfois, laissé à la main.
/// - **Garder le presse-papiers.** Il appartient à l'utilisateur : sauvegardé
///   tout entier, tous types compris, avant les essais de « copier », et
///   rendu après le dernier.
///
/// Chaque attente **observe** — la page qui enregistre, la zone qui revient, la
/// réponse qui cesse de s'écrire — et une borne l'arrête ; aucune ne se
/// contente d'un délai écoulé.
@MainActor
struct RelaisCalibrationAuto {
    let page: RelaisPage
    /// Le calibrage en place. Le parcours ne s'en sert que pour ce qu'il
    /// n'éprouve pas — le repère de la réponse, d'où la dictée partira pour
    /// trouver « copier », et d'où la preuve part donc aussi — et ne le
    /// modifie jamais.
    let ancien: RelaisSelecteurs

    struct Issue {
        var preuves = RelaisPreuves()
        /// Le message d'essai a quitté la zone de texte : il est parti, ou du
        /// moins il ne partira pas deux fois.
        var messageEnvoye = false
        /// Combien de réponses de ChatGPT la page portait avant l'envoi : ce
        /// qui distingue la réponse au message d'essai d'une page qui en
        /// montrerait déjà.
        var reponsesAvant = 0
    }

    /// Un fragment du message d'essai, pour le reconnaître là où la page l'a
    /// réécrit : ni apostrophe ni guillemet, que l'éditeur pourrait rendre
    /// autrement.
    private static let empreinte = "Caspr pour repérer les boutons"

    /// La raison d'un repère essayé dont le clic n'a rien trouvé. Sans elle,
    /// le rapport le disait « pas essayé : une étape précédente a échoué »,
    /// et envoyait chercher la panne une étape trop tôt.
    private static let clicPerdu = "au moment du clic, son repère ne désignait plus un bouton"

    /// Mène le parcours jusqu'au premier repère qui ne se prouve pas.
    ///
    /// Lève `CancellationError` quand on l'abandonne : il n'y a alors rien à
    /// rapporter, et c'est l'abandon qui remet la page d'aplomb.
    func mener() async throws -> Issue {
        var issue = Issue()
        // Une conversation neuve, sans le brouillon que ChatGPT réinstalle.
        page.charger()
        guard await page.attendreComposeurPret(secondes: 30) else {
            try Task.checkCancellation()
            issue.preuves.manque(.composeur, "la page ChatGPT ne s'est pas chargée")
            return issue
        }
        await page.viderComposeur(selecteur: "")

        guard let composeur = try await prouverComposeur(&issue),
              let micro = try await prouverMicro(composeur, &issue),
              let stop = try await prouverStop(micro, composeur, &issue),
              try await prouverEnvoi(micro, stop, composeur, &issue)
        else { return issue }
        try await prouverCopier(&issue)
        return issue
    }

    // MARK: - Les cinq preuves

    /// La zone de texte : on y écrit, on relit, on vide, on relit.
    private func prouverComposeur(_ issue: inout Issue) async throws -> String? {
        let liste = await candidats(.composeur)
        guard !liste.isEmpty else {
            issue.preuves.manque(.composeur, "aucune zone de texte n'y est seule à son repère")
            return nil
        }
        for sel in liste {
            try await ecrireLEssai(dans: sel)
            let ecrit = try await observer(pendant: 3) {
                await lire(sel)?.contains(Self.empreinte) == true
            }
            guard ecrit else {
                issue.preuves.manque(.composeur, "ce qu'on y écrit ne s'y relit pas")
                continue
            }
            guard await page.viderComposeur(selecteur: sel) else {
                issue.preuves.manque(.composeur, "elle refuse de se vider")
                continue
            }
            issue.preuves.prouve(.composeur, sel)
            return sel
        }
        return nil
    }

    /// Le micro : après le clic, la page enregistre.
    ///
    /// « Enregistre » au sens où la dictée le lira : la zone de texte a quitté
    /// la page, et un bouton d'arrêt l'a remplacée. L'arrêt n'est pas encore
    /// appris : le filet le cherche.
    private func prouverMicro(_ composeur: String, _ issue: inout Issue) async throws -> String? {
        let liste = await candidats(.micro)
        guard !liste.isEmpty else {
            issue.preuves.manque(.micro, "aucun bouton micro n'y est seul à son repère")
            return nil
        }
        for sel in liste {
            guard await cliquer(.micro, sel) else {
                issue.preuves.manque(.micro, Self.clicPerdu)
                continue
            }
            // Quinze secondes : la première fois, macOS demande l'accès au
            // micro, et il faut le temps de lire la question.
            let ecoute = try await observer(pendant: 15) {
                await etat(sel, "", composeur)?["enregistrement"] as? Bool == true
            }
            if ecoute {
                issue.preuves.prouve(.micro, sel)
                // Un instant d'écoute avant l'arrêt : un enregistrement coupé
                // à l'instant même où il commence peut être refusé par la page.
                try await Task.sleep(for: .seconds(1))
                return sel
            }
            issue.preuves.manque(.micro, "la page ne s'est pas mise à écouter — Caspr a-t-il "
                                 + "accès au micro (Réglages Système › Confidentialité) ?")
            // Ce clic a pu ouvrir autre chose : le candidat suivant part d'une
            // page neuve.
            try await remettreLaPage()
        }
        return nil
    }

    /// L'arrêt : après le clic, la zone de texte revient.
    ///
    /// Cherché pendant l'enregistrement, seul moment où il existe. S'il ne se
    /// prouve pas, la page écoute encore : elle est rechargée, ce qui coupe
    /// l'écoute, et le micro est rendu.
    private func prouverStop(_ micro: String, _ composeur: String,
                             _ issue: inout Issue) async throws -> String? {
        let liste = await candidats(.stop)
        if liste.isEmpty {
            issue.preuves.manque(.stop, "aucun bouton d'arrêt n'y est seul à son repère")
        }
        for sel in liste {
            guard await cliquer(.stop, sel) else {
                issue.preuves.manque(.stop, Self.clicPerdu)
                continue
            }
            // Trente secondes : la zone revient après la transcription, qui
            // suit la durée parlée — ici, une seconde ou deux.
            let revenue = try await observer(pendant: 30) {
                await etat(micro, sel, composeur)?["composeur"] as? Bool == true
            }
            if revenue {
                issue.preuves.prouve(.stop, sel)
                // Ce que la page a entendu arrive dans la zone un instant
                // après son retour : on le laisse arriver, pour l'effacer une
                // bonne fois plutôt que de le voir réapparaître sous le
                // message d'essai.
                try await attendreQueLaZoneSeTaise(composeur)
                return sel
            }
            issue.preuves.manque(.stop, "la zone de texte n'est pas revenue après le clic")
            // Ce clic n'a pas arrêté l'écoute : un autre candidat le peut
            // encore. Plus d'écoute, en revanche, et il n'y a plus rien à
            // arrêter.
            guard await etat(micro, "", composeur)?["enregistrement"] as? Bool == true else { break }
        }
        try await remettreLaPage()
        return nil
    }

    /// L'envoi : après le clic, la page porte une conversation. Un seul
    /// message, quoi qu'il arrive (cf. l'en-tête).
    private func prouverEnvoi(_ micro: String, _ stop: String, _ composeur: String,
                              _ issue: inout Issue) async throws -> Bool {
        await page.viderComposeur(selecteur: composeur)
        try await ecrireLEssai(dans: composeur)
        guard try await observer(pendant: 3, {
            await lire(composeur)?.contains(Self.empreinte) == true
        }) else {
            issue.preuves.manque(.envoi, "le message d'essai n'a pas pu être écrit")
            return false
        }
        // La preuve est l'apparition d'une conversation : elle ne prouve rien
        // sur une page qui en porte déjà une.
        guard let avant = await etat(micro, stop, composeur),
              avant["conversation"] as? Bool == false else {
            issue.preuves.manque(.envoi, "la page de départ est déjà une conversation — "
                                 + "revenez à l'accueil de ChatGPT dans les réglages")
            return false
        }
        let liste = await candidats(.envoi)
        guard !liste.isEmpty else {
            issue.preuves.manque(.envoi, "aucun bouton d'envoi n'y est seul à son repère")
            return false
        }
        let releve = try? await page.appeler("return window.__relais.releve();")
        issue.reponsesAvant = (releve?["reponses"] as? Int) ?? 0
        for sel in liste {
            guard await lire(composeur)?.contains(Self.empreinte) == true else {
                // Parti entre deux candidats : peut-être envoyé, et en tout cas
                // pas deux fois.
                issue.messageEnvoye = true
                issue.preuves.manque(.envoi, "le message d'essai a quitté la zone avant le clic")
                break
            }
            guard await cliquer(.envoi, sel) else {
                issue.preuves.manque(.envoi, Self.clicPerdu)
                continue
            }
            let parti = try await observer(pendant: 15) {
                await etat(micro, stop, composeur)?["conversation"] as? Bool == true
            }
            if parti {
                issue.messageEnvoye = true
                issue.preuves.prouve(.envoi, sel)
                return true
            }
            if await lire(composeur)?.contains(Self.empreinte) != true {
                // Le message a quitté la zone sans qu'une conversation ne se
                // montre : on ne sait pas où il est allé, et l'on n'en
                // enverra pas un second pour le savoir.
                issue.messageEnvoye = true
                issue.preuves.manque(.envoi, "le message a quitté la zone, mais aucune "
                                     + "conversation ne s'est ouverte")
                return false
            }
            issue.preuves.manque(.envoi, "aucune conversation ne s'est ouverte après le clic")
        }
        return false
    }

    /// « Copier » : le presse-papiers reçoit la réponse, et non la demande.
    private func prouverCopier(_ issue: inout Issue) async throws {
        guard try await attendreLaReponse(apres: issue.reponsesAvant) else {
            issue.preuves.manque(.copier, "ChatGPT n'a pas répondu au message d'essai en "
                                 + "deux minutes")
            return
        }
        let r = try? await page.appeler("return window.__relais.candidatsCopier(selReponse);",
                                        ["selReponse": ancien.reponse])
        let liste = (r?["candidats"] as? [[String: Any]]) ?? []
        guard !liste.isEmpty else {
            issue.preuves.manque(.copier, "aucun bouton « copier » n'est seul sous la réponse")
            return
        }
        // Sauvegardé une fois pour tous les candidats, et rendu en sortant,
        // abandon compris. Une sauvegarde par candidat pouvait capturer la
        // copie tardive du précédent — la réponse de ChatGPT — et la rendre
        // à la place de ce que l'utilisateur y avait mis.
        let presse = NSPasteboard.general
        let sauvegarde = PressePapiers(presse)
        let depart = presse.changeCount
        defer { if presse.changeCount != depart { sauvegarde.rendre(presse) } }
        for candidat in liste {
            try Task.checkCancellation()
            let sel = (candidat["selecteur"] as? String) ?? ""
            let parent = (candidat["parent"] as? String) ?? ""
            guard !sel.isEmpty else { continue }
            guard let copie = await copier(parent: parent, selecteur: sel) else {
                issue.preuves.manque(.copier, "au moment du clic, son repère ne désignait "
                                     + "plus un bouton seul")
                continue
            }
            if !copie.isEmpty, !copie.contains(Self.empreinte) {
                issue.preuves.prouve(.copier, sel, parent: parent)
                return
            }
            issue.preuves.manque(.copier, copie.isEmpty
                ? "le presse-papiers n'a rien reçu"
                : "le bouton a copié le message envoyé, pas la réponse")
        }
    }

    // MARK: - Attentes

    /// Observe une condition jusqu'à ce qu'elle tienne, ou jusqu'à la borne.
    private func observer(pendant secondes: Double,
                          _ condition: () async -> Bool) async throws -> Bool {
        let limite = Date.now.addingTimeInterval(secondes)
        repeat {
            try Task.checkCancellation()
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(250))
        } while Date.now < limite
        return false
    }

    /// Attend que ce que la page a transcrit cesse d'arriver dans la zone —
    /// une seconde sans changement, cinq au plus.
    private func attendreQueLaZoneSeTaise(_ composeur: String) async throws {
        var precedent: String?
        var stable = 0
        _ = try await observer(pendant: 5) {
            let texte = await lire(composeur)
            stable = texte == precedent ? stable + 1 : 0
            precedent = texte
            return stable >= 4
        }
    }

    /// Attend la réponse au message d'essai : nouvelle, écrite jusqu'au bout,
    /// immobile depuis deux secondes. Le bouton « copier » n'existe qu'alors.
    private func attendreLaReponse(apres avant: Int) async throws -> Bool {
        var precedent = ""
        var stable = 0
        return try await observer(pendant: 120) {
            guard let r = try? await page.appeler("return window.__relais.etatReponse(avant);",
                                                  ["avant": avant]),
                  r["nouvelle"] as? Bool == true
            else { stable = 0; return false }
            let texte = (r["texte"] as? String) ?? ""
            if r["enCours"] as? Bool != true, !texte.isEmpty, texte == precedent {
                stable += 1
            } else {
                stable = 0
            }
            precedent = texte
            return stable >= 8
        }
    }

    /// Recharge la page et attend sa zone de texte : ce qu'un candidat raté a
    /// pu ouvrir ou lancer ne doit pas fausser l'essai du suivant.
    private func remettreLaPage() async throws {
        await page.rendreLeMicro()
        page.charger()
        _ = await page.attendreComposeurPret(secondes: 30)
        try Task.checkCancellation()
        await page.viderComposeur(selecteur: "")
    }

    // MARK: - Le presse-papiers

    /// Clique « copier » comme la dictée le fera, et rend ce qui a été copié —
    /// une chaîne vide si rien ne l'a été, `nil` si le repère n'a rien cliqué
    /// ou que l'appel n'a pas répondu. C'est `prouverCopier` qui rend le
    /// presse-papiers.
    ///
    /// L'attente de la copie ne cède pas à l'abandon : le clic est parti, et sa
    /// copie atterrit quoi qu'il arrive, une fraction de seconde plus tard.
    /// Sortir avant, c'était rendre le presse-papiers avant qu'elle ne
    /// l'écrase (cf. `copierReponse`). Un appel sans réponse — abandonné, ou
    /// resté muet — a pu cliquer quand même : sa copie s'attend de même.
    private func copier(parent: String, selecteur: String) async -> String? {
        let presse = NSPasteboard.general
        let avant = presse.changeCount
        let r = try? await page.appeler(
            "return window.__relais.copierLaReponse(selParent, selCopier, selReponse);",
            ["selParent": parent, "selCopier": selecteur, "selReponse": ancien.reponse])
        if let r, r["ok"] as? Bool != true { return nil }
        let fin = Date.now.addingTimeInterval(5)
        while presse.changeCount == avant, Date.now < fin {
            // Une tâche à part, que l'annulation de celle-ci n'atteint pas.
            await Task { try? await Task.sleep(for: .milliseconds(100)) }.value
        }
        guard r != nil else { return nil }
        guard presse.changeCount != avant else { return "" }
        return presse.string(forType: .string) ?? ""
    }

    // MARK: - Appels au pont, avec les repères qu'on éprouve

    private func candidats(_ cible: RelaisCible) async -> [String] {
        let r = try? await page.appeler("return window.__relais.candidats(cible);",
                                        ["cible": cible.rawValue])
        return (r?["candidats"] as? [String]) ?? []
    }

    /// Le texte de la zone, ou `nil` quand elle est introuvable.
    private func lire(_ composeur: String) async -> String? {
        guard let r = try? await page.appeler("return window.__relais.lire(sel);",
                                              ["sel": composeur]),
              r["ok"] as? Bool == true else { return nil }
        return (r["texte"] as? String) ?? ""
    }

    private func ecrireLEssai(dans composeur: String) async throws {
        try Task.checkCancellation()
        _ = try? await page.appeler("return window.__relais.ecrire(sel, texte);",
                                    ["sel": composeur, "texte": RelaisPage.essai])
    }

    private func cliquer(_ cible: RelaisCible, _ selecteur: String) async -> Bool {
        let r = try? await page.appeler("return window.__relais.cliquer(cible, sel);",
                                        ["cible": cible.rawValue, "sel": selecteur])
        return r?["ok"] as? Bool == true
    }

    /// L'état de la page lu avec les repères en cours d'épreuve, et non avec
    /// le calibrage en place — qu'on est peut-être en train de remplacer
    /// parce qu'il est faux.
    private func etat(_ micro: String, _ stop: String,
                      _ composeur: String) async -> [String: Any]? {
        try? await page.appeler("return window.__relais.etat(micro, stop, composeur);",
                                ["micro": micro, "stop": stop, "composeur": composeur])
    }
}

/// Le presse-papiers entier, pour le rendre tel quel.
///
/// Tous les éléments et tous leurs types, et non la seule chaîne : une image,
/// un fichier ou un texte mis en forme qu'on y gardait ne doit pas revenir en
/// texte brut — ni disparaître.
@MainActor
private struct PressePapiers {
    private let elements: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ presse: NSPasteboard) {
        elements = (presse.pasteboardItems ?? []).map { element in
            element.types.compactMap { type in element.data(forType: type).map { (type, $0) } }
        }
    }

    func rendre(_ presse: NSPasteboard) {
        presse.clearContents()
        let rendus = elements.map { types -> NSPasteboardItem in
            let element = NSPasteboardItem()
            for (type, donnees) in types { element.setData(donnees, forType: type) }
            return element
        }
        if !rendus.isEmpty { presse.writeObjects(rendus) }
    }
}
