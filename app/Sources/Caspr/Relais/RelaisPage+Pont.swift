import WebKit
import CasprCore

// La façade du pont (`RelaisScripts.pont`) : un seul point d'appel, et une
// méthode typée par fonction de la page. Le JavaScript ne s'écrit plus que
// là-bas ; ici, on ne fait que l'appeler et relire ce qu'il rend.
extension RelaisPage {

    /// Un repère appris d'un clic, ou proposé par la page pour « copier ».
    struct Repere: Decodable {
        let selecteur: String
        /// Le premier ancêtre qui porte un repère (cf. `selecteurAncetre`).
        let parent: String
        /// L'ouvre-menu cliqué d'abord, pour « Lire à haute voix ».
        var menu = "", menuParent = ""
        private enum CodingKeys: CodingKey { case selecteur, parent }
    }

    /// Ce que rend une fonction du pont : chacune n'en remplit qu'une partie.
    private struct Rendu: Decodable {
        let ok: Bool
        let texte, voie, selecteur, parent, menu, menuParent: String?
    }

    private struct Liste<Element: Decodable>: Decodable {
        let candidats: [Element]?
    }

    /// Un pont absent d'une page qui n'a pas fini d'arriver — ou qui n'est pas
    /// une page web : rien de prouvé, l'appelant réessaie comme devant un
    /// silence.
    private struct PontPasEncoreLa: Error {}

    // MARK: - Le point d'appel

    /// Appelle `fonction` du pont avec `args`, et décode ce qu'elle rend.
    ///
    /// **Sans délai** : c'est le chemin d'une dictée (cf. `appeler`). Au
    /// repos, où un silence doit se constater, on l'enveloppe dans `sonder`.
    func pont<T: Decodable>(_ fonction: RelaisScripts.Fonction, _ args: Any...) async throws -> T {
        try JSONDecoder().decode(T.self, from: await appeler(fonction, args))
    }

