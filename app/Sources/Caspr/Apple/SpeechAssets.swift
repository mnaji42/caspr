import Foundation
import Observation
import Speech

/// Les modèles de reconnaissance de macOS, langue par langue.
///
/// Ce n'est pas une option. Ce sont les actifs de la version **Apple
/// Intelligence** du moteur de macOS — celle qui écrit là où elle existe, et
/// qui assure alors l'aperçu en direct sous la barre d'enregistrement. Il n'y
/// a donc pas de choix à proposer, mais un prérequis à satisfaire — et à
/// satisfaire **avant** le premier essai, pas pendant.
///
/// C'est aussi une **mesure** : tant que le modèle de la langue n'est pas
/// `.ready`, Apple Intelligence n'est pas retenue pour écrire, et la Dictée
/// écrit à sa place quand elle le peut (cf. `EngineSafetyManager`). Sans
/// quoi la dictée commençait par télécharger le modèle, et échouait hors
/// ligne.
///
/// La version **Dictée** n'a rien à voir avec ce fichier : ses modèles sont
/// ceux que Réglages Système › Clavier › Dictée installe, et Caspr ne fait
/// que constater leur présence.
///
/// ## Par langue, et pas globalement
///
/// La première version ne connaissait qu'un état d'ensemble, ce qui ne tenait
/// pas : les actifs sont fournis par locale. Quelqu'un qui a le français
/// installé et bascule sur l'anglais retombe exactement dans le cas de la
/// machine vierge, sans que rien ne le prépare. L'état est donc suivi langue
/// par langue, et la bascule sait ce qu'elle coûte.
///
/// ## Ne pas mesurer ce qui n'a pas commencé
///
/// Le téléchargement échouait sur « Cannot check the download status,
/// fr.lyriastudio.caspr is not subscribed to transcription.fr ». Deux
/// hypothèses ont été tentées à l'aveugle avant qu'on lise l'évidence : la
/// phrase décrit exactement ce que faisait la barre de progression, et
/// l'erreur est apparue au commit qui l'a introduite. Interroger l'avancement
/// d'une requête que le système n'a pas encore acceptée le fait répondre que
/// l'application n'est pas souscrite — et cette réponse remontait comme
/// l'échec du téléchargement lui-même.
///
/// La leçon vaut d'être écrite : le message nommait la cause depuis le début,
/// et deux corrections ont été livrées avant qu'on le prenne au mot.
@MainActor
@Observable
final class SpeechAssets {
    static let shared = SpeechAssets()

    enum State: Equatable {
        case unknown
        case checking
        /// Absent, et récupérable.
        case missing
        /// Fraction téléchargée, quand le système la rapporte.
        case installing(Double)
        case ready
        /// Le système ne propose pas cette langue ici.
        case unsupported(String)
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    /// Un état par code de langue — « fr », « en ».
    private(set) var states: [String: State] = [:]

    func state(of language: String) -> State { states[language] ?? .unknown }

    /// Rien ne bloque : la langue est prête, ou le système ne la propose pas
    /// et rien ne la rendra disponible.
    func isSettled(_ language: String) -> Bool {
        switch state(of: language) {
        case .ready, .unsupported: true
        default: false
        }
    }

    // MARK: - Vérifier

    /// Interroge le système sur ces langues, en tâche de fond.
    ///
    /// Au lancement pour toutes les langues déclarées, et à chaque changement
    /// de langue principale pour la nouvelle. Sans ça, la prise en charge
    /// d'une langue n'est connue qu'après avoir ouvert l'écran qui la montre,
    /// et la toute première dictée se ferait sur un « on ne sait pas encore »
    /// — c'est-à-dire sans repli vers la Dictée quand Apple Intelligence ne
    /// sait pas l'écrire.
    func probe(_ languages: [String]) {
        Task {
            for language in languages { await check(language) }
        }
    }

