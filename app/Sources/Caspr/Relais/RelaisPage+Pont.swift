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
        let texte, voie, zone, selecteur, parent, menu, menuParent: String?
        let repond: Bool?
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
    func pont<T: Decodable>(_ fonction: String, _ args: Any...) async throws -> T {
        try JSONDecoder().decode(T.self, from: await appeler(fonction, args))
    }

    /// Les relevés que la page rend en vrac — `etat`, `releve`, `erreur`,
    /// `etatReponse` —, sans type dédié : ils seront fondus en un seul.
    func pont(_ fonction: String, _ args: Any...) async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: await appeler(fonction, args)) as? [String: Any] ?? [:]
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
    /// (`Erreur.pontAbsent`) : le script ne s'y est pas installé, et rien ne
    /// l'y installera. Attendre, sans échéance, ce serait attendre toujours.
    private func appeler(_ fonction: String, _ args: [Any]) async throws -> Data {
        // Une tâche déjà annulée ne touche plus à la page : le clic qu'elle
        // demandait n'est plus voulu par personne.
        try Task.checkCancellation()
        // Une page morte qu'on a renoncé à recharger revit dès qu'on s'en
        // sert : l'appel tombe sur la page qui arrive, et chaque attente sait
        // déjà patienter devant un chargement.
        if rechargementRetenu { charger() }
        let vue: WKWebView = webView
        let appel = AppelAnnulable<String?>()
        enSuspens.append(appel)
        defer { enSuspens.removeAll { $0 === appel } }
        Task {
            do {
                let brut = try await vue.callAsyncJavaScript("""
                    const r = window.__relais;
                    if (!r) return '{"__absent":true}';
                    return JSON.stringify(await r[f](...a));
                    """, arguments: ["f": fonction, "a": args], in: nil, contentWorld: .page)
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
            guard !chargementEnCours, pageWeb else { throw PontPasEncoreLa() }
            Log.error("relais : le pont est absent d'une page chargée (\(fonction))")
            throw Erreur.pontAbsent
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

    // MARK: - Les fonctions de la page

    func cliquer(_ cible: RelaisCible, sel: String) async throws -> Bool {
        try await (pont("cliquer", cible.rawValue, sel) as Rendu).ok
    }

    /// Le texte de la zone de saisie ; `nil` quand elle est introuvable.
    func lire(sel: String) async throws -> String? { try await texte(pont("lire", sel)) }

    @discardableResult
    func ecrire(_ texte: String, sel: String) async throws -> Bool {
        try await (pont("ecrire", sel, texte) as Rendu).ok
    }

    func vider(sel: String) async throws { let _: Rendu = try await pont("vider", sel) }

    func encadrer(sel: String, avant: String, apres: String) async throws -> Bool {
        try await (pont("encadrer", sel, avant, apres) as Rendu).ok
    }

    /// Le message a-t-il quitté la zone ? Ce qu'elle porte encore — `nil`
    /// quand elle est absente, ce qui ne prouve rien —, et si ChatGPT répond.
    func depart(sel: String, avant: Int) async throws -> (zone: String?, repond: Bool) {
        let r: Rendu = try await pont("depart", sel, avant)
        return (r.zone, r.repond == true)
    }

    /// Clique « copier » ; rend la voie suivie — la paire, ou le repère seul
    /// autour de la dernière réponse —, `nil` quand rien n'a été cliqué.
    func copierLaReponse(parent: String, copier: String, reponse: String) async throws -> String? {
        let r: Rendu = try await pont("copierLaReponse", parent, copier, reponse)
        return r.ok ? r.voie ?? "?" : nil
    }

    func cliquerBouton(parent: String, bouton: String) async throws -> Bool {
        try await (pont("cliquerBouton", parent, bouton) as Rendu).ok
    }

    /// Le texte de la dernière réponse ; `nil` quand elle est introuvable.
    func lireReponse(sel: String) async throws -> String? {
        try await texte(pont("lireReponse", sel))
    }

    private func texte(_ r: Rendu) -> String? { r.ok ? r.texte ?? "" : nil }

    func oublierBrouillon() async throws { let _: Rendu = try await pont("oublierBrouillon") }

    func compacter(_ actif: Bool, sel: String) async throws {
        let _: Rendu = try await pont("compacter", actif, sel)
    }

    /// Les repères que la calibration automatique éprouvera, dans l'ordre.
    func candidats(_ cible: RelaisCible) async throws -> [String] {
        try await (pont("candidats", cible.rawValue) as Liste<String>).candidats ?? []
    }

    /// Les boutons « copier » de la dernière réponse, avec leur bloc.
    func candidatsCopier(reponse: String) async throws -> [Repere] {
        try await (pont("candidatsCopier", reponse) as Liste<Repere>).candidats ?? []
    }

    /// Guette un clic de l'utilisateur sur un élément de ce genre ; `nil` à
    /// l'abandon (cf. `abandonnerCalibration`).
    func calibrer(genre: String) async throws -> Repere? { try await repere(pont("calibrer", genre)) }

    /// Guette un clic, ouvre-menu compris (cf. `calibrerAvecMenu` du pont).
    func calibrerAvecMenu() async throws -> Repere? { try await repere(pont("calibrerAvecMenu")) }

    private func repere(_ r: Rendu) -> Repere? {
        r.ok ? Repere(selecteur: r.selecteur ?? "", parent: r.parent ?? "",
                      menu: r.menu ?? "", menuParent: r.menuParent ?? "") : nil
    }

    /// Fait renoncer une calibration qui attend un clic — au repos.
    func abandonnerCalibration() async {
        _ = await sonder { try await self.pont("abandonnerCalibration") as Rendu }
    }

    /// Connecté ou non, en train d'écouter ou non — par les repères du
    /// calibrage, sauf ceux qu'on donne.
    func etat(micro: String? = nil, stop: String? = nil,
              composeur: String? = nil) async throws -> [String: Any] {
        try await pont("etat", micro ?? selecteurs.micro, stop ?? selecteurs.stop,
                       composeur ?? selecteurs.composeur)
    }

    func releve() async throws -> [String: Any] { try await pont("releve") }

    func erreur(connues: [String], nouvelles: Bool, avant: Int) async throws -> [String: Any] {
        try await pont("erreur", connues, nouvelles, avant)
    }

    func etatReponse(avant: Int) async throws -> [String: Any] { try await pont("etatReponse", avant) }
}
