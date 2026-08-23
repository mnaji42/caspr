import SwiftUI
import CasprCore

/// Le moteur de macOS : quelle version, et les modèles qu'elle réclame.
///
/// ## Deux réglages, et c'est l'utilisateur qui arbitre
///
/// Le même composant sert deux fois — sous la bascule de l'aperçu en direct, et
/// dans le panneau « macOS (Natif) » du moteur final — et chaque exemplaire
/// pilote **son** réglage, désigné par `target`. C'est ce que fait
/// `AppleEngineCard.jsx`.
///
/// J'avais tranché l'inverse, en croyant qu'un aperçu utilisant une autre
/// version que la passe finale afficherait pendant qu'on parle un texte
/// qu'aucun moteur ne produirait. C'est vrai, et ce n'est pas une incohérence :
/// ce sont deux besoins différents, et quelqu'un peut légitimement vouloir la
/// Dictée pour un aperçu léger pendant qu'il parle et Apple Intelligence pour
/// le texte définitif. Les coupler retirait ce choix sans rien garantir en
/// échange. Cf. `Preferences.liveEngineTechnology`, et le seul point de contact
/// qui subsiste, dans `setTechnology`.
///
/// ## Ce qui bloque, et ce qui n'a pas à bloquer
///
/// Le doc 02 se contredit sur ce point : §1 exige que **toutes** les langues
/// retenues aient leur modèle, §0.quater dit que seule la langue active
/// détermine si le moteur est prêt. C'est §0.quater qui a raison, et l'autre
/// lecture serait pénible : quelqu'un qui a déclaré cinq langues et téléchargé
/// celle dans laquelle il dicte peut dicter — l'en empêcher pour un modèle
/// espagnol dont il se servira dans trois semaines n'a aucune contrepartie.
///
/// Les langues secondaires manquantes sont donc **proposées, jamais exigées**.
struct AppleEngineCard: View, ValidatingComponent {
    /// Imbriqué sous une ligne de choix : la carte perd son cadre et son
    /// en-tête, qui feraient une carte dans une carte.
    var isSubCard = false

    /// Lequel des deux moteurs cette carte règle.
    ///
    /// Le même composant sert deux fois — sous la bascule de l'aperçu en direct,
    /// et dans le panneau « macOS (Natif) » du moteur final — et chaque
    /// exemplaire pilote **son** réglage. C'est le `target` de
    /// `AppleEngineCard.jsx`. Sans lui, les deux cartes écrivaient la même
    /// valeur : choisir Dictée pour l'aperçu basculait aussi la transcription,
    /// et réciproquement.
    var target: Target = .live

    enum Target { case live, final }

    /// La version réglée par cette carte-ci.
    private var technology: EngineChoice {
        target == .final ? prefs.finalAppleTechnology : prefs.liveEngineTechnology
    }

    /// La version que la carte **montre**, qui n'est pas toujours celle qui est
    /// enregistrée.
    ///
    /// Quand la machine n'en propose qu'une, c'est elle — le réglage, lui, peut
    /// encore désigner l'autre : il a été pris sur un Mac où les deux
    /// existaient, ou il vaut sa valeur par défaut. La carte décrivait alors
    /// Apple Intelligence sur une machine qui ne sait faire que la Dictée, et
    /// n'affichait ni le nombre de langues ni la ligne d'autorisation qui va
    /// avec — deux informations qui manquaient exactement là où elles
    /// comptaient.
    private var shownTechnology: EngineChoice {
        available.count == 1 ? (available.first ?? technology) : technology
    }