    /// Où en est cette langue, sans rien télécharger.
    func check(_ language: String) async {
        guard #available(macOS 26.0, *) else {
            Language.recordAppleSupport(language, supported: false)
            states[language] = .unsupported("Le moteur intégré demande macOS 26.")
            return
        }
        if case .installing = state(of: language) { return }
        // `.checking` seulement quand on ne savait rien. Revérifier une langue
        // connue — chaque ouverture de la carte le fait — ne doit pas oublier
        // ce qu'on sait le temps de la réponse : c'est sur `.ready` que
        // `EngineSafetyManager` choisit la version qui écrit, et l'effacer
        // faisait passer la carte, et une dictée lancée à cet instant, à la
        // Dictée pour une fraction de seconde.
        if case .unknown = state(of: language) { states[language] = .checking }

        guard let locale = await Self.locale(for: language) else {
            Language.recordAppleSupport(language, supported: false)
            states[language] = .unsupported(
                "Apple Intelligence ne propose pas cette langue sur ce Mac.")
            return
        }
        Language.recordAppleSupport(language, supported: true)
        let installed = await SpeechTranscriber.installedLocales
        states[language] = installed.contains { $0.identifier == locale.identifier }
            ? .ready : .missing
    }

    /// Récupère le modèle de cette langue.
    ///
    /// ## L'ordre, et pourquoi il a changé deux fois
    ///
    /// Devant l'erreur « is not subscribed to transcription.fr », j'ai supposé
    /// qu'il fallait réserver la langue avant d'interroger ses actifs. C'était
    /// une conjecture, et elle était fausse : l'erreur persiste à l'identique.
    ///
    /// L'ordre retenu est maintenant celui de la documentation d'Apple —
    /// vérifier ce qui est installé, demander l'installation, et seulement
    /// ensuite réserver. La réservation sert à *garder* une langue disponible,
    /// elle n'est pas un préalable au téléchargement, et son échec n'empêche
    /// rien : elle est donc tentée sans conditionner la suite.
    ///
    /// Chaque étape est journalisée avec son résultat. Deux hypothèses ont
    /// déjà été essayées à l'aveugle ; la troisième attendra de savoir.
    func install(_ language: String) async {
        guard #available(macOS 26.0, *) else { return }
        if case .installing = state(of: language) { return }

        guard let locale = await Self.locale(for: language) else {
            let supported = await SpeechTranscriber.supportedLocales
            Log.error("assets: \(language) non supportée — le système propose "
                      + supported.map(\.identifier).joined(separator: ", "))
            states[language] = .unsupported("macOS ne reconnaît pas cette langue.")
            return
        }

        let installed = await SpeechTranscriber.installedLocales
        Log.info("assets: \(locale.identifier) — installées : "
                 + (installed.map(\.identifier).joined(separator: ", ")
                    .isEmpty ? "aucune" : installed.map(\.identifier).joined(separator: ", ")))
        if installed.contains(where: { $0.identifier == locale.identifier }) {
            states[language] = .ready
            await reserveQuietly(locale)
            return
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])
        states[language] = .installing(0)
        do {
            guard let request = try await AssetInventory
                .assetInstallationRequest(supporting: [transcriber]) else {
                Log.info("assets: \(locale.identifier) — rien à installer")
                states[language] = .ready
                await reserveQuietly(locale)
                return
            }

            // Pas de guetteur sur `request.progress`, et c'est lui le coupable.
            //
            // L'erreur dit mot pour mot ce que ce guetteur faisait : « Cannot
            // check the download **status** ». Elle est apparue avec lui — le
            // même commit — et pas avant. Lire l'avancement d'une requête que
            // le système n'a pas encore acceptée le fait répondre que
            // l'application n'est pas souscrite à l'actif, et cette réponse
            // remonte comme l'échec de toute l'opération.
            //
            // Une barre qui avance valait mieux qu'un tourniquet ; elle ne vaut
            // pas de casser le téléchargement qu'elle prétend mesurer.
            Log.info("assets: téléchargement de \(locale.identifier)…")
            try await request.downloadAndInstall()
            Log.info("assets: \(locale.identifier) installé")
            states[language] = .ready
            await reserveQuietly(locale)
        } catch {
            // Un système qui ne propose **aucune** langue ne pourra jamais
            // fournir ce modèle : ce n'est pas un échec dont on se relève en
            // réessayant, c'est une machine où ce moteur n'existe pas. Le
            // classer en échec bloquait « Continuer » et enfermait dans une
            // page dont rien ne sortait — alors que la Dictée de macOS, elle,
            // n'a besoin de rien de tout ça.
            if await SpeechTranscriber.supportedLocales.isEmpty {
                Log.error("assets: le système ne propose aucune langue — "
                          + "moteur macOS indisponible sur cette machine")
                // Ce qui est établi, et rien de plus. `SpeechTranscriber` ne
                // fonctionne pas sous virtualisation : `supportedLocales` y
                // rend une liste vide et `isAvailable` répond faux. C'est une
                // limite de la virtualisation elle-même, rapportée par
                // d'autres développeurs et vérifiable — pas un réglage manqué,
                // pas Siri, pas un compte Apple. Rien de ce que l'utilisateur
                // pourrait faire n'y changerait quoi que ce soit, et le lui
                // suggérer l'enverrait chercher pendant une heure.
                states[language] = .unsupported(
                    "macOS ne propose aucune langue de reconnaissance sur "
                    + "cette machine. C'est le cas des machines virtuelles et "
                    + "des simulateurs, où ce moteur n'est pas disponible — "
                    + "il n'y a rien à activer pour l'obtenir. Sur un Mac "
                    + "ordinaire il fonctionne. La Dictée de macOS, elle, ne "
                    + "dépend pas de ce moteur et peut marcher ici.")
                return
            }

            // Le diagnostic va à l'écran, pas seulement au journal : ces
            // essais ont lieu dans une machine virtuelle où lire la Console
            // suppose de retaper une commande à la main — ce qui a déjà coûté
            // un aller-retour pour une apostrophe.
            let supported = await SpeechTranscriber.supportedLocales
                .map(\.identifier).joined(separator: ", ")
            let present = await SpeechTranscriber.installedLocales
                .map(\.identifier).joined(separator: ", ")
            Log.error("assets: échec sur \(locale.identifier) — \(error)")
            states[language] = .failed("""
                \(error.localizedDescription)

                Proposées par le système : \(supported.isEmpty ? "aucune" : supported)
                Déjà installées : \(present.isEmpty ? "aucune" : present)
                """)
        }
    }

    /// Réserve la langue sans en faire dépendre quoi que ce soit.
    ///
    /// Elle garde la langue disponible pour l'application ; son échec ne rend
    /// pas le modèle inutilisable, et le faire remonter transformerait un
    /// détail en panne.
    @available(macOS 26.0, *)
    private func reserveQuietly(_ locale: Locale) async {
        do { try await LivePreview.reserve(locale) } catch {
            Log.error("assets: réservation de \(locale.identifier) — \(error)")
        }
    }

    /// Vérifie, puis télécharge si besoin. Ce que fait l'accueil.
    func ensure(_ language: String) async {
        await check(language)
        if case .missing = state(of: language) { await install(language) }
    }

    /// La locale d'Apple Intelligence correspondant à cette langue, **si elle
    /// figure dans celles qu'il prend en charge**.
    ///
    /// ## Pourquoi pas `supportedLocale(equivalentTo:)`
    ///
    /// Son nom laisse croire à un test d'appartenance. Ce n'en est pas un :
    /// mesuré sur cette machine, il rend `pl_PL`, `ru_RU`, `ar_SA` et `vi_VN`
    /// alors qu'aucune des quatre n'est dans `supportedLocales`. Il normalise
    /// un identifiant, il ne vérifie rien. S'y fier faisait déclarer toutes les
    /// langues prises en charge, donc proposer le téléchargement d'un modèle
    /// qui n'existe pas — le bouton ne pouvait qu'échouer.
    ///
    /// L'appartenance se teste donc sur `supportedLocales`, la liste elle-même.
    /// La comparaison passe par une forme normalisée parce qu'Apple rend
    /// `fr_FR` là où le catalogue écrit `fr-FR`.
    private static func locale(for language: String) async -> Locale? {
        guard #available(macOS 26.0, *) else { return nil }
        let wanted = normalised(language)
        return await SpeechTranscriber.supportedLocales.first {
            normalised($0.identifier) == wanted
        }
    }

    private static func normalised(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
