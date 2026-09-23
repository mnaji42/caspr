import Foundation
import WebKit
import CasprCore

/// L'écho, côté Swift : le son que la page ChatGPT capte, reçu en mémoire vive.
///
/// La page tient le micro pendant qu'elle écoute, et celui que Caspr ouvrirait
/// ne recevrait que du silence : on reçoit donc la copie de son propre flux
/// (cf. `RelaisScripts.echo`). Pour l'instant, on ne fait que mesurer ce qui
/// arrive — une ligne de journal par dictée —, pour savoir si un repli par la
/// voie macOS, et un aperçu en direct, peuvent s'y adosser.
///
/// Rien sur disque : un tableau en mémoire, libéré au désarmement.
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
    private var crete: Float = 0
    private var statut: [String: Any] = [:]

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

    /// Arme l'écho, juste avant le clic du micro.
    func armer() {
        desarmer()
        arme = true
        signaler(signalArmer)
    }

    /// Le micro est cliqué : la page écoute, et la dictée aura sa ligne.
    func ecouter() {
        if arme { ecouteDepuis = .now }
    }

    /// Désarme, écrit la ligne de la dictée et libère le son — sur-le-champ.
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
        defer { echantillons = []; crete = 0; statut = [:]; ecouteDepuis = nil }
        guard let debut = ecouteDepuis else { return }
        let appels = (statut["appels"] as? Int).map { "\($0) appel\($0 > 1 ? "s" : "") à getUserMedia" }
            ?? "aucun statut de la page"
        let niveau = "crête " + Self.decimal(Double(crete), 3)
        let etat = statut["etat"] as? String ?? "?"
        guard !echantillons.isEmpty else {
            return Log.notice("relais : écho — rien reçu (\(niveau), \(appels), contexte \(etat))")
        }
        let duree = Double((.now - debut) / .milliseconds(1)) / 1000
        let taux = statut["taux"] as? Double ?? 16000
        let piste = (statut["piste"] as? Int).map { "\($0) Hz" } ?? "? Hz"
        Log.notice("relais : écho — \(Self.decimal(Double(echantillons.count) / taux, 1)) s reçues "
                 + "pour \(Self.decimal(duree, 1)) s d'écoute, piste \(piste), contexte "
                 + "\(etat) à \(Int(taux)) Hz, \(niveau), \(appels)")
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
            octets.withUnsafeBytes { brut in
                for i in stride(from: 0, to: brut.count - 1, by: 2) {
                    let n = Int16(littleEndian: brut.loadUnaligned(fromByteOffset: i, as: Int16.self))
                    echantillons.append(Float(n) / 32768)
                    crete = max(crete, abs(Float(n) / 32768))
                }
            }
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