    private func setTechnology(_ choice: EngineChoice) {
        switch target {
        case .final:
            prefs.finalAppleTechnology = choice
        case .live:
            prefs.liveEngineTechnology = choice
            // Le seul point de contact qui subsiste, et il ne joue qu'une fois :
            // tant que la version de la passe finale n'a jamais été choisie,
            // régler l'aperçu la règle aussi. C'est le cas de l'accueil, où
            // l'écran 3 vient avant l'écran 4 — sans ça, prendre Dictée pour
            // l'aperçu laisserait Apple Intelligence en transcription sans que
            // personne l'ait demandé. Dès qu'elle a été choisie une fois, elle
            // ne bouge plus toute seule.
            if !prefs.finalTechnologyWasChosen {
                prefs.finalAppleTechnology = choice
            }
        }
    }

    @State private var prefs = Preferences.shared
    @State private var assets = SpeechAssets.shared
    @State private var monitor = PermissionsMonitor.shared
    @State private var installing: Set<String> = []

    // MARK: - Validité

    /// Prêt quand la **langue active** peut être transcrite.
    ///
    /// Deux conditions selon la version, et elles n'ont rien à voir : Apple
    /// Intelligence veut son modèle sur le disque, la Dictée veut le droit de
    /// reconnaissance vocale — elle se sert des actifs que macOS a déjà.
    /// `target` décide **quelle** version on juge : l'écran de l'aperçu en
    /// direct valide celle de l'aperçu, l'écran du moteur final celle de la
    /// passe finale. Les juger toutes deux sur la seconde bloquait l'écran 3
    /// de l'accueil sur l'état d'un réglage qui ne s'y règle pas.
    /// La conformité au protocole, qui juge la passe finale — la seule dont
    /// dépend ce qui sera réellement inséré.
    static func validate() -> ComponentValidationError? { validate(target: .final) }

    static func validate(target: Target) -> ComponentValidationError? {
        let prefs = Preferences.shared
        let language = prefs.primaryLanguage

        switch target == .final ? prefs.finalAppleTechnology
                                : prefs.liveEngineTechnology {
        case .apple:
            guard EngineChoice.apple.isAvailable(for: language) else {
                return .noSystemEngine(
                    LegacySpeechEngine.unavailabilityReason(for: language)
                        ?? "Le moteur Apple Intelligence n'est pas disponible ici.")
            }
            // Seulement quand le modèle manque vraiment.
            //
            // `isReady` était le critère, donc tout ce qui n'est pas `.ready`
            // valait « pas installé » — y compris `.unknown` et `.checking`,
            // qui veulent dire « on ne sait pas encore ». L'accueil affirmait
            // alors « Le modèle de Français (France) n'est pas encore
            // installé » et grisait « Continuer », pendant que la carte
            // n'offrait aucun bouton pour l'installer : elle, elle n'agit que
            // sur `.missing`. Deux lectures du même état qui se contredisent,
            // et un écran dont on ne peut pas sortir.
            //
            // Interroger les actifs du système prend un instant, et un instant
            // suffit à voir l'écran bloqué. Ne bloquer que sur ce qui appelle
            // vraiment une action : le modèle absent, ou son installation
            // échouée. Un état encore inconnu ne justifie pas d'arrêter
            // quelqu'un avec une phrase qu'on ne sait pas vraie.
            switch SpeechAssets.shared.state(of: language) {
            case .missing, .failed:
                return .missingLanguageModels([language])
            case .ready, .unknown, .checking, .installing, .unsupported:
                return nil
            }
        case .appleLegacy:
            guard EngineChoice.appleLegacy.isAvailable(for: language) else {
                return .noSystemEngine(
                    LegacySpeechEngine.unavailabilityReason(for: language)
                        ?? "La Dictée de macOS n'est pas utilisable ici.")
            }
            // Avant l'autorisation, parce que c'est le manque le plus profond
            // des deux : accorder la reconnaissance vocale sur un Mac dont la
            // Dictée est éteinte ne débloque rien, et donne l'impression
            // d'avoir tout fait — c'est exactement ce qui s'est passé sur la
            // machine où le défaut a été trouvé.
            if SystemDictation.isDisabled { return .systemDictationDisabled }
            return PermissionsMonitor.shared.speechGranted
                ? nil : .speechRecognitionPermissionRequired
        case .crisperWhisper:
            // Impossible par construction : les deux réglages de version ne
              // prennent que les deux versions de macOS. On ne bloque pas sur un état qui ne peut
            // pas exister.
            return nil
        }
    }

