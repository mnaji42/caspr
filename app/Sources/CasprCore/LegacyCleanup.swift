//  Ce que Caspr ne sait plus faire, et qu'il doit quand même reprendre.
//
//  La refonte de septembre 2026 ne garde que deux voies : macOS et ChatGPT.
//  CrisperWhisper, son démon, le corpus, le lexique et les modes disparaissent
//  du code. Mais pas du disque des gens qui les ont utilisés — et une fois le
//  code parti, plus rien ne saurait où ils se trouvent. Ce fichier est cette
//  mémoire-là, écrite pendant que le code qui les déposait existe encore pour
//  la relire.
//
//  Dans CasprCore pour deux raisons. Les règles qui décident de ce qui part
//  sont celles qu'on ne peut pas se permettre de rater : un chemin de trop dans
//  une migration automatique, et c'est le code source d'un développeur qui
//  part à la corbeille sans qu'il ait rien demandé. Elles méritent des tests,
//  et seule cette cible en a. Et elles ne doivent dépendre d'**aucun** type
//  que la refonte retire ensuite : tout y est écrit en chaînes et en chemins,
//  jamais en `EngineChoice.crisperWhisper` ni en `CrisperWhisperModel`, pour
//  que la migration compile encore le jour où ces types n'existent plus.

import Foundation

public enum LegacyCleanup {

    // MARK: - Réglages

    /// Les clés de l'accueil, telles qu'elles sont rangées sur le disque.
    public enum Key {
        /// L'étape d'accueil atteinte, rangée par son **rang** jusqu'ici.
        public static let legacyOnboardingStep = "caspr.onboarding.step"
        /// La même, rangée par son **nom**.
        public static let onboardingScreen = "caspr.onboarding.screen"
    }

    /// Les écrans de l'accueil, dans l'ordre où l'ancienne clé les numérotait.
    ///
    /// Figé, et c'est tout son objet : c'est la table de lecture des index
    /// écrits par les versions d'avant, pas l'ordre de l'accueil d'aujourd'hui.
    /// Le jour où l'accueil perd un écran, un index relu tel quel rouvrirait
    /// sur la page suivante — l'écran de fin, peut-être, pour quelqu'un qui
    /// n'a jamais accordé le micro. Les noms sont ceux de `Step.name` dans
    /// `Onboarding.swift`, y compris ceux d'écrans disparus depuis : c'est
    /// l'accueil qui sait où reprendre quand l'un d'eux ne désigne plus rien.
    public static let legacyOnboardingScreens = [
        "welcome", "preferences", "liveEngine", "finalEngine", "completion",
    ]

    /// Les réglages qui ne règlent plus rien.
    ///
    /// Lexique, collecte, mode par défaut, moteur local — et le choix de la
    /// version de macOS, qui se fait désormais tout seul selon ce que la
    /// machine sait écrire dans la langue. **Jamais** une clé `relais.*`, le
    /// raccourci, les langues, l'historique, la destination ou le fichier de
    /// notes : ce sont eux que l'utilisateur retrouverait vides à la mise à
    /// jour, et le calibrage du relais ne se refait pas en un clic. Jamais non
    /// plus `caspr.engine.appleSupport` : ce n'est pas un choix, c'est ce que
    /// le système a répondu sur les langues d'Apple Intelligence, et le
    /// reperdre ferait dicter la première phrase sur un « on ne sait pas ».
    public static let obsoleteKeys = [
        "caspr.lexicon",
        "caspr.lexicon.useDefault",
        "caspr.corpus.enabled",
        "caspr.corpus.audio",
        "caspr.corpus.engines",
        "caspr.mode",
        "caspr.crisper.licence",
        "caspr.crisper.model.chosen",
        // Les habitudes déclarées à l'accueil ne servaient qu'à recommander
        // CrisperWhisper ou macOS : sans l'un des deux, plus rien à conseiller.
        "caspr.habits",
        // Le moteur : la famille (macOS ou CrisperWhisper), la version de la
        // passe finale, celle de l'aperçu, le dernier moteur qui avait écrit
        // et le réglage unique d'avant leur séparation. Un CrisperWhisper
        // encore inscrit n'a plus rien à traduire : il n'y a plus de version
        // à choisir à sa place.
        "caspr.engine.final",
        "caspr.engine.apple",
        "caspr.engine.live",
        "caspr.engine.lastValid",
        "caspr.engine",
        // La marque qui retenait l'effacement de `caspr.engine` tant que la
        // version courante n'avait pas relu l'installation.
        "caspr.schema.migrated",
        // Le côté de la touche Option, qui n'est plus un réglage depuis que
        // seule la droite est écoutée : plus rien ne la relit.
        "caspr.trigger.side",
    ]