    /// Un appel au pont, sur le chemin d'une dictée : **sans délai**.
    ///
    /// Il a porté un délai de cinq secondes, qui faisait passer une page lente
    /// pour une page figée, la rechargeait, et jetait la dictée avec elle.
    /// ChatGPT met parfois trente secondes, ou plusieurs minutes, à rendre ce
    /// qu'on lui a dicté longtemps : ce n'est pas au temps de décider qu'on
    /// renonce (cf. RELAIS.md, sixième règle).
    ///
    /// La sortie reste instantanée : l'annulation de la tâche appelante — la
    /// touche de dictée, la croix — tranche l'attente sur-le-champ, même quand
    /// l'appel JavaScript ne revient jamais (cf. `AppelAnnulable`).
    /// `callAsyncJavaScript` ne s'annule pas : on cesse seulement d'attendre
    /// ici, et l'appel resté en suspens finit dans le vide.
    ///
    /// Le nom de la fonction et ses arguments passent en arguments, jamais
    /// dans le corps : aucun texte dicté n'est interprété comme du code. La
    /// page rend du JSON, qu'on décode ici.
    ///
    /// Un pont absent d'une page chargée est un échec prouvé
    /// (`RelaisErreur.pontAbsent`) : le script ne s'y est pas installé, et
    /// rien ne l'y installera. Attendre, sans échéance, ce serait attendre
    /// toujours.
    private func appeler(_ fonction: RelaisScripts.Fonction, _ args: [Any]) async throws -> Data {
        // Une tâche déjà annulée ne touche plus à la page : le clic qu'elle
        // demandait n'est plus voulu par personne.
        try Task.checkCancellation()
        // Une page morte qu'on a renoncé à recharger revit dès qu'on s'en
        // sert : l'appel tombe sur la page qui arrive, et chaque attente sait
        // déjà patienter devant un chargement.
        if rechargementRetenu { charger() }
        let vue: WKWebView = webView
        // Qu'une page se charge, `chargementEnCours` le dit dès l'ordre de
        // `charger()`, et `isLoading` pour toutes les autres navigations :
        // « Recharger » de la grande fenêtre, une redirection après la
        // connexion. Relu avant l'appel aussi : une absence relevée pendant un
        // chargement qui s'achève entre-temps ne prouve rien.
        let chargeait = chargementEnCours || vue.isLoading
        let appel = AppelAnnulable<String?>()
        enSuspens.append(appel)
        defer { enSuspens.removeAll { $0 === appel } }
        Task {
            do {
                let brut = try await vue.callAsyncJavaScript("""
                    const r = window.__relais;
                    if (!r) return '{"__absent":true}';
                    return JSON.stringify(await r[f](...a));
                    """, arguments: ["f": fonction.rawValue, "a": args], in: nil, contentWorld: Self.monde)
                appel.rendre(.success(brut as? String))
            } catch {
                appel.rendre(.failure(error))
            }
        }
        let json = try await appel.attendre() ?? "null"
        if json == #"{"__absent":true}"# {
            // Pendant un chargement, le pont n'est pas encore posé ; sans page
            // web — rien de chargé, hors ligne —, il n'a nulle part où l'être.
            let pageWeb = ["http", "https"].contains(vue.url?.scheme ?? "")
            guard !chargeait, !chargementEnCours, !vue.isLoading, pageWeb else { throw PontPasEncoreLa() }
            Log.error("relais : le pont est absent d'une page chargée (\(fonction))")
            throw RelaisErreur.pontAbsent
        }
        return Data(json.utf8)
    }

    /// Une opération sur la page **au repos**, qui renonce au bout de
    /// `duree` ; `nil` veut dire « pas de réponse », ou rien à rendre.
    ///
    /// **Au repos seulement** — préparer la page, l'arrêter après un abandon,
    /// l'étiquette, le diagnostic, la calibration. Un silence n'y mène qu'à
    /// reconstruire la page au repos (cf. `Relais.reconstruireLaPage`) ou à
    /// dire « la page ne répond pas » ; jamais à faire échouer une dictée,
    /// dont les attentes appellent le pont directement.
    func sonder<T>(auPlus duree: Duration = .seconds(5),
                   _ operation: @escaping @MainActor () async throws -> T?) async -> T? {
        (try? await auPlus(duree, operation)) ?? nil
    }

    /// Fait courir une opération contre le temps ; `nil` si le temps gagne.
    ///
    /// Une erreur de l'opération passe telle quelle — un guetteur de
    /// calibration dont la page a changé n'a pas « attendu trois minutes ».
    /// L'opération doit céder à l'annulation, sans quoi le groupe l'attendrait
    /// quand même : c'est ce qu'`AppelAnnulable` lui garantit.
    func auPlus<T>(_ duree: Duration,
                   _ operation: @escaping @MainActor () async throws -> T) async throws -> T? {
        try await withThrowingTaskGroup(of: Colis<T>?.self) { groupe in
            groupe.addTask { @MainActor in Colis(valeur: try await operation()) }
            groupe.addTask {
                try await Task.sleep(for: duree)
                return nil
            }
            defer { groupe.cancelAll() }
            return (try await groupe.next() ?? nil)?.valeur
        }
    }

    /// Observe `condition` jusqu'à ce qu'elle tienne ; faux à la borne. Lève
    /// à l'annulation : ce qu'on attendait n'a plus d'objet, et l'appelant ne
    /// doit rien conclure du temps passé.
    ///
    /// **Au repos et en calibration seulement**, comme `sonder` : une page
    /// qui se charge, une main qui se connecte, un geste dont on guette
    /// l'effet. Jamais sur le chemin d'une dictée, dont les attentes n'ont
    /// pas d'échéance (cf. `RelaisDictee.observer`). La primitive du relais
    /// (`RelaisHorloge.guetter`), bornée.
    func observer(auPlus duree: Duration, toutes pas: Duration = .milliseconds(250),
                  _ condition: () async -> Bool) async throws -> Bool {
        try await RelaisHorlogeReelle.systeme.guetter(toutes: pas, auPlus: duree) { await condition() ? () : nil } != nil
    }

    // MARK: - Au repos

    /// Ce que la page dit d'elle-même, au repos : l'arrêt après un abandon,
    /// la préparation de la dictée suivante, le diagnostic.
    ///
    /// C'est la page qui fait foi, pas un drapeau tenu de notre côté. Qu'elle
    /// écoute : un drapeau local se désynchronisait à la première erreur, et
    /// le geste suivant relançait une dictée par-dessus au lieu de l'arrêter.
    /// Qu'elle porte une conversation : une réorganisation qui échoue à
    /// mi-chemin a tout de même envoyé son message, et c'est la page qui le
    /// sait.
    ///
    /// `nil` quand elle ne répond pas, quelle qu'en soit la raison — page
    /// muette, pont absent : ni oui ni non, et la seule préparation qui vaille
    /// alors est de la reconstruire.
    func auRepos() async -> RelaisInstantane? {
        await sonder { try await self.instantane() }
    }

    /// Attend que la page rechargée soit prête, zone de saisie comprise — au
    /// repos, borné.
    ///
    /// **Sans se fier au calibrage.** Une calibration s'appuyait sur les
    /// repères qu'elle allait remplacer, et ceux-ci peuvent être absents —
    /// c'est le premier lancement — ou faux, c'est-à-dire exactement la
    /// raison pour laquelle on recalibre. On a ainsi « vidé » un bouton micro
    /// que le calibrage désignait comme la zone de texte. Les heuristiques du
    /// pont, elles, ne dépendent de rien.
    func attendreComposeurPret(secondes: Double) async -> Bool {
        (try? await observer(auPlus: .seconds(secondes)) {
            guard !chargementEnCours else { return false }
            return await sonder({ try await self.lire(sel: "") }) != nil
        }) == true
    }

    /// Vide la zone de saisie, et s'assure qu'elle l'est restée — au repos.
    @discardableResult
    func viderComposeur(selecteur: String? = nil) async -> Bool {
        // Le brouillon vit aussi dans le stockage de la page : l'effacer de la
        // zone ne suffit pas, ChatGPT le réinstalle depuis là.
        _ = await sonder { try await self.oublierBrouillon() }
        // Vider, c'est écrire vide : une seule règle pour les deux.
        let vide = await ecrire("", sel: selecteur ?? selecteurs.composeur, pendant: 6, jusqua: \.isEmpty)
        if !vide, !Task.isCancelled { Log.error("relais : la zone de saisie n'a pas voulu se vider") }
        return vide
    }

    /// Écrit `texte` dans la zone `sel` (vide : le filet) jusqu'à l'y relire
    /// comme `tenu` le veut — au repos, `secondes` au plus ; faux sinon.
    ///
    /// Relu, et réécrit tant qu'il ne tient pas. La zone existe dans le DOM
    /// avant que ChatGPT n'en ait repris le contrôle : le texte y était bien
    /// déposé, puis effacé par le rendu qui suivait. Et ChatGPT réinstalle le
    /// brouillon non envoyé après un rechargement, parfois après qu'on l'a
    /// effacé : vider une fois ne suffit pas.
    func ecrire(_ texte: String, sel: String, pendant secondes: Double,
                jusqua tenu: @escaping (String) -> Bool) async -> Bool {
        (try? await observer(auPlus: .seconds(secondes), toutes: .zero) {
            _ = await sonder { try await self.ecrire(texte, sel: sel) }
            try? await Task.sleep(for: .milliseconds(500))
            return await sonder({ try await self.lire(sel: sel) }).map(tenu) == true
        }) == true
    }

    /// Recharge la page de départ, attend sa zone de saisie et la vide, par le
    /// filet — au repos ; faux quand la zone n'est pas venue.
    ///
    /// Le départ des deux parcours de calibration, et de l'essai qui suit un
    /// candidat raté : une conversation neuve, sans le brouillon que ChatGPT
    /// réinstalle, et sans se fier au calibrage qu'on remplace peut-être
    /// parce qu'il est faux.
    func repartirAuFilet() async -> Bool {
        charger()
        guard await attendreComposeurPret(secondes: 30) else { return false }
        await viderComposeur(selecteur: "")
        return true
    }

    // MARK: - Les fonctions de la page

    func cliquer(_ cible: RelaisCible, sel: String) async throws -> Bool {
        let clique = try await (pont(.cliquer, cible.rawValue, sel) as Rendu).ok
        // La page écoute : une dictée qui a armé l'écho aura sa ligne (cf.
        // `RelaisEcho`) ; sans écho armé — la calibration —, rien.
        if clique, cible == .micro { echo.ecouter() }
        return clique
    }

    /// Le texte de la zone de saisie ; `nil` quand elle est introuvable.
    func lire(sel: String) async throws -> String? { try await texte(pont(.lire, sel)) }

    @discardableResult
    func ecrire(_ texte: String, sel: String) async throws -> Bool {
        try await (pont(.ecrire, sel, texte) as Rendu).ok
    }

    /// Clique « copier » ; rend la voie suivie — la paire, ou le repère seul
    /// autour de la dernière réponse —, `nil` quand rien n'a été cliqué.
    func copierLaReponse(parent: String, copier: String, reponse: String) async throws -> String? {
        let r: Rendu = try await pont(.copierLaReponse, parent, copier, reponse)
        return r.ok ? r.voie ?? "?" : nil
    }

    private func texte(_ r: Rendu) -> String? { r.ok ? r.texte ?? "" : nil }

    func oublierBrouillon() async throws { let _: Rendu = try await pont(.oublierBrouillon) }

    func compacter(_ actif: Bool, sel: String) async throws {
        let _: Rendu = try await pont(.compacter, actif, sel)
    }

    /// Les repères que la calibration automatique éprouvera, dans l'ordre.
    func candidats(_ cible: RelaisCible) async throws -> [String] {
        try await (pont(.candidats, cible.rawValue) as Liste<String>).candidats ?? []
    }

    /// Les boutons « copier » de la dernière réponse, avec leur bloc.
    func candidatsCopier(reponse: String) async throws -> [Repere] {
        try await (pont(.candidatsCopier, reponse) as Liste<Repere>).candidats ?? []
    }

    /// Guette le clic de l'utilisateur sur `cible` (cf. `guetter` du pont) ;
    /// `nil` à l'abandon (cf. `abandonnerCalibration`). Un repère vide : la
    /// page a refusé ce clic — un « copier » qui n'est pas celui de la
    /// dernière réponse, cherchée par `reponse`.
    func guetter(_ cible: RelaisCible, reponse: String) async throws -> Repere? {
        let r: Rendu = try await pont(.guetter, cible.rawValue, reponse)
        return r.ok ? Repere(selecteur: r.selecteur ?? "", parent: r.parent ?? "",
                             menu: r.menu ?? "", menuParent: r.menuParent ?? "") : nil
    }

    /// Fait renoncer une calibration qui attend un clic — au repos.
    func abandonnerCalibration() async {
        _ = await sonder { try await self.pont(.abandonnerCalibration) as Rendu }
    }

    /// Pose la marque : ce qu'un relevé comptera ensuite comme nouveau —
    /// échecs affichés et réponses de ChatGPT — est ce qui apparaît après.
    /// Effacée d'abord : une marque manquée ne laisse pas en place celle de
    /// la dictée d'avant, qui ferait passer sa réponse pour la nouvelle.
    func marquer() async throws {
        marque = nil
        marque = try await pont(.marquer)
    }

    /// Ce que la page dit d'elle-même, en un aller-retour — par les repères du
    /// calibrage, sauf ceux qu'on donne (vides : le filet).
    func instantane(_ demande: RelaisDemande = [],
                    reperes: RelaisSelecteurs?) async throws -> RelaisInstantane {
        // Les repères sous leurs noms de toujours (`micro`, `copierParent`…).
        let r = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reperes ?? selecteurs))
        let m = try marque.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        return try await pont(.instantane, r, ["texte": demande.contains(.texte),
                                              "reponse": demande.contains(.reponse),
                                              "alertes": demande.contains(.alertes)], m ?? NSNull())
    }
}

