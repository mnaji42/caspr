import Foundation
import Observation
import CasprCore

/// Regarde s'il existe une version plus récente, sur les releases GitHub.
///
/// Caspr ne passe par aucun magasin d'applications : rien d'extérieur ne le
/// tiendra à jour, et une correction de bug ne parviendrait jamais à quelqu'un
/// qui a installé une fois et n'y pense plus. Cette vérification est le seul
/// canal qui reste.
///
/// Elle ne fait que *constater*. L'installation appartient à
/// `UpdateInstaller`, qui prend le relais depuis les Réglages — la séparation
/// tient à ce que constater est anodin et installer ne l'est pas : le premier
/// a le droit de se déclencher tout seul une fois par jour, le second exige
/// un clic.
///
/// Elle compare des **releases**, pas des commits. Une branche `main` bouge
/// plusieurs fois par jour, souvent pour des travaux en cours ; prévenir à
/// chaque commit reviendrait à ne jamais être cru. Un tag est une déclaration
/// explicite : « cette version-ci est bonne à installer ».
///
/// Aucune erreur n'est présentée à l'utilisateur. Un réseau coupé, une API
/// injoignable ou un quota GitHub épuisé ne sont pas des évènements qui
/// justifient d'interrompre quelqu'un dans son travail — la vérification
/// réessaiera demain.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let page: URL
        let notes: String
        /// Quand GitHub l'a publiée. La carte l'affiche à côté du numéro :
        /// « v0.9.2 » ne dit pas si la version date d'hier ou de l'an dernier,
        /// et c'est ce qui fait la différence entre « installer maintenant » et
        /// « je verrai plus tard ».
        let publishedAt: Date?
        /// L'image disque attachée à la release, quand il y en a une.
        ///
        /// Facultative, et c'est voulu : une release publiée à la main, ou
        /// dont le build a échoué, n'en a pas. Dans ce cas la mise à jour
        /// intégrée est simplement indisponible et la page reste offerte —
        /// plutôt qu'un bouton qui promet une installation impossible.
        let asset: Asset?

        struct Asset: Equatable {
            let url: URL
            /// Annoncée par GitHub, sert à détecter un téléchargement tronqué
            /// et à afficher un avancement qui veut dire quelque chose.
            let size: Int64
        }
    }

    /// Renseigné seulement si la version distante est **strictement**
    /// supérieure à celle qui tourne.
    private(set) var newer: Release?
    private(set) var checking = false
    /// Pour le bouton « vérifier maintenant » des Réglages, qui lui a le droit
    /// de dire que ça n'a pas marché : l'utilisateur vient de le demander.
    private(set) var lastError: String?

    /// Quand la dernière vérification a abouti. Persistée, donc survit au
    /// redémarrage — sans quoi les Réglages afficheraient « à jour » au premier
    /// lancement, alors que rien n'a encore été demandé à personne.
    var lastCheckedAt: Date? {
        UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    }

    private let endpoint = URL(string:
        "https://api.github.com/repos/mnaji42/caspr/releases/latest")!
    private let lastCheckKey = "caspr.update.lastCheck"

    // MARK: - Identité du build

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Ce bundle correspond-il exactement à un tag, arbre propre ?
    ///
    /// Écrit par scripts/install.sh depuis git. Une machine de développement
    /// est presque toujours en avance sur la dernière release : lui proposer
    /// de « mettre à jour » vers du code plus ancien que le sien serait absurde.
    static var isReleaseBuild: Bool {
        Bundle.main.infoDictionary?["CasprIsRelease"] as? Bool ?? false
    }

    static var gitDescribe: String {
        Bundle.main.infoDictionary?["CasprGitDescribe"] as? String ?? "inconnu"
    }

    /// Ce que les Réglages affichent sous la version.
    static var buildLabel: String {
        isReleaseBuild ? currentVersion : "\(currentVersion) · build de développement"
    }

    // MARK: - Déclenchement

    /// Appelé au lancement. Ne fait rien la plupart du temps.
    func checkIfDue() async {
        guard Preferences.shared.checksForUpdates else { return }
        guard Self.isReleaseBuild else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        // Une fois par jour. L'API publique de GitHub tolère soixante appels
        // par heure et par adresse ; le vrai motif est ailleurs : une app qui
        // interroge un serveur à chaque lancement est une app qui traque.
        if let last, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await check()
    }

    /// Vérification explicite, depuis les Réglages. Ignore la temporisation et
    /// le garde-fou du build de développement — c'est le seul moyen de tester
    /// la fonction sans publier une release.
    func check() async {
        guard !checking else { return }
        checking = true
        lastError = nil
        defer { checking = false }

        do {
            var request = URLRequest(url: endpoint)
            // L'API de GitHub rejette les requêtes sans User-Agent.
            request.setValue("Caspr/\(Self.currentVersion)",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json",
                             forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            // Ne pas servir une réponse de cache : la question posée est
            // précisément « qu'y a-t-il de neuf ».
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                // 404 tant qu'aucune release n'est publiée : ce n'est pas une
                // panne, c'est l'état normal d'un dépôt encore vierge.
                throw Failure.http(code)
            }

            let payload = try JSONDecoder().decode(Payload.self, from: data)
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)

            let remote = payload.tagName.hasPrefix("v")
                ? String(payload.tagName.dropFirst())
                : payload.tagName
            guard Version.isNewer(remote, than: Self.currentVersion),
                  let page = URL(string: payload.htmlUrl) else {
                newer = nil
                return
            }

            // On retient l'URL que l'API donne pour *cette* release-ci, pas
            // l'adresse `releases/latest/download` : entre le moment où on
            // annonce une version et celui où l'utilisateur clique, une autre
            // peut être publiée, et il installerait alors autre chose que ce
            // qui lui a été présenté.
            let dmg = payload.assets.first { $0.name == UpdateInstaller.assetName }
            let asset = dmg.flatMap { file in
                URL(string: file.browserDownloadUrl).map {
                    Release.Asset(url: $0, size: file.size)
                }
            }

            newer = Release(version: remote, page: page,
                            notes: payload.body ?? "",
                            publishedAt: payload.publishedAt.flatMap {
                                ISO8601DateFormatter().date(from: $0)
                            },
                            asset: asset)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Réponse

    private struct Payload: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let publishedAt: String?
        /// Absent d'une release sans pièce jointe : `decodeIfPresent` plutôt
        /// qu'un champ obligatoire, sinon le décodage échoue en entier et
        /// l'application se croit à jour.
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            let size: Int64

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
                case size
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body
            case assets
            case publishedAt = "published_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try c.decode(String.self, forKey: .tagName)
            htmlUrl = try c.decode(String.self, forKey: .htmlUrl)
            body = try c.decodeIfPresent(String.self, forKey: .body)
            assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
            publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        }
    }

    private enum Failure: LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(404): "Aucune release publiée pour l'instant."
            case .http(let code): "GitHub a répondu \(code)."
            }
        }
    }
}