    /// Efface les réglages qui n'ont plus d'objet, et range l'étape d'accueil
    /// sous son nom.
    ///
    /// Idempotente : un second passage ne trouve plus rien et ne rend rien.
    ///
    /// - Returns: ce qui a été fait, une ligne par geste, pour le journal.
    @discardableResult
    public static func migrateSettings(_ defaults: UserDefaults) -> [String] {
        var done: [String] = []

        // L'étape d'accueil change de clé en même temps que de forme : un
        // index traduit une fois pour toutes en nom, avant que l'accueil ne
        // la relise. Un index hors de la table ne désigne rien de connu, et
        // l'on repart de la bienvenue plutôt que d'un écran au hasard.
        if let stored = defaults.object(forKey: Key.legacyOnboardingStep) {
            if let index = stored as? Int,
               defaults.object(forKey: Key.onboardingScreen) == nil,
               legacyOnboardingScreens.indices.contains(index) {
                let screen = legacyOnboardingScreens[index]
                defaults.set(screen, forKey: Key.onboardingScreen)
                done.append("étape d'accueil : \(index) → \(screen)")
            }
            defaults.removeObject(forKey: Key.legacyOnboardingStep)
            done.append("réglage effacé : \(Key.legacyOnboardingStep)")
        }

        for key in obsoleteKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            done.append("réglage effacé : \(key)")
        }
        return done
    }

    // MARK: - Le démon

    /// Les agents launchd du moteur local, sous ses deux noms.
    ///
    /// Le premier est la priorité de toute la migration : il porte `RunAtLoad`
    /// et `KeepAlive`, il pointe **hors du bundle**, et il relancerait trois
    /// gigaoctets de Python à chaque ouverture de session longtemps après que
    /// plus aucun code de Caspr ne sache l'arrêter. Le second est celui que le
    /// renommage retirait ; il est repris ici pour survivre au renommage.
    public static let agentLabels = [
        "fr.lyriastudio.caspr.engine",
        "fr.lyriastudio.sofler.engine",
    ]

    public static func agentPlist(_ label: String, home: URL) -> URL {
        home.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    // MARK: - Les fichiers

    /// Un emplacement à mettre à la corbeille, avec de quoi le nommer.
    public struct Location: Sendable, Equatable {
        public let url: URL
        public let label: String

        public init(_ url: URL, _ label: String) {
            self.url = url
            self.label = label
        }
    }

    public static func supportDirectory(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Caspr")
    }

    /// Le descripteur que l'installation du moteur laissait : il dit où vit
    /// l'environnement Python.
    public static func engineDescriptor(home: URL) -> URL {
        supportDirectory(home: home).appending(path: "engine.json")
    }

    /// Le dossier du projet Python, lu dans le descripteur.
    ///
    /// Lu à la main plutôt qu'avec `EngineInstall.Descriptor` : ce type décode
    /// un `CrisperWhisperModel`, qui disparaît avec le reste.
    public static func engineProject(descriptor data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["project"] as? String
    }

    /// Ce que l'installation du moteur a déposé, et qui appartient à Caspr.
    ///
    /// La distinction qui compte est celle de `Uninstall.enginePaths`, et
    /// pour la même raison : se tromper d'emplacement ne produit pas une
    /// erreur, ça jette le dossier de quelqu'un d'autre. Mais la migration va
    /// un cran plus loin dans la prudence, parce que personne ne l'a demandée :
    ///
    /// - le dossier du moteur dans « Application Support » et l'outil `uv` que
    ///   Caspr y a récupéré partent toujours — ils n'appartiennent qu'à lui ;
    /// - le dépôt cloné par l'ancienne commande d'installation ne part que
    ///   s'il est **exactement** à `~/.caspr`, là où elle le mettait ;
    /// - un dépôt de travail de développeur n'est **pas touché du tout**, pas
    ///   même son `.venv` : c'est un arbre git, avec peut-être du travail non
    ///   commité, et une migration silencieuse n'a rien à y faire.
    ///
    /// Le `uv` de Homebrew, les Python gérés par `uv` pour d'autres projets et
    /// le Python du système ne figurent jamais ici.
    public static func engineLocations(home: URL, project: String?) -> [Location] {
        let support = supportDirectory(home: home)
        var found = [
            Location(support.appending(path: "engine"), "moteur Python"),
            Location(support.appending(path: "tools"), "outil uv de Caspr"),
        ]
        guard let project else { return found }
        // Comparé par `path`, jamais comme deux `URL` : la barre oblique finale
        // que `deletingLastPathComponent()` ajoute rend l'égalité d'URL
        // toujours fausse — cf. `Uninstall.enginePaths`, où ce piège a laissé
        // un dépôt survivre à la case qui promettait de le retirer.
        let clone = URL(fileURLWithPath: project).standardizedFileURL
            .deletingLastPathComponent()
        let canonical = home.appending(path: ".caspr").standardizedFileURL
        if clone.path == canonical.path {
            found.append(Location(canonical, "dépôt du moteur (~/.caspr)"))
        }
        return found
    }

    /// Les modèles CrisperWhisper que Caspr savait télécharger, et eux seuls.
    ///
    /// Le cache Hugging Face est partagé : Voxtral, Whisper ou n'importe quel
    /// modèle qu'un autre projet y range n'appartient pas à Caspr. La liste est
    /// donc écrite en toutes lettres, variante par variante — celles que
    /// `CrisperWhisperModel` proposait — plutôt que déduite d'un préfixe qui
    /// attraperait aussi un modèle téléchargé à la main pour autre chose.
    /// Le magasin `xet`, lui aussi partagé, n'est jamais touché.
    public static let crisperWhisperVariants = ["small", "medium", "turbo", "large"]

    public static func modelLocations(home: URL) -> [Location] {
        let hub = home.appending(path: ".cache/huggingface/hub")
        return crisperWhisperVariants.flatMap { variant -> [Location] in
            let name = "models--nyralabs--CrisperWhisper2.0_\(variant)"
            return [
                Location(hub.appending(path: name), "modèle CrisperWhisper \(variant)"),
                // Le verrou du téléchargement survit au modèle : quelques
                // octets, mais c'est lui qu'un balayage du cache retrouverait.
                Location(hub.appending(path: ".locks/\(name)"),
                         "verrou du modèle CrisperWhisper \(variant)"),
            ]
        }
    }

    /// Le reste : journaux du moteur, socket, corpus, sauvegardes de réglages,
    /// et ce que l'ancien nom avait laissé.
    ///
    /// Le dossier de support n'est jamais jeté d'un bloc : l'historique des
    /// transcriptions n'y vit pas (il est dans les réglages), mais rien ne dit
    /// qu'un fichier que la refonte ne connaît pas n'y vivra pas un jour. Il ne
    /// part qu'une fois vide — cf. `isEffectivelyEmpty`.
    public static func otherLocations(home: URL) -> [Location] {
        let support = supportDirectory(home: home)
        return [
            // Rien d'autre que `engine.log` n'y a jamais été écrit.
            Location(home.appending(path: "Library/Logs/Caspr"), "journaux du moteur"),
            // Le socket du service, et rien d'autre.
            Location(home.appending(path: "Library/Caches/caspr"), "socket du moteur"),
            Location(support.appending(path: "corpus"), "corpus"),
            // Écrites par les anciennes versions de `scripts/reset-state.sh`,
            // qui exportaient les réglages ici avant de les effacer. Plus rien
            // ne les relit, et le script les range désormais hors d'ici.
            Location(support.appending(path: "backups"), "sauvegardes de réglages"),
            // Ce que le renommage laissait en place quand le nouveau dossier
            // existait déjà — il refusait de fusionner, à juste titre. Plus
            // rien ne le reprendra.
            Location(home.appending(path: "Library/Application Support/Sofler"),
                     "dossier de Sofler"),
            Location(home.appending(path: "Library/Caches/sofler"), "cache de Sofler"),
            Location(home.appending(path: "Library/Logs/Sofler"), "journaux de Sofler"),
        ]
    }

    /// Ne reste-t-il là-dedans que des miettes ?
    ///
    /// Un `.DS_Store` et des dossiers vides ne sont pas des données : les
    /// compter ferait survivre le dossier à sa propre vacuité. Un dossier
    /// illisible, lui, n'est **pas** vide — dans le doute, on le garde.
    public static func isEffectivelyEmpty(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return entries.allSatisfy { name in
            if name == ".DS_Store" { return true }
            let child = url.appending(path: name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            return isEffectivelyEmpty(child)
        }
    }
}