// Ce que le scénario d'une dictée demande à la page (cf. `RelaisDictee`), par
// les repères du calibrage.
extension RelaisPage: RelaisPageDictee {
    func instantane(_ demande: RelaisDemande = []) async throws -> RelaisInstantane {
        try await instantane(demande, reperes: nil)
    }

    func cliquer(_ cible: RelaisCible) async throws -> Bool { try await cliquer(cible, sel: selecteurs[cible]) }
    func vider() async throws { try await ecrire("", sel: selecteurs.composeur) }

    func encadrer(avant: String, apres: String) async throws -> Bool {
        try await (pont(.encadrer, selecteurs.composeur, avant, apres) as Rendu).ok
    }

    func copier() async throws -> String? {
        try await copierLaReponse(parent: selecteurs.copierParent, copier: selecteurs.copier,
                                  reponse: selecteurs.reponse)
    }

    /// Sans cadrage quand un menu l'a ouvert : la page pose ses éléments de
    /// menu ailleurs dans le document, hors du bloc de la réponse.
    func cliquerLecture(menu: Bool) async throws -> Bool {
        let s = selecteurs
        let (parent, bouton) = menu ? (s.lectureMenuParent, s.lectureMenu)
                                    : (s.lectureMenu.isEmpty ? s.lectureParent : "", s.lecture)
        return try await (pont(.cliquerBouton, parent, bouton) as Rendu).ok
    }

    func lireReponse() async throws -> String? { try await texte(pont(.lireReponse, selecteurs.reponse)) }

    func armerEcho() { echo.armer() }
    func desarmerEcho() { echo.desarmer() }
}
