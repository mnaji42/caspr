import Foundation
import WebKit
import CasprCore

/// L'écho, côté Swift : le son que la page ChatGPT capte, reçu en mémoire vive.
///
/// La page tient le micro pendant qu'elle écoute, et celui que Caspr ouvrirait
/// ne recevrait que du silence : on reçoit donc la copie de son propre flux
/// (cf. `RelaisScripts.echo`). Une ligne de journal par dictée dit ce qui est
/// arrivé ; le son sert au repli par la voie macOS, quand on renonce à
/// ChatGPT ou qu'il échoue (cf. `RelaisRepli`).
///
/// Rien sur disque : un tableau en mémoire, gardé après le désarmement — la
/// transcription de ChatGPT vient après l'arrêt, et c'est pendant qu'on
/// l'attend qu'on peut y renoncer —, puis pris par le repli ou libéré à la
/// fin de la dictée (cf. `Relais.finirLeCycle`). Il survit à la mort du
/// processus de la page : c'est le même objet, et la même page rechargée.
@MainActor
final class RelaisEcho {

    static let gestionnaire = "casprEcho"
    /// Le monde de Caspr : `window.webkit` n'y est pas visible de chatgpt.com.
    static let monde = WKContentWorld.world(name: "caspr")

    /// Tirés au hasard pour chaque page : la page ne peut ni les deviner, ni
    /// émettre à notre place.
    private let evenement = nom(), signalArmer = nom(), signalDesarmer = nom()
    private weak var webView: WKWebView?
    private var arme = false
    /// Le clic du micro. Sans lui, pas de ligne : « rien reçu, 0 appel » se
    /// lirait comme une capture faite ailleurs, quand c'est la dictée qui n'a
    /// pas commencé.
    private var ecouteDepuis: ContinuousClock.Instant?
    private var echantillons: [Float] = []
    /// Tout ce qui est arrivé depuis l'armement, pour la ligne du journal : le
    /// son a pu être pris avant le désarmement — une annulation pendant
    /// l'écoute —, et la ligne dirait « rien reçu ».
    private var recus = 0
    private var crete: Float = 0
    private var statut: [String: Any] = [:]

    /// Chaque morceau reçu, et la fréquence du contexte de la page, pour
    /// l'aperçu en direct (cf. `ApercuEnDirect.nourrir`) ; `nil` sans aperçu.
    ///
    /// Posé quand la page s'est mise à écouter, après le clic : le son déjà
    /// reçu depuis l'armement part d'un bloc, sans quoi les premiers mots
    /// manqueraient à l'aperçu.
    var surMorceau: ((ArraySlice<Float>, Double) -> Void)? {
        didSet { if !echantillons.isEmpty { surMorceau?(echantillons[...], taux) } }
    }

