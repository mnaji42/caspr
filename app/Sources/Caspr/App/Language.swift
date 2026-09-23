import Foundation
import Speech
import CasprCore

/// Une langue de dictée, telle qu'on la choisit.
///
/// ## Deux codes, et ils ne sont pas interchangeables
///
/// - `code` est la locale complète (`fr-FR`). C'est ce que réclament
///   `SpeechTranscriber` et `SFSpeechRecognizer` : les modèles de macOS sont
///   fournis *par région*, et `fr-CA` n'est pas `fr-FR`.
/// - `base` est le code ISO-639-1 (`fr`). Il sert à reconnaître deux régions
///   d'une même langue, et à la nommer en deux lettres sur la barre.
struct Language: Identifiable, Hashable, Sendable {
    /// Locale complète — `fr-FR`. Sert d'identité et de clé de persistance.
    let code: String
    /// Nom dans sa propre langue — « Français », « 日本語 ».
    let name: String
    /// Région, dans sa propre langue — « France », « 日本 ».
    let region: String
    let flag: String
    /// Le nom en français — « anglais », « allemand ».
    ///
    /// Le catalogue nomme chaque langue dans **sa propre** langue, ce qui est
    /// juste : c'est ainsi qu'on la reconnaît. Mais l'interface est en
    /// français, et taper « anglais » ne trouvait rien — il fallait deviner
    /// « English ». Ce nom-ci ne s'affiche pas ; il sert à chercher.
    let frenchName: String
    /// Poids **estimé** du modèle Apple Intelligence, en octets.
    ///
    /// Estimé, et il faut le dire à l'écran. Apple n'expose le poids d'un actif
    /// ni avant ni pendant son installation : `AssetInventory` ne rend qu'une
    /// requête opaque. Ces valeurs viennent de mesures ponctuelles et servent à
    /// donner un ordre de grandeur — « environ 123 Mo » — jamais à annoncer un
    /// chiffre exact qu'on serait incapable de tenir.
    let estimatedModelBytes: Int64

    var id: String { code }

    /// Le code ISO-639-1 — `fr` pour `fr-FR`.
    ///
    /// Dérivé, jamais stocké : une seule vérité par langue, et `Locale` sait
    /// déjà faire cette extraction. Le repli sur `code` ne sert que si l'on
    /// nous confie un identifiant que `Locale` ne sait pas lire.
    var base: String {
        Locale(identifier: code).language.languageCode?.identifier ?? code
    }

    /// « Français » quand la langue n'a qu'une région au catalogue,
    /// « Français (Canada) » quand elle en a plusieurs.
    ///
    /// Afficher la région partout alourdit une liste où l'immense majorité des
    /// gens ne choisit qu'une variante ; ne l'afficher nulle part rend `fr-FR`
    /// et `fr-CA` indistinguables. On ne la montre donc que là où elle tranche.
    var displayName: String {
        Self.catalog.filter { $0.base == base }.count > 1
            ? "\(name) (\(region))"
            : name
    }

    /// « 🇫🇷 Français » — pour les pastilles et les puces.
    var badge: String { "\(flag) \(name)" }

    /// « 🇫🇷 FR » — pour la barre d'enregistrement, où la place est comptée.
    var shortBadge: String { "\(flag) \(base.uppercased())" }

    /// Poids arrondi, présenté comme l'approximation qu'il est.
    /// « 62 Mo ». En français, parce que toute l'interface l'est.
    ///
    /// `ByteCountFormatter` suit la langue du **système**, pas celle de
    /// l'application : sur un Mac en anglais il écrivait « 62 MB » au milieu
    /// d'une phrase française.
    var estimatedSizeLabel: String {
        "\(estimatedModelBytes / 1_000_000) Mo"
    }
}

// MARK: - Catalogue

extension Language {
    /// Le français de France, et rien d'autre, quand il faut bien commencer
    /// quelque part.
    ///
    /// C'est le seul défaut écrit en dur du fichier. Il vaut pour la valeur
    /// initiale de `selectedLanguages` et pour le repli quand une liste
    /// deviendrait vide — jamais pour décider de ce que la machine sait faire,
    /// qui se mesure (cf. `installed(among:)`).
    static let fallback = "fr-FR"