    var body: some View {
        Group {
            if isSubCard {
                VStack(alignment: .leading, spacing: 12) { content }
            } else {
                Card { content }
            }
        }
        // ## L'horloge est tenue ici, et pas plus bas
        //
        // La carte lit trois choses qui changent depuis les Réglages Système —
        // la reconnaissance vocale, et désormais l'interrupteur de la Dictée —
        // et elle ne les relisait jamais elle-même : elle profitait de ce que
        // `SpeechAccessRow`, affiché juste en dessous, lançait l'horloge.
        //
        // Ça ne pouvait pas tenir pour `SystemDictationRow`, qui ne rend
        // **rien** tant qu'il n'y a rien à réparer : un `.onAppear` posé sur un
        // `Group` vide n'est jamais appelé — SwiftUI n'instancie pas
        // `EmptyView` — donc la ligne n'aurait pu démarrer l'horloge que dans le
        // cas où elle était déjà visible. Éteindre la Dictée pendant que la
        // carte est ouverte n'aurait rien affiché du tout.
        //
        // Le compteur d'observateurs est un décompte : un abonné de plus ne
        // fait pas battre l'horloge deux fois.
        .onAppear { monitor.observe() }
        .onDisappear { monitor.release() }
        // Sur la carte entière, et non plus dans la branche des modèles d'Apple
        // Intelligence : ce compte sert aussi à `inconsistency`, qui ne se pose
        // que sur les machines où cette branche-là ne s'affiche jamais.
        .task { await assets.refreshLocaleCount() }
    }

    /// **Ce message ne devrait jamais paraître.**
    ///
    /// Il dit qu'un réglage désigne un moteur que cette machine ne sait faire
    /// tourner pour *aucune* langue — un état que rien, dans l'application, n'a
    /// le droit d'écrire. S'il s'affiche un jour, la faute est ailleurs dans le
    /// code, et c'est précisément pour ça qu'il existe : la panne qui l'a
    /// motivé s'est manifestée par une transcription vide et rien d'autre, et
    /// il a fallu remonter trois fichiers pour comprendre que le réglage
    /// pointait sur Apple Intelligence sur un Mac qui n'en a pas.
    ///
    /// ## La condition est étroite exprès
    ///
    /// « Le moteur réglé n'est pas disponible » ne suffit pas : c'est un état
    /// **légitime et courant**, celui de quelqu'un qui a choisi Apple
    /// Intelligence puis dicte dans une langue qu'il ne couvre pas. Le réglage
    /// n'est alors pas fautif, il ne s'applique simplement pas ici et
    /// maintenant — `LanguageSwitchCoordinator` le laisse en place à dessein et
    /// son bandeau le dit déjà. Crier à l'anomalie là-dessus ferait de ce
    /// message un bruit de fond, et le jour où il dirait vrai plus personne ne
    /// le lirait.
    ///
    /// On exige donc que la machine soit incapable de faire tourner ce moteur
    /// **du tout** : zéro locale proposée, mesuré auprès du système. C'est la
    /// différence entre « pas dans cette langue » et « pas sur ce Mac ».
    private var inconsistency: EngineChoice? {
        guard !available.isEmpty, !available.contains(technology) else { return nil }
        // Seul Apple Intelligence peut se retrouver dans cet état par un défaut
        // de Caspr. Une Dictée indisponible, elle, a toujours une cause visible
        // côté système — l'interrupteur éteint — et `SystemDictationRow` la
        // porte déjà.
        guard technology == .apple, assets.appleLocaleCount == 0 else { return nil }
        return available.first
    }