    private static func nom() -> String {
        String((0..<16).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
    }

    /// Installe les deux scripts et le gestionnaire, avant la vue.
    ///
    /// Le gestionnaire passe par un mandataire faible : le contrôleur retient
    /// fortement le sien, et sans mandataire ni retrait la page — et le micro
    /// avec elle — survivraient au passage à macOS.
    func installer(dans controleur: WKUserContentController) {
        controleur.addUserScript(WKUserScript(
            source: RelaisScripts.echo(evenement: evenement, armer: signalArmer,
                                       desarmer: signalDesarmer),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controleur.addUserScript(WKUserScript(
            source: RelaisScripts.relaisEcho(evenement: evenement),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.monde))
        controleur.add(Mandataire(self), contentWorld: Self.monde, name: Self.gestionnaire)
    }

    func relier(_ vue: WKWebView) { webView = vue }

    /// Arme l'écho, juste avant le clic du micro — sur un son vide : celui
    /// d'une dictée précédente ne doit jamais passer pour celui-ci.
    func armer() {
        liberer()
        recus = 0
        crete = 0
        statut = [:]
        arme = true
        signaler(signalArmer)
    }

    /// Le micro est cliqué : la page écoute, et la dictée aura sa ligne.
    func ecouter() {
        if arme { ecouteDepuis = .now }
    }

    /// Désarme et écrit la ligne de la dictée — sur-le-champ. Le son reçu
    /// reste, pour le repli.
    ///
    /// Sans attendre la page : une page figée ne rendrait jamais la main, et la
    /// ligne resterait en suspens. On y perd au plus le dernier morceau encore
    /// en route (un quart de seconde). Sans effet s'il n'est pas armé :
    /// chaque sortie d'une dictée l'appelle, la mort et la destruction de la
    /// page comprises.
    func desarmer() {
        guard arme else { return }
        arme = false
        signaler(signalDesarmer)
        defer { ecouteDepuis = nil }
        guard let debut = ecouteDepuis else { return }
        let appels = (statut["appels"] as? Int).map { "\($0) appel\($0 > 1 ? "s" : "") à getUserMedia" }
            ?? "aucun statut de la page"
        let niveau = "crête " + Self.decimal(Double(crete), 3)
        let etat = statut["etat"] as? String ?? "?"
        guard recus > 0 else {
            return Log.notice("relais : écho — rien reçu (\(niveau), \(appels), contexte \(etat))")
        }
        let duree = Double((.now - debut) / .milliseconds(1)) / 1000
        let piste = (statut["piste"] as? Int).map { "\($0) Hz" } ?? "? Hz"
        Log.notice("relais : écho — \(Self.decimal(Double(recus) / taux, 1)) s reçues "
                 + "pour \(Self.decimal(duree, 1)) s d'écoute, piste \(piste), contexte "
                 + "\(etat) à \(Int(taux)) Hz, \(niveau), \(appels)")
    }

    /// La fréquence du contexte de la page : 16 kHz demandés, ceux de la
    /// voie macOS.
    private var taux: Double { statut["taux"] as? Double ?? 16000 }

    /// La durée du son reçu, en secondes ; zéro s'il est inutilisable (cf.
    /// `prendre`).
    var secondes: Double { taux == 16000 ? Double(echantillons.count) / taux : 0 }

    /// Le son reçu depuis l'armement, pour la voie macOS ; il quitte l'écho.
    ///
    /// Vide si le contexte n'a pas tourné à 16 kHz : transcrit comme tel, un
    /// autre débit rendrait un texte faux, sans que rien ne le dise.
    func prendre() -> [Float] {
        defer { liberer() }
        guard taux == 16000 else {
            Log.error("relais : écho à \(Int(taux)) Hz, inutilisable par macOS")
            return []
        }
        return echantillons
    }

    /// Oublie le son reçu : la dictée est livrée, ou le repli l'a pris.
    ///
    /// Désarmé d'abord : pris pendant l'écoute — la croix, une page morte —,
    /// le son laissait l'écho armé jusqu'à l'arrêt de la page, et ce qui
    /// arrivait entre-temps restait en mémoire jusqu'à la dictée suivante.
    func liberer() {
        desarmer()
        surMorceau = nil
        echantillons = []
    }

    /// Tiré sans attendre : rien ne s'attend, sur le chemin d'une dictée,
    /// qu'une page pourrait retenir.
    private func signaler(_ nom: String) {
        webView?.callAsyncJavaScript("document.dispatchEvent(new CustomEvent(n));",
                                     arguments: ["n": nom], in: nil, in: Self.monde)
    }

    fileprivate func recevoir(_ message: WKScriptMessage) {
        // Les popups de connexion partagent la configuration, donc ce
        // gestionnaire : seul le cadre principal de la page, sur chatgpt.com,
        // est entendu.
        let hote = message.frameInfo.securityOrigin.host
        guard arme, message.frameInfo.isMainFrame, message.webView === webView,
              hote == "chatgpt.com" || hote.hasSuffix(".chatgpt.com"),
              let corps = message.body as? String, corps.utf8.count <= 64 * 1024 else { return }
        if corps.hasPrefix("{") {
            // Fusionné : le statut d'un appel à getUserMedia, sans contexte,
            // n'efface pas la fréquence que celui du branchement a donnée.
            let json = try? JSONSerialization.jsonObject(with: Data(corps.utf8))
            for (cle, valeur) in json as? [String: Any] ?? [:] where !(valeur is NSNull) {
                statut[cle] = valeur
            }
        } else if let octets = Data(base64Encoded: corps) {
            recus += octets.count / 2
            let debut = echantillons.count
            octets.withUnsafeBytes { brut in
                for i in stride(from: 0, to: brut.count - 1, by: 2) {
                    let n = Int16(littleEndian: brut.loadUnaligned(fromByteOffset: i, as: Int16.self))
                    echantillons.append(Float(n) / 32768)
                    crete = max(crete, abs(Float(n) / 32768))
                }
            }
            surMorceau?(echantillons[debut...], taux)
        }
    }

    private static func decimal(_ x: Double, _ chiffres: Int) -> String {
        String(format: "%.\(chiffres)f", x).replacingOccurrences(of: ".", with: ",")
    }

    /// Le gestionnaire que retient WebKit, sans retenir l'écho.
    private final class Mandataire: NSObject, WKScriptMessageHandler {
        weak var echo: RelaisEcho?
        init(_ echo: RelaisEcho) { self.echo = echo }
        func userContentController(_ controleur: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            echo?.recevoir(message)
        }
    }
}