    /// Ce que Caspr sait nommer.
    ///
    /// **Ce n'est pas la liste de ce qui marche ici.** C'est un dictionnaire de
    /// libellés : drapeaux, noms, régions, ordres de grandeur. Ce que cette
    /// machine sait réellement transcrire se demande au système, langue par
    /// langue, et se mesure à l'exécution — un Mac Intel, une machine virtuelle
    /// et un Mac Apple Silicon à jour ne répondent pas la même chose, et aucun
    /// numéro de version ne permet de le deviner.
    ///
    /// Une langue absente d'ici reste utilisable : `named(_:)` fabrique une
    /// entrée depuis `Locale` plutôt que de la faire disparaître de l'interface.
    /// Le catalogue, lu dans `languages.json`.
    ///
    /// Sorti du code pour être tenu à jour sans recompiler : ajouter une langue
    /// ou corriger un poids estimé est une modification de données, pas de
    /// programme.
    ///
    /// **Ce qui n'y figure pas, délibérément** : les locales d'Apple
    /// Intelligence et celles de la Dictée de macOS. Elles dépendent de la
    /// machine et de la version du système — 30 et 63 sur ce Mac — et une liste
    /// figée mentirait au premier utilisateur dont le Mac diffère. Elles sont
    /// demandées au système à l'exécution.
    static let catalog: [Language] = Catalogue.read()

    /// Le fichier, lu une fois. Son format est dans CasprCore
    /// (`LanguageCatalogue`), où un test décode le vrai fichier.
    enum Catalogue {
        static func read() -> [Language] {
            guard let url = Bundle.main.url(forResource: "languages",
                                            withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let doc = try? LanguageCatalogue.decode(data)
            else {
                // Un repli minimal plutôt qu'une application sans langue. Il
                // signale l'anomalie sans empêcher de dicter : c'est une erreur
                // d'empaquetage, pas une raison de refuser de démarrer.
                Log.error("languages.json introuvable ou illisible — "
                          + "catalogue réduit au français et à l'anglais")
                return [
                    Language(code: "fr-FR", name: "Français", region: "France",
                             flag: "🇫🇷", frenchName: "français",
                             estimatedModelBytes: 65_000_000),
                    Language(code: "en-US", name: "English",
                             region: "United States", flag: "🇺🇸",
                             frenchName: "anglais",
                             estimatedModelBytes: 58_000_000),
                ]
            }
            return doc.languages.map {
                Language(code: $0.code, name: $0.name, region: $0.region,
                         flag: $0.flag, frenchName: $0.frenchName,
                         estimatedModelBytes: $0.estimatedModelMegabytes * 1_000_000)
            }
        }
    }

    /// La langue de ce code, connue du catalogue ou déduite de `Locale`.
    ///
    /// Ne rend jamais `nil`, et c'est délibéré : un code inconnu du catalogue
    /// — parce que macOS en propose un que nous n'avons pas listé, ou parce
    /// qu'une préférence a été écrite par une version ultérieure — doit rester
    /// affichable. Le faire disparaître de l'interface donnerait une liste de
    /// langues d'où la langue active serait absente, et un sélecteur sans
    /// sélection.
    static func named(_ code: String) -> Language {
        if let known = catalog.first(where: { $0.code == code }) { return known }

        let locale = Locale(identifier: code)
        let display = locale.localizedString(forIdentifier: code)
            ?? locale.localizedString(forLanguageCode: code)
            ?? code
        return Language(code: code, name: display, region: "",
                        // Le globe plutôt qu'un drapeau deviné : une langue n'a
                        // pas de pays, et en choisir un est un tort qu'on fait
                        // à quelqu'un.
                        flag: "🌐", frenchName: display,
                        estimatedModelBytes: 60_000_000)
    }

    /// La locale complète à retenir pour un code, court ou déjà complet.
    ///
    /// Sert à la migration de l'ancien réglage à code court (`fr`) vers une
    /// locale (`fr-FR`), et à chaque fois qu'on reçoit un identifiant dont on
    /// ne sait pas s'il porte une région.
    ///
    /// La région de la machine passe en premier — quelqu'un qui dicte en
    /// français depuis Montréal veut `fr-CA`, et lui imposer `fr-FR` lui donne
    /// un modèle entraîné sur un autre accent. À défaut, la première entrée du
    /// catalogue pour cette langue, qui est aussi la plus répandue.
    static func preferred(for code: String) -> String {
        if catalog.contains(where: { $0.code == code }) { return code }

        let base = Locale(identifier: code).language.languageCode?.identifier ?? code
        let sameLanguage = catalog.filter { $0.base == base }
        guard !sameLanguage.isEmpty else { return code }

        if let here = Locale.current.region?.identifier,
           let local = sameLanguage.first(where: {
               Locale(identifier: $0.code).region?.identifier == here
           }) {
            return local.code
        }
        return sameLanguage[0].code
    }

