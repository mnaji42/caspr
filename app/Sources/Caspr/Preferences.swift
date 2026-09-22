import AppKit
import Observation
import CasprCore

extension Notification.Name {
    /// Le déclencheur a changé : le tap clavier doit être reconstruit.
    static let casprTriggerChanged = Notification.Name("caspr.trigger.changed")

    /// L'accessibilité vient d'être accordée, alors que l'application tourne
    /// déjà. Le tap clavier n'a pas pu être créé au lancement et rien ne le
    /// recrée de lui-même : sans ce signal, la touche Option reste morte
    /// jusqu'au prochain démarrage.
    static let casprAccessibilityGranted = Notification.Name("caspr.accessibility.granted")
}

/// Réglages persistants.
///
/// Tout passe par `UserDefaults` : ce sont quelques scalaires et une liste de
/// mots, une base de données serait disproportionnée. Aucun réglage ne quitte
/// la machine.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let lexicon = "caspr.lexicon"
        static let useDefaultLexicon = "caspr.lexicon.useDefault"
        static let triggerSide = "caspr.trigger.side"
        static let triggerEnabled = "caspr.trigger.enabled"   // hérité, migré vers triggerKind
        static let triggerKind = "caspr.trigger.kind"
        static let defaultMode = "caspr.mode"
        static let language = "caspr.language"          // hérité, migré vers languages
        static let languages = "caspr.languages.selected"
        static let primaryLanguage = "caspr.languages.primary"
        static let noteFile = "caspr.notes.file"
        static let destination = "caspr.dictation.destination"
        static let livePreview = "caspr.preview.live"
        static let engine = "caspr.engine"              // hérité, migré vers apple
        static let finalAppleTechnology = "caspr.engine.apple"
        static let liveTechnology = "caspr.engine.live"
        static let shortcut = "caspr.shortcut"
        static let onboarded = "caspr.onboarded"
        /// Le nom de l'étape, et non plus son numéro — cf. `onboardingScreen`.
        static let onboardingScreen = "caspr.onboarding.screen"
        static let updateCheck = "caspr.update.check"
        static let ignoredUpdate = "caspr.update.ignored"
        static let lastValidEngine = "caspr.engine.lastValid"
        /// Marque qu'une installation antérieure au multi-langues a été
        /// reprise. Sert à ne pas changer sous les pieds de quelqu'un des
        /// défauts qui n'ont bougé que pour les installations neuves.
        static let migratedSchema = "caspr.schema.migrated"
    }

    private let defaults = UserDefaults.standard

    // MARK: - Accueil

    /// L'accueil a-t-il été mené jusqu'au bout ?
    ///
    /// Un drapeau explicite, et non l'état des autorisations : quelqu'un peut
    /// refuser le micro en connaissance de cause, ou rester sur le moteur
    /// d'Apple sans jamais rien installer. Déduire l'accueil de ces états
    /// reviendrait à le rouvrir à chaque lancement chez ces gens-là.
    var onboarded: Bool {
        didSet { defaults.set(onboarded, forKey: Key.onboarded) }
    }

    /// L'étape d'accueil atteinte, quand il n'a pas été mené à terme.
    ///
    /// Enregistrée en continu, pas seulement à la fermeture : quelqu'un qui
    /// quitte Caspr au milieu de l'étape 3 — ce qui arrive précisément là,
    /// puisque c'est l'étape qui envoie dans les Réglages Système accorder
    /// l'accessibilité — doit revenir là où il était, et non repartir de la
    /// page de bienvenue qu'il a déjà lue.
    ///
    /// Ne veut plus rien dire une fois `onboarded` vrai, et n'est plus lue.
    ///
    /// Rangée sous son nom (« liveEngine »), pas sous son rang : l'ancienne
    /// clé `caspr.onboarding.step` tenait un index, qui aurait désigné l'écran
    /// suivant le jour où l'accueil en perd un. `LegacyCleanup` traduit
    /// l'ancien index avant la première lecture.
    var onboardingScreen: String? {
        didSet { defaults.set(onboardingScreen, forKey: Key.onboardingScreen) }
    }

    /// Caspr doit-il regarder tout seul s'il existe une version plus récente ?
    ///
    /// **Désactivé par défaut**, et c'est un choix. C'est la seule requête
    /// réseau que l'application sache faire ; tant qu'on ne l'a pas activée,
    /// Caspr ne contacte rien ni personne, et la promesse « rien ne sort de
    /// votre Mac » n'a aucune exception à énoncer. Une exception, même
    /// bénigne, oblige à la mentionner partout et fait douter du reste.
    ///
    /// Ce que la requête envoie une fois activée : un GET sur l'API publique
    /// de GitHub, donc une adresse IP et rien d'autre — aucun identifiant,
    /// aucun compteur, rien de ce qui est dicté.
    ///
    /// Le bouton « Vérifier maintenant » des Réglages, lui, marche toujours :
    /// il est déclenché par l'utilisateur, qui sait donc ce qu'il demande.
    var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Key.updateCheck) }
    }

    // MARK: - Lexique

    /// Termes privilégiés au décodage, un par ligne dans l'interface.
    ///
    /// C'est le principal levier de qualité de l'application : c'est lui qui
    /// fait sortir `useEffect` plutôt que « use effect ».
    ///
    /// Mais allonger la liste dégrade, et c'est mesuré : à 36 termes le modèle
    /// perd des virgules — « Dans Next.js j'ai envie » au lieu de « Dans
    /// Next.js, j'ai envie ». Un prompt plus long dilue le contexte. Il faut
    /// donc retirer un terme pour en ajouter un, pas empiler.
    var lexicon: [String] {
        didSet { defaults.set(lexicon, forKey: Key.lexicon) }
    }

    /// Liste envoyée au moteur.
    ///
    /// Toujours explicite désormais. Il existait une bascule « utiliser la liste
    /// intégrée » qui envoyait `nil`, laissant le service appliquer sa propre
    /// `DEFAULT_LEXICON` — dix-neuf termes de développement web que
    /// l'utilisateur ne voyait nulle part et ne pouvait pas modifier.
    ///
    /// Le prototype n'a pas cette bascule, et il a raison : un réglage qui
    /// change ce que le moteur écrit sans montrer quoi n'est pas un réglage,
    /// c'est une surprise. La migration a recopié la liste du service dans
    /// `lexicon` — les deux étaient **rigoureusement identiques**, donc rien
    /// n'a changé pour personne, sinon que la liste est enfin visible.
    var effectiveLexicon: [String]? { lexicon }

    // MARK: - Déclencheur

    /// Comment on lance une dictée. **Une seule façon à la fois.**
    ///
    /// Les deux coexistaient, et c'était incohérent : quelqu'un qui se donnait
    /// la peine de choisir ⌘K voyait la touche Option continuer de déclencher
    /// dans son dos. Choisir un déclencheur, c'est écarter l'autre.
    ///
    /// Conséquence assumée : sous « raccourci clavier », maintenir Option
    /// n'ouvre plus les réglages non plus, puisque le tap n'est pas installé.
    /// Le menu reste là pour ça.
    enum TriggerKind: String, CaseIterable, Codable, Sendable {
        /// La touche Option seule, par un tap clavier. Demande l'accessibilité.
        case option
        /// Une combinaison classique, par Carbon. N'exige aucune autorisation.
        case shortcut
    }

    /// Le déclencheur est le seul réglage qui ne peut pas être simplement lu
    /// au moment de s'en servir : le tap clavier est construit une fois, avec
    /// son côté. Il faut donc prévenir pour qu'il soit reconstruit.
    var triggerKind: TriggerKind {
        didSet {
            defaults.set(triggerKind.rawValue, forKey: Key.triggerKind)
            NotificationCenter.default.post(name: .casprTriggerChanged, object: nil)
        }
    }

    /// Raccourci clavier de dictée, personnalisable.
    ///
    /// Un raccourci global s'approprie la combinaison dans *toutes* les
    /// applications : celui qui convient dépend donc de ce que l'utilisateur
    /// fait tourner par ailleurs, et aucun défaut ne peut convenir à tout le
    /// monde.
    var dictateShortcut: HotkeyMonitor.Shortcut {
        didSet {
            defaults.set(["keyCode": Int(dictateShortcut.keyCode),
                          "modifiers": Int(dictateShortcut.modifiers),
                          "label": dictateShortcut.label], forKey: Key.shortcut)
            NotificationCenter.default.post(name: .casprTriggerChanged, object: nil)
        }
    }

    /// Le côté de la touche Option écoutée.
    ///
    /// **Toujours la droite, et ce n'est plus un réglage.** Le choix existait,
    /// et le prototype l'a retiré : la gauche est le modificateur qu'on emploie
    /// couramment pour les raccourcis tapés d'une main, si bien que l'écouter
    /// revenait à s'installer un déclencheur qui part tout seul. La ligne
    /// « Laquelle : droite / gauche » a disparu de l'interface avec elle.
    ///
    /// La propriété reste : `ModifierKeyMonitor` a besoin d'un côté pour
    /// construire son tap, et un jour peut-être d'une raison de le changer.
    /// D'ici là elle ne varie pas, ce qui permet enfin au texte d'être
    /// affirmatif sur la touche concernée.
    let triggerSide: ModifierKeyMonitor.Side = .right

    // MARK: - Transcription

    var defaultMode: TranscriptionMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Key.defaultMode) }
    }

    /// Les langues de travail, en locales complètes — `["fr-FR", "en-US"]`.
    ///
    /// **L'ordre porte du sens, et il est le seul à en porter :** l'élément
    /// d'indice 0 est la langue principale, celle avec laquelle on dicte. Le
    /// reste est ce qu'on a déclaré vouloir employer, ce qui sert à savoir
    /// quels modèles récupérer d'avance plutôt qu'au moment où l'on bascule.
    ///
    /// Ne peut jamais être vide : sans langue, aucun moteur ne sait quoi
    /// charger, et l'application n'aurait plus qu'à échouer à chaque dictée. Un
    /// appel qui la viderait est donc corrigé sur place plutôt que refusé — le
    /// code appelant n'a aucun moyen raisonnable de traiter ce refus.
    var selectedLanguages: [String] {
        didSet {
            // Dédoublonnage en conservant l'ordre : `Set` le perdrait, et
            // l'ordre *est* l'information ici.
            var seen: Set<String> = []
            let cleaned = selectedLanguages.filter { seen.insert($0).inserted }
            if cleaned.isEmpty {
                selectedLanguages = [Language.fallback]
                return
            }
            if cleaned != selectedLanguages {
                selectedLanguages = cleaned
                return
            }
            defaults.set(selectedLanguages, forKey: Key.languages)
            // Retirer la langue principale la remplace par la première qui
            // reste — la seule circonstance où l'ordre a son mot à dire. Le
            // reste du temps il ne décide de rien : ajouter, retirer ou
            // réordonner ne change pas avec quoi on dicte.
            if !selectedLanguages.contains(storedPrimaryLanguage) {
                storedPrimaryLanguage = selectedLanguages[0]
            }
        }
    }

    /// La langue principale, **rangée à part de l'ordre de la liste**.
    ///
    /// Elle se déduisait de la position 0, et l'affecter remontait la langue en
    /// tête. Les deux se voyaient : choisir l'anglais faisait permuter les
    /// pastilles sous le curseur, et la liste du gestionnaire se réordonnait à
    /// chaque bascule. L'ordre et la langue active sont deux faits distincts —
    /// *quand la langue a été ajoutée*, et *avec laquelle on dicte* — et le
    /// prototype les range d'ailleurs dans deux états séparés.
    private var storedPrimaryLanguage: String {
        didSet {
            guard storedPrimaryLanguage != oldValue else { return }
            defaults.set(storedPrimaryLanguage, forKey: Key.primaryLanguage)
            // Une langue fraîchement choisie vaut « inconnue » pour
            // l'inventaire des modèles, ce qui n'est pas « manquante » : la
            // carte de macOS ne proposerait pas de la télécharger. Le système
            // est donc interrogé tout de suite, et la carte se redessine
            // quand il répond.
            SpeechAssets.shared.probe([storedPrimaryLanguage])
        }
    }

    /// La langue avec laquelle on dicte.
    ///
    /// L'affecter ne **déplace rien** : on choisit sa langue principale parmi
    /// celles qu'on a déclarées, et les autres restent où elles étaient.
    /// Une valeur qui ne fait pas partie des langues déclarées est ignorée,
    /// et la lecture retombe sur la première déclarée — l'invariant « la
    /// principale est toujours l'une des déclarées » tient donc même si les
    /// réglages sur disque ont été édités à la main.
    var primaryLanguage: String {
        get {
            selectedLanguages.contains(storedPrimaryLanguage)
                ? storedPrimaryLanguage
                : (selectedLanguages.first ?? Language.fallback)
        }
        set {
            guard selectedLanguages.contains(newValue) else { return }
            storedPrimaryLanguage = newValue
        }
    }

    /// Les langues déclarées, en plus de la principale — dans leur ordre.
    var secondaryLanguages: [String] {
        selectedLanguages.filter { $0 != primaryLanguage }
    }

    /// Le catalogue restreint à ce que l'utilisateur a retenu, dans son ordre.
    var activeLanguages: [Language] { selectedLanguages.map(Language.named) }

    /// La langue principale, comme objet.
    var primary: Language { Language.named(primaryLanguage) }

    /// Nom historique de la langue principale.
    ///
    /// Conservé parce que tout ce qui transcrit le lit — moteurs, aperçu — et
    /// que ces appels ne gagneraient rien à être réécrits : « la
    /// langue » y désigne bien la langue courante. Il rend une locale complète
    /// (`fr-FR`) et non un code court (`fr`) : `SpeechTranscriber` et
    /// `SFSpeechRecognizer` ont leurs modèles par région.
    var language: String {
        get { primaryLanguage }
        set {
            // Une langue qu'on n'a pas déclarée devient déclarée, et
            // principale : c'est le sens de l'ancien réglage à choix unique,
            // et le seul qui ne surprenne pas l'appelant.
            if selectedLanguages.contains(newValue) {
                primaryLanguage = newValue
            } else {
                // Ajoutée **à la fin**, comme le fait `toggleLanguage` dans le
                // prototype : la liste garde l'ordre de déclaration. C'est le
                // choix de la principale qui la rend principale, pas sa place.
                selectedLanguages.append(newValue)
                primaryLanguage = newValue
            }
        }
    }

    /// La version de mise à jour qu'on a explicitement refusée.
    ///
    /// Refuser vaut pour **cette version-là**, pas pour la fonction. Quelqu'un
    /// qui écarte la 0.8.3 parce qu'il est en plein travail doit revoir la
    /// proposition quand la 0.8.4 paraît — sans quoi « Ignorer » deviendrait un
    /// interrupteur déguisé, et le seul moyen de revenir en arrière serait de
    /// deviner qu'il existe.
    var ignoredUpdateVersion: String? {
        didSet { defaults.set(ignoredUpdateVersion, forKey: Key.ignoredUpdate) }
    }

    /// Le moteur retenu au tout premier lancement.
    ///
    /// Choisi sur ce que la machine sait faire, pas sur son numéro de version.
    /// `.apple` était écrit en dur, ce qui donnait un défaut inutilisable sur
    /// un Mac Intel, sur un macOS antérieur à 26, ou sur toute machine sans
    /// Apple Intelligence : l'application s'ouvrait sur un moteur incapable
    /// d'écrire une ligne, et rien ne disait pourquoi.
    ///
    /// L'ordre suit la qualité attendue puis la disponibilité : le moteur de
    /// macOS 26 s'il est là, celui de la Dictée sinon.
    ///
    /// Quand aucune version de macOS ne marche ici, on retient quand même la
    /// famille : l'interface montre alors la ligne « macOS » avec la raison
    /// mesurée et le bouton qui y mène, ce qui vaut mieux que de désigner un
    /// moteur que rien n'explique.
    static func defaultEngine(for language: String) -> EngineChoice {
        EngineChoice.systemEngine(preferring: .apple, for: language) ?? .apple
    }

    // MARK: - Notes

    /// Fichier des notes, retenu **indépendamment** de la destination courante.
    ///
    /// Revenir au curseur ne doit pas l'oublier : on alterne entre les deux en
    /// pleine dictée, et redemander le fichier à chaque retour ouvrirait un
    /// sélecteur — qui activerait Caspr et déplacerait le curseur, exactement
    /// ce que l'overlay `nonactivatingPanel` s'applique à éviter.
    ///
    /// Un chemin suffit : l'application n'est pas en bac à sable, donc pas de
    /// signet à conserver pour retrouver le droit d'écrire.
    var noteFile: URL? {
        didSet { defaults.set(noteFile?.path, forKey: Key.noteFile) }
    }

    /// Où va le texte : au curseur, ou dans le fichier de notes.
    ///
    /// Persistée, alors qu'elle ne l'était pas : la destination était remise au
    /// curseur à chaque lancement. Quelqu'un qui travaille au fichier de notes
    /// des journées entières devait donc y revenir après chaque redémarrage,
    /// sans que rien ne le lui rappelle — et le découvrait en constatant que sa
    /// dictée s'était écrite dans la fenêtre de devant.
    ///
    /// La contrepartie est réelle et assumée : au lancement suivant, le texte
    /// peut partir ailleurs que là où l'on regarde. C'est pourquoi le menu de
    /// la barre porte en permanence la ligne « ▸ Écrit dans … » tant que la
    /// destination est un fichier.
    enum Destination: String, CaseIterable, Codable, Sendable {
        case caret, notes
    }

    var destination: Destination {
        didSet { defaults.set(destination.rawValue, forKey: Key.destination) }
    }

    /// La destination effective, une fois vérifié qu'elle est tenable.
    ///
    /// « Notes » sans fichier mémorisé n'est pas une destination : c'est un
    /// réglage qui n'a pas fini d'être posé. On retombe au curseur plutôt que
    /// de perdre la dictée.
    var effectiveTarget: DictationTarget {
        guard destination == .notes, let noteFile else { return .caret }
        return .file(noteFile)
    }

    /// Aperçu en direct pendant la dictée, par le moteur système.
    ///
    /// Réglable depuis la barre elle-même : c'est là qu'on s'aperçoit qu'il
    /// gêne, pas dans une fenêtre de réglages.
    var livePreviewEnabled: Bool {
        didSet { defaults.set(livePreviewEnabled, forKey: Key.livePreview) }
    }

    // MARK: - Moteur

    /// La version de macOS qui écrit le texte définitif — Apple Intelligence
    /// ou Dictée.
    ///
    /// Il y avait au-dessus d'elle un second réglage, la famille : macOS ou
    /// l'ancien moteur local. Parti avec lui, il ne reste que celui-ci ;
    /// l'ancienne clé `caspr.engine.final` n'est plus lue.
    var finalAppleTechnology: EngineChoice {
        didSet {
            defaults.set(finalAppleTechnology.rawValue, forKey: Key.finalAppleTechnology)
        }
    }

    /// La version de macOS qui alimente l'aperçu en direct.
    ///
    /// **Indépendante de celle de la passe finale.** Elle était couplée : régler
    /// l'aperçu sur Dictée réglait aussi la transcription sur Dictée, et
    /// l'inverse. L'argument était qu'un aperçu utilisant l'autre version
    /// afficherait un texte que le moteur final n'allait pas produire — mais ce
    /// sont deux besoins différents et l'utilisateur arbitre lui-même : Dictée
    /// pour un aperçu léger pendant qu'on parle, Apple Intelligence pour le
    /// texte définitif, ou l'inverse. Le prototype range d'ailleurs les deux
    /// dans deux états séparés (`liveEngineTechnology`, `finalAppleTechnology`)
    /// et `AppleEngineCard` choisit lequel piloter via son `target`.
    var liveEngineTechnology: EngineChoice {
        didSet {
            defaults.set(liveEngineTechnology.rawValue, forKey: Key.liveTechnology)
        }
    }

    /// La version de la passe finale a-t-elle déjà été choisie **explicitement** ?
    ///
    /// Sert au seul endroit où les deux réglages se parlent encore : pendant
    /// l'accueil, choisir la version de l'aperçu alors que celle de la
    /// transcription n'a jamais été touchée pose la même des deux côtés. Sans
    /// ça, quelqu'un qui prend Dictée à l'écran 3 se retrouve avec Apple
    /// Intelligence à l'écran 4 sans l'avoir demandé. Dès qu'elle est choisie
    /// une fois, elle ne bouge plus toute seule — y compris si l'on revient en
    /// arrière changer l'aperçu.
    ///
    /// Mesuré sur la présence de la clé, et non sur un drapeau de plus : les
    /// observateurs ne se déclenchent pas pendant l'initialisation, donc la
    /// valeur par défaut calculée au démarrage n'écrit rien.
    var finalTechnologyWasChosen: Bool {
        defaults.string(forKey: Key.finalAppleTechnology) != nil
    }

    /// Le moteur qui écrit.
    ///
    /// Point d'entrée historique : tout ce qui transcrit veut savoir « qui
    /// écrit », pas « quelle case est cochée où ».
    var engine: EngineChoice {
        get { finalAppleTechnology }
        set { finalAppleTechnology = newValue }
    }

    /// Le dernier moteur dont on a **constaté** qu'il savait écrire.
    ///
    /// Filet de sécurité : tant que la version choisie ne sait pas écrire ici
    /// — modèle Apple Intelligence pas encore téléchargé, Dictée éteinte —
    /// la dictée continue avec celle-ci plutôt que d'échouer. Cf.
    /// `EngineSafetyManager`.
    var lastValidEngine: EngineChoice {
        didSet { defaults.set(lastValidEngine.rawValue, forKey: Key.lastValidEngine) }
    }

    private init() {
        // Reprend-on une installation antérieure au multi-langues ?
        //
        // La question n'est pas rhétorique : des défauts ont changé pour les
        // installations neuves, et les changer sous les pieds de quelqu'un qui
        // utilise déjà Caspr modifierait ses transcriptions sans qu'il ait rien
        // touché. On ne peut pas se contenter de l'absence des nouvelles clés : une
        // installation neuve ne les a pas non plus. C'est la présence des
        // **anciennes** qui tranche.
        let isExistingInstall = defaults.object(forKey: Key.migratedSchema) == nil
            && (defaults.object(forKey: Key.onboarded) != nil
                || defaults.object(forKey: Key.language) != nil
                || defaults.object(forKey: Key.engine) != nil)
        defaults.set(true, forKey: Key.migratedSchema)

        // Liste vide pour qui découvre Caspr : la liste intégrée est du
        // vocabulaire de développement web, et un médecin ou un juriste n'a
        // rien à faire de `useEffect`. Mais elle reste en place pour qui
        // l'utilisait déjà — cf. `isExistingInstall`.
        // Migration de la bascule « liste intégrée » : ceux qui l'avaient
        // active recevaient la liste du service. On la leur écrit noir sur
        // blanc plutôt que de la leur retirer — c'est le même contenu, mot
        // pour mot, et il devient modifiable.
        let storedLexicon = defaults.stringArray(forKey: Key.lexicon)
        let usedBuiltIn = defaults.object(forKey: Key.useDefaultLexicon) as? Bool
            ?? isExistingInstall
        if let storedLexicon, !usedBuiltIn {
            lexicon = storedLexicon
        } else if usedBuiltIn {
            lexicon = storedLexicon.map { $0.isEmpty ? Self.starterLexicon : $0 }
                ?? Self.starterLexicon
        } else {
            lexicon = []
        }
        defaults.removeObject(forKey: Key.useDefaultLexicon)
        // Migration : l'ancien réglage était un simple interrupteur sur la
        // touche Option, le raccourci restant actif en parallèle. Le couper
        // voulait donc dire « je préfère le raccourci ».
        if let stored = defaults.string(forKey: Key.triggerKind) {
            triggerKind = TriggerKind(rawValue: stored) ?? .option
        } else if let legacy = defaults.object(forKey: Key.triggerEnabled) as? Bool {
            triggerKind = legacy ? .option : .shortcut
        } else {
            triggerKind = .option
        }
        defaultMode = TranscriptionMode(
            rawValue: defaults.string(forKey: Key.defaultMode) ?? "intended") ?? .intended

        // Migration des langues : le réglage était un code court unique
        // (« fr »), il devient une liste de locales complètes (« fr-FR »).
        //
        // Les modèles de macOS sont fournis *par région* : « fr » ne suffit pas
        // à désigner ce qu'il faut télécharger, et `SFSpeechRecognizer` répond
        // mieux à une locale exacte. La région retenue est celle de la machine
        // quand le catalogue la connaît — un francophone au Canada obtient
        // `fr-CA` plutôt que `fr-FR`.
        let languages: [String]
        if let stored = defaults.stringArray(forKey: Key.languages), !stored.isEmpty {
            languages = stored
        } else if let legacy = defaults.string(forKey: Key.language) {
            languages = [Language.preferred(for: legacy)]
        } else {
            languages = [Language.fallback]
        }
        selectedLanguages = languages
        // Avant, la principale était la première de la liste. Les installations
        // existantes n'ont donc pas la clé : leur `languages[0]` *est* leur
        // langue principale, et la reprendre telle quelle ne change rien pour
        // elles.
        let storedPrimary = defaults.string(forKey: Key.primaryLanguage)
        storedPrimaryLanguage = storedPrimary.flatMap { languages.contains($0) ? $0 : nil }
            ?? languages[0]
        // La langue principale sert plus bas à choisir un moteur par défaut.
        // Elle passe par une locale, et non par `selectedLanguages` : sous
        // `@Observable`, relire une propriété stockée avant que toutes le
        // soient est refusé — et le contournement serait un ordre
        // d'initialisation fragile plutôt qu'une variable de trois caractères.
        let primary = languages[0]

        // Un fichier supprimé ou renommé depuis la dernière session ne doit
        // pas rester proposé comme destination : la dictée y serait perdue.
        noteFile = defaults.string(forKey: Key.noteFile)
            .map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.isWritableFile(atPath: $0.path) ? $0 : nil }
        // Au curseur par défaut : c'est ce qu'on attend d'une dictée, et le
        // fichier de notes suppose d'en avoir désigné un.
        destination = Destination(rawValue: defaults.string(forKey: Key.destination) ?? "")
            ?? .caret
        livePreviewEnabled = defaults.object(forKey: Key.livePreview) as? Bool ?? true
        onboarded = defaults.bool(forKey: Key.onboarded)
        onboardingScreen = defaults.string(forKey: Key.onboardingScreen)
        checksForUpdates = defaults.bool(forKey: Key.updateCheck)
        if let stored = defaults.dictionary(forKey: Key.shortcut),
           let code = stored["keyCode"] as? Int,
           let modifiers = stored["modifiers"] as? Int,
           let label = stored["label"] as? String {
            dictateShortcut = HotkeyMonitor.Shortcut(
                keyCode: UInt32(code), modifiers: UInt32(modifiers),
                label: label, id: HotkeyMonitor.Shortcut.dictate.id)
        } else {
            dictateShortcut = .dictate
        }
        // La version de macOS : celle explicitement rangée, sinon celle que
        // l'ancien réglage unique (`caspr.engine`) désignait, sinon celle que
        // cette machine sait faire tourner — mesuré, jamais déduit du numéro
        // de version. La valeur de l'ancien moteur local ne se relit plus :
        // `Migration` l'a déjà traduite, et un réglage qu'elle n'aurait pas
        // encore vu retombe sur ce que la machine sait faire.
        let resolvedApple = EngineChoice(rawValue: defaults.string(forKey: Key.finalAppleTechnology) ?? "")
            ?? EngineChoice(rawValue: defaults.string(forKey: Key.engine) ?? "")
            ?? Self.defaultEngine(for: primary)
        finalAppleTechnology = resolvedApple
        liveEngineTechnology = EngineChoice(rawValue: defaults.string(forKey: Key.liveTechnology) ?? "")
            ?? Self.defaultEngine(for: primary)
        // Au premier lancement, le dernier moteur valide est celui qu'on vient
        // de retenir : rien n'a encore échoué, et démarrer sur un repli
        // arbitraire ferait dicter avec autre chose que ce qui est affiché.
        lastValidEngine = EngineChoice(rawValue: defaults.string(forKey: Key.lastValidEngine) ?? "")
            ?? resolvedApple

        ignoredUpdateVersion = defaults.string(forKey: Key.ignoredUpdate)
    }

    /// Point de départ quand l'utilisateur passe à sa propre liste : le même
    /// contenu que la liste intégrée, pour qu'il parte de quelque chose qui
    /// marche plutôt que d'une page blanche.
    static let starterLexicon = [
        "useEffect", "useState", "component", "React", "Next.js", "TypeScript",
        "hook", "props", "state",
        "refactor", "merge", "commit", "branch", "pull request",
        "endpoint", "dependencies", "async", "await",
        "chunk",
    ]
}