    @ViewBuilder
    private func inconsistencyNotice(_ fix: EngineChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Note("**Réglage incohérent — c'est un défaut de Caspr, pas une "
                 + "manipulation de votre part.** "
                 + (target == .final ? "Ce moteur" : "Cet aperçu")
                 + " est réglé sur \(technology.fullLabel), que ce Mac ne sait "
                 + "faire tourner pour aucune langue. Rien n'est bloqué : la "
                 + "dictée se replie sur \(fix.fullLabel). Mais ce réglage "
                 + "n'aurait pas dû pouvoir s'écrire ici.", warning: true)
            ButtonRow {
                Button("Régler sur \(fix.fullLabel)") { setTechnology(fix) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Style.innerRadius, style: .continuous)
                .fill(Style.warning.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: Style.innerRadius,
                                          style: .continuous)
                    .strokeBorder(Style.warning.opacity(0.35), lineWidth: 1)))
    }

    @ViewBuilder
    private var content: some View {
        // En tête, avant tout le reste : si ce filet se déclenche, plus rien
        // sur la carte ne mérite d'être lu avant lui.
        if let fix = inconsistency {
            inconsistencyNotice(fix)
        }

        // Hors sous-carte, la carte porte son propre en-tête : une pastille qui
        // dit si le moteur est opérationnel, le nom de la version active, et ce
        // qu'elle est. En sous-carte, la ligne de choix parente le dit déjà.
        if !isSubCard {
            HStack(alignment: .top, spacing: 12) {
                statusCircle
                VStack(alignment: .leading, spacing: 3) {
                    Text(headerTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(headerDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(Style.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        versionPicker

        switch shownTechnology {
        case .appleLegacy:
            // Avant l'autorisation : elle ne sert à rien tant que celui-ci
            // n'est pas levé, et le laisser en second faisait accorder un droit
            // pour rien.
            SystemDictationRow()
            SpeechAccessRow(explains: !isSubCard)
        default:
            models
        }
    }

    /// La pastille d'état : pleine et cochée quand le moteur peut écrire,
    /// cerclée sinon. `.status-circle` du prototype.
    @ViewBuilder
    private var statusCircle: some View {
        if Self.isValid {
            ZStack {
                Circle().fill(Style.accent).frame(width: 18, height: 18)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Style.onAccent)
            }
        } else {
            Circle()
                .strokeBorder(Style.textTertiary, lineWidth: 1.5)
                .frame(width: 18, height: 18)
        }
    }

    private var headerTitle: String {
        let version = shownTechnology
        return "macOS · \(version.versionLabel ?? version.label)"
    }

    private var headerDetail: String {
        shownTechnology == .apple
            ? "Fourni par macOS 26+ (SpeechTranscriber) : modèles neuronaux sur "
                + "puce Apple. Zéro donnée envoyée au cloud, 0 Mo de RAM résidente."
            : "Fourni par macOS (SFSpeechRecognizer) : prêt immédiatement, "
                + "aucune licence ni téléchargement requis."
    }

    // MARK: - La version

    /// Ce que cette machine sait faire, mesuré, dans la langue active.
    private var available: [EngineChoice] {
        EngineChoice.availableSystemEngines(for: prefs.primaryLanguage)
    }

    /// **La même carte dans les deux cas**, à la rangée de choix près.
    ///
    /// Une seule version disponible produisait auparavant une mise en page à
    /// part : pas d'intitulé « VERSION DU MOTEUR », pas de nombre de langues, et
    /// à la place une ligne « macOS · Dictée — seule version ici » qui répétait
    /// le titre de la carte deux centimètres plus bas. Ça se lisait comme un
    /// écran inachevé, et la seule chose qu'on y gagnait — savoir qu'il n'y a
    /// pas de choix — est déjà dite par l'absence du sélecteur.
    ///
    /// Ce qui disparaît, c'est donc **la rangée « Technologie » et elle seule**.
    /// Le reste est identique, et la version montrée est traitée exactement
    /// comme si elle avait été choisie. Aucune version disponible reste un cas
    /// à part : la raison mesurée, et le bouton qui y mène.
    @ViewBuilder
    private var versionPicker: some View {
        if !available.isEmpty {
            if !isSubCard {
                Divider().opacity(0.25)
            }
            Text("VERSION DU MOTEUR")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Style.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if available.count > 1 {
                Row(label: "Technologie :") {
                    PillPicker(options: available.map { ($0, $0.versionLabel ?? $0.label) },
                               selection: Binding(
                                   get: { technology },
                                   set: { setTechnology($0) }))
                }
            }
            languageCoverage

            if let explanation = shownTechnology.versionExplanation {
                Note(explanation)
            }
        } else {
            Note(LegacySpeechEngine.unavailabilityReason(for: prefs.primaryLanguage)
                 ?? "Aucune version du moteur de macOS n'est utilisable ici.",
                 warning: true)
            ButtonRow {
                Button("Ouvrir Réglages › Clavier") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
        }
    }

    // MARK: - Les modèles d'Apple Intelligence

    /// Les langues **téléchargeables et absentes**.
    ///
    /// C'était « toutes celles qui ne sont pas prêtes », ce qui englobait
    /// celles qu'Apple Intelligence ne propose pas : la carte offrait de
    /// télécharger un modèle qui n'existe pas, et le bouton ne pouvait
    /// qu'échouer. Une langue non proposée n'est pas en attente : elle sort
    /// simplement de la liste. Rien à annoncer tant qu'elle n'est pas la
    /// langue principale — et si elle le devient, c'est le bandeau de la carte
    /// de langue qui le dit, pas celle-ci.
    private var missing: [Language] {
        prefs.activeLanguages.filter { assets.state(of: $0.code) == .missing }
    }

    /// Celles dont le modèle est en place.
    private var ready: [Language] {
        prefs.activeLanguages.filter { assets.state(of: $0.code).isReady }
    }

    private var primaryIsReady: Bool {
        assets.state(of: prefs.primaryLanguage).isReady
    }

    private var models: some View {
        Group {
            if EngineChoice.apple.isAvailable(for: prefs.primaryLanguage) {
                if missing.isEmpty {
                    if !ready.isEmpty {
                        GrantedLine("Modèles installés (\(ready.map(\.name).joined(separator: ", ")))")
                    }
                } else if primaryIsReady {
                    // Non bloquant : la langue active est prête, on peut dicter.
                    secondaryOffer
                } else {
                    primaryNeeded
                }
            }
        }
        // Chaque langue vérifiée une fois à l'affichage, et de nouveau quand la
        // liste change. `check` ne télécharge rien : on regarde, on ne décide
        // pas à la place de quelqu'un qui n'a pas encore lu la question.
        .task(id: prefs.selectedLanguages) {
            for code in prefs.selectedLanguages {
                await assets.check(code)
            }
        }
    }

    /// La langue active manque : c'est le seul cas qui empêche de dicter.
    private var primaryNeeded: some View {
        actionBox {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Modèle de \(prefs.primary.displayName)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("macOS fournit ce modèle mais ne l'embarque pas : il "
                         + "faut aller le chercher une fois. Environ "
                         + "\(prefs.primary.estimatedSizeLabel).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                downloadButton(for: [prefs.primary], label: "Télécharger")
            }
            state(of: prefs.primaryLanguage)
        }
    }

    /// Des langues secondaires manquent. Proposé discrètement, sans encart
    /// d'alerte : rien n'est bloqué, et rien ne presse.
    private var secondaryOffer: some View {
        VStack(alignment: .leading, spacing: 6) {
            GrantedLine("Modèle de \(prefs.primary.displayName) prêt")
            HStack(alignment: .top, spacing: 8) {
                Text("\(missing.map(\.name).joined(separator: ", ")) — "
                     + "pas encore installé\(missing.count > 1 ? "s" : ""), "
                     + "environ \(totalLabel(missing)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                downloadButton(for: missing, label: "Télécharger tout",
                               prominent: false)
            }
            ForEach(missing) { language in
                state(of: language.code)
            }
        }
    }

    /// Le poids cumulé, annoncé pour ce qu'il est : une estimation.
    ///
    /// Apple n'expose la taille d'un actif ni avant ni pendant l'installation.
    /// Afficher « 123 Mo » au point près serait un chiffre qu'on serait
    /// incapable de tenir, sur une opération que les gens surveillent.
    /// Combien de langues cette version sait écrire, et si la vôtre en est.
    ///
    /// Le nombre vient du système, jamais d'une liste écrite ici : il dépend de
    /// la version de macOS et du matériel. Trois exemples suffisent à donner
    /// l'idée — en aligner soixante ferait de cette carte un catalogue.
    @ViewBuilder
    private var languageCoverage: some View {
        let covered = Language.appleSupports(prefs.primaryLanguage) != false
        if shownTechnology == .apple, let count = assets.appleLocaleCount {
            Note("**\(count) langues** sur ce Mac — français, anglais, espagnol, "
                 + "allemand, italien, portugais, japonais, coréen, chinois…"
                 + (covered ? ""
                    : " **\(prefs.primary.displayName) n'en fait pas partie** : "
                      + "la Dictée de macOS prend le relais."))
        } else if shownTechnology == .appleLegacy {
            Note("**\(LegacySpeechEngine.supportedLocaleCount) langues** sur ce "
                 + "Mac : c'est la liste de la Dictée de macOS, la plus large "
                 + "des trois.")
        }
    }

    private func totalLabel(_ languages: [Language]) -> String {
        let total = languages.reduce(Int64(0)) { $0 + $1.estimatedModelBytes }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func downloadButton(for languages: [Language], label: String,
                                prominent: Bool = true) -> some View {
        let busy = languages.contains { installing.contains($0.code) }

        return Button(busy ? "Téléchargement…" : "\(label) (~\(totalLabel(languages)))") {
            Task {
                let codes = languages.map(\.code)
                installing.formUnion(codes)
                // En série, pas en parallèle : plusieurs installations d'actifs
                // simultanées se gênent, et l'ordre garantit que la langue
                // active — toujours en tête — arrive la première.
                for code in codes { await assets.install(code) }
                installing.subtract(codes)
                // Le repli éventuel se lève dès que le modèle est là.
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? Style.accent : Color.secondary.opacity(0.35))
        .controlSize(.small)
        .disabled(busy)
    }

    /// L'état d'une langue, quand il a quelque chose à dire.
    @ViewBuilder
    private func state(of code: String) -> some View {
        switch assets.state(of: code) {
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                // Indéterminé, et c'est un correctif : observer
                // `request.progress` fait échouer le téléchargement avec
                // « is not subscribed to transcription.fr ». L'étape est donc
                // nommée à défaut d'être mesurée. Cf. `SpeechAssets`.
                Text("Téléchargement de \(Language.named(code).displayName)…")
                    .font(.system(size: 11))
            }
        case .failed(let message):
            Note(message, warning: true)
            ButtonRow {
                Button("Réessayer") { Task { await assets.install(code) } }
            }
        case .unsupported(let why):
            Note(why, warning: true)
        // `.missing` n'affiche rien ici : l'encart qui englobe cette ligne
        // porte déjà le bouton de téléchargement, et répéter « absent » à côté
        // de « Télécharger » n'ajoute rien.
        case .unknown, .checking, .missing, .ready:
            EmptyView()
        }
    }

    private func actionBox<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Style.innerRadius, style: .continuous)
                    .fill(Style.innerBoxFill)
                    .overlay(RoundedRectangle(cornerRadius: Style.innerRadius,
                                              style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)))
    }
}

#Preview("Moteur macOS") {
    ScrollView {
        AppleEngineCard()
            .padding(Style.windowPadding)
    }
    .frame(width: Style.windowWidth, height: 500)
    .background(Color(hex: 0x141821))
}