    /// Filtre le catalogue sur une recherche libre.
    ///
    /// Cherche dans le nom, la région et le code : on tape « canada » aussi
    /// bien que « français » ou « fr-CA », et la casse comme les accents sont
    /// ignorés — `.caseInsensitive` seul laissait « francais » sans résultat.
    static func matching(_ query: String) -> [Language] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return catalog }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return catalog.filter {
            $0.name.range(of: needle, options: options) != nil
                || $0.frenchName.range(of: needle, options: options) != nil
                || $0.region.range(of: needle, options: options) != nil
                || $0.code.range(of: needle, options: options) != nil
        }
    }
}

// MARK: - Ce que cette machine sait faire

extension Language {
    // MARK: - Ce qu'Apple Intelligence propose, mémorisé

    private static let appleSupportLock = NSLock()
    private static let appleSupportKey = "caspr.engine.appleSupport"

    /// **Persistée**, et ce n'est pas une optimisation.
    ///
    /// En mémoire seule, elle repartait vide à chaque lancement : `appleSupports`
    /// rendait `nil` jusqu'à ce que la carte du moteur soit affichée *et* que sa
    /// vérification asynchrone aboutisse. Or `isAvailable` traite `nil` comme
    /// « pas encore infirmé », donc Apple Intelligence se déclarait disponible —
    /// sur toute machine en macOS 26, y compris celles qui n'en ont aucun
    /// modèle. Une dictée lancée avant ce premier affichage partait donc vers un
    /// moteur qui ne pouvait rien produire.
    ///
    /// Ce que sait faire une machine ne change pas d'un lancement à l'autre. La
    /// valeur est relue au démarrage suivant, et corrigée dès que le système
    /// répond autre chose.
    nonisolated(unsafe) private static var appleSupport: [String: Bool] =
        UserDefaults.standard.dictionary(forKey: appleSupportKey) as? [String: Bool] ?? [:]

    /// Apple Intelligence propose-t-il cette langue **sur cette machine** ?
    ///
    /// `nil` tant que le système n'a pas répondu pour elle.
    ///
    /// La réponse vient de `SpeechTranscriber.supportedLocale(equivalentTo:)`,
    /// qui est asynchrone, alors que `EngineChoice.isAvailable` ne l'est pas et
    /// est appelée depuis le chemin de dictée comme depuis les vues. D'où cette
    /// mémoire : le verrou est là parce qu'elle est écrite depuis l'acteur
    /// principal et lue en dehors.
    ///
    /// Sans elle, `.apple` se disait disponible pour **n'importe quelle**
    /// langue dès que la machine avait Apple Intelligence — le paramètre
    /// `language` était ignoré. Deux conséquences : aucun repli vers la Dictée
    /// quand la langue principale n'est pas prise en charge, et la carte
    /// proposait de télécharger un modèle qui n'existe pas.
    static func appleSupports(_ language: String) -> Bool? {
        appleSupportLock.lock()
        defer { appleSupportLock.unlock() }
        return appleSupport[language]
    }

    /// Consigne ce que le système vient de répondre.
    static func recordAppleSupport(_ language: String, supported: Bool) {
        appleSupportLock.lock()
        appleSupport[language] = supported
        let snapshot = appleSupport
        appleSupportLock.unlock()
        // Hors du verrou : `UserDefaults` prend le sien, et les imbriquer sur
        // un chemin appelé depuis deux acteurs ne s'impose pas.
        UserDefaults.standard.set(snapshot, forKey: appleSupportKey)
    }

    /// Les locales que la version **Apple Intelligence** propose ici.
    ///
    /// Demandé au système, jamais déduit d'un numéro de version : une machine
    /// virtuelle en macOS 26 rend une liste vide. Vide veut donc dire « ce
    /// moteur n'existe pas sur cette machine », pas « macOS est trop ancien ».
    /// Rendues avec un tiret — `fr-FR` — comme le catalogue les écrit.
    ///
    /// Apple les rend avec un tiret bas (`fr_FR`). Non normalisées, elles ne
    /// correspondaient à aucun code du catalogue : la taille du modèle ne
    /// s'affichait jamais, et aucune langue n'était marquée « indisponible
    /// ici », y compris celles qu'Apple Intelligence ne propose pas.
    static func systemSupportedLocales() async -> [String] {
        guard #available(macOS 26.0, *) else { return [] }
        return await SpeechTranscriber.supportedLocales
            .map { $0.identifier.replacingOccurrences(of: "_", with: "-") }
    }
}
