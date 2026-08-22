import AppKit
import SwiftUI
import CasprCore

/// Fenêtre de réglages.
///
/// Caspr est une app d'arrière-plan sans Dock : ouvrir une fenêtre demande de
/// l'activer explicitement, sinon elle apparaît derrière tout le reste.
@MainActor
final class PreferencesWindowController {
    private var window: NSWindow?

    /// L'historique appartient au contrôleur de dictée : on le passe plutôt
    /// que d'en faire un singleton de plus, pour qu'il n'existe qu'un seul
    /// propriétaire de ces données.
    func show(history: TranscriptionHistory) {
        if let window {
            window.showCentered()
            return
        }

        let window = NSWindow.caspr(title: "Réglages de Caspr") {
            PreferencesView(history: history)
        }
        self.window = window

        window.showCentered()
    }
}

// MARK: - Fenêtre

// Interne, et non `private` : son énumération d'onglets est la cible de
// `selectSettingsTab`, que des composants d'autres fichiers empruntent pour
// renvoyer vers l'onglet qui résout ce qu'ils signalent.
struct PreferencesView: View {
    let history: TranscriptionHistory
    @State private var tab: Tab = .general

    /// Six onglets, dans l'ordre où l'on se pose les questions : *ce qui vaut
    /// pour toute l'application*, *comment on déclenche*, *avec quoi ça
    /// transcrit*, puis les trois réserves — mots, historique, corpus.
    enum Tab: String, CaseIterable {
        case general, recording, engine, lexicon, history, collection

        /// Le symbole de l'onglet.
        ///
        /// **Des SF Symbols, pas des émoji.** Le prototype en utilise, et c'est
        /// naturel dans un navigateur ; sur macOS ils détonnent : rendus en
        /// couleur pleine, à une graisse qui ne suit pas celle du texte, et
        /// différents d'une version du système à l'autre. Un symbole vectoriel
        /// prend la couleur de l'onglet — turquoise quand il est actif, gris
        /// sinon — et s'aligne sur la ligne de base du libellé.
        ///
        /// Le choix suit ce que la page *fait*, pas son titre :
        /// - `⚡` était l'éclair de la vitesse ; le Moteur IA n'a rien de
        ///   rapide, il fait tourner un réseau de neurones — d'où le cerveau.
        /// - `📦` était un colis ; la Collecte n'expédie rien, elle accumule
        ///   des mesures — d'où le graphique.
        /// - `🕒` disait l'heure ; l'Historique dit ce qui est *passé* — d'où
        ///   la flèche qui revient en arrière.
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .recording: "mic"
            case .engine: "brain"
            case .lexicon: "character.book.closed"
            case .history: "clock.arrow.circlepath"
            case .collection: "chart.bar.doc.horizontal"
            }
        }

        /// « Dictée » plutôt qu'« Enregistrement », et c'est le seul écart de
        /// libellé avec le prototype.
        ///
        /// Mesuré : à 11,5 pt, les six libellés du prototype demandent environ
        /// 532 pt pour 516 disponibles dans la fenêtre. Ça déborde de peu, mais
        /// ça déborde — et `Enregistrement` est à lui seul l'excédent.
        /// `Dictée` couvre exactement la même chose : le déclencheur, l'aperçu
        /// en direct et les sons.
        var label: String {
            switch self {
            case .general: "Général"
            case .recording: "Dictée"
            case .engine: "Moteur IA"
            case .lexicon: "Lexique"
            case .history: "Historique"
            case .collection: "Collecte"
            }
        }

        /// L'en-tête de l'onglet — titre à 18 pt, puis ce qu'on y règle.
        var header: (title: String, subtitle: String) {
            switch self {
            case .general:
                ("Réglages Généraux",
                 "Langue de travail, destination du texte transcrit et "
                    + "intégration système.")
            case .recording:
                ("Dictée & Barre flottante",
                 "Comment vous appelez Caspr, ce que la barre affiche pendant "
                    + "que vous parlez, et les sons qui l'accompagnent.")
            case .engine:
                ("Moteur IA & Transcription Finale",
                 "Choisissez le moteur neuronal qui rédige le texte définitif "
                    + "de votre dictée vocale.")
            case .lexicon:
                ("Lexique & Mots Métier",
                 "Personnalisez le dictionnaire local pour garantir "
                    + "l'orthographe exacte de vos termes clés.")
            case .history:
                ("Historique des Dictées",
                 "Retrouvez et copiez vos dernières transcriptions locales en "
                    + "un clic.")
            case .collection:
                ("Collecte & Comparatif Moteurs",
                 "Archivez localement vos enregistrements pour mesurer et "
                    + "comparer la précision de chaque IA.")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: tab.header.title,
                               subtitle: tab.header.subtitle,
                               scale: .tab)
                    switch tab {
                    case .general: GeneralTab()
                    case .recording: RecordingTab()
                    case .engine: TranscriptionSettings()
                    case .lexicon: VocabularySettings()
                    case .history: HistoryTab(history: history)
                    case .collection: CollectionTab()
                    }
                }
                // `.content-area { padding: 26px 30px 24px 30px }`. Les 30 pt
                // latéraux donnent les 520 pt de largeur utile sur lesquels
                // toutes les cartes du prototype ont été dessinées ; la barre
                // d'onglets, elle, a sa propre marge et n'est pas concernée.
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.top)
        }
        .background(WindowBackground().ignoresSafeArea())
        .tint(Style.accent)
        .environment(\.selectSettingsTab) { tab = $0 }
    }

    /// La barre segmentée du prototype : un rail sombre à coins arrondis, six
    /// boutons de largeur égale, l'actif en turquoise bordé.
    ///
    /// Elle réserve les 48 pt de la barre de titre au-dessus d'elle : la
    /// fenêtre est en `fullSizeContentView`, donc sans cette marge les onglets
    /// passeraient sous les feux tricolores.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { item in
                let active = item == tab
                // Un vrai bouton, pas un `Text` avec `onTapGesture` : celui-ci
                // n'existe ni pour le clavier ni pour VoiceOver, qui annonçait
                // « texte » sur ce qui est la navigation principale de la
                // fenêtre. Un bouton se tabule, se déclenche à l'Espace et
                // s'annonce comme sélectionné.
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11.5, weight: .medium))
                            .imageScale(.medium)
                        Text(item.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(active ? Style.accent : Style.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? Style.accent.opacity(0.12) : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 7,
                                                      style: .continuous)
                                .strokeBorder(active ? Style.accentBorder : .clear,
                                              lineWidth: 1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)))
        // Serré : le rail borde la fenêtre au lieu de flotter au milieu d'une
        // bande. `.top` ne réserve que la barre de titre, sans marge ajoutée —
        // l'écart au-dessus faisait lire les onglets comme un bloc détaché,
        // alors qu'ils appartiennent au chrome de la fenêtre.
        // Pas de marge haute ajoutée : la fenêtre est en `fullSizeContentView`,
        // mais SwiftUI réserve quand même l'encart de sécurité de la barre de
        // titre. Les 40 pt que j'ajoutais s'empilaient dessus et creusaient un
        // vide de la hauteur d'une carte au-dessus des onglets.
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(
            Color(hex: 0x0F172A).opacity(0.65)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                })
    }
}

// MARK: - Général

private struct GeneralTab: View {
    var body: some View {
        // La langue d'abord : c'est elle qui décide de ce que les moteurs
        // peuvent faire, et elle vaut pour toute l'application.
        SectionLabel("Langue Principale de Dictée", followsHeader: true)
        PrimaryLanguageSelector()

        SectionLabel("Destination des Dictées")
        DestinationCard()

        SectionLabel("Mises à jour du Logiciel")
        UpdateCard()

        SectionLabel("Démarrage & Système")
        LoginItemCard()
    }
}

// MARK: - Dictée

/// Comment on déclenche, ce qu'on entend pendant, et ce qu'on voit.
///
/// Tout ce qui touche à l'acte de dicter, par opposition à l'onglet Général,
/// qui porte ce qui vaut pour l'application entière.
private struct RecordingTab: View {
    @State private var prefs = Preferences.shared
    @State private var soundsEnabled = Feedback.soundsEnabled

    var body: some View {
        // La même vue que l'accueil, sans la zone d'essai : on ne découvre pas
        // la dictée depuis les Réglages. Les deux écrans posaient la même
        // question avec deux implémentations, et elles avaient déjà divergé.
        SectionLabel("Déclencheur & Permissions", followsHeader: true)
        TriggerCard(showTrialSandbox: false)

        SectionLabel("Aperçu du texte en direct (Live Preview)")
        SettingsToggleRow(
            title: "Afficher les mots prononcés en temps réel",
            description: "Affiche le flux sous la barre flottante pendant la "
                + "parole (0 Mo de RAM, moteur macOS).",
            // La note n'apparaît **que** désactivé : rappeler ce qu'on perd
            // quand on ne perd rien serait du bruit.
            note: prefs.livePreviewEnabled ? nil
                : "L'aperçu textuel est masqué. La barre flottante affichera "
                  + "uniquement les ondes sonores pendant la parole.",
            isOn: $prefs.livePreviewEnabled,
            bottomMargin: prefs.livePreviewEnabled ? 10 : 0)

        // Une carte **à part**, et non un panneau glissé dans la précédente :
        // c'est ce que fait `SettingsView.jsx`, et c'est plus juste. Le moteur
        // n'est pas un détail du réglage « afficher l'aperçu » — il a son
        // propre état, ses propres modèles à télécharger et sa propre pastille
        // de validité, qu'une sous-carte sans en-tête ne peut pas montrer.
        if prefs.livePreviewEnabled {
            AppleEngineCard()
        }

        SectionLabel("Retours Sonores")
        Card {
            SettingsToggleRow(
                title: "Sons de début et de fin",
                description: "Émet un bip discret pour confirmer l'ouverture et "
                    + "la fermeture de la barre d'écoute.",
                isOn: $soundsEnabled,
                isCard: false)
                .onChange(of: soundsEnabled) { _, new in Feedback.soundsEnabled = new }
        }

        SectionLabel("Micro")
        MicrophoneModeCard()
    }
}

/// Mode micro de macOS.
///
/// Il n'apparaissait que sur la barre d'enregistrement, ce qui donnait
/// l'impression d'un réglage de Caspr rangé au mauvais endroit. En réalité
/// **aucune application ne peut le changer** : c'est un réglage système,
/// commun à toutes les apps. Le dire ici évite de le chercher.
private struct MicrophoneModeCard: View {
    @State private var mode = AudioRecorder.microphoneModeLabel

    var body: some View {
        Card {
            Row(label: "Mode") {
                Text(mode).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Note("**L'isolement de la voix** retire le bruit autour de vous et "
                 + "améliore nettement la transcription en environnement "
                 + "bruyant.")
            Note("macOS ne laisse aucune application imposer ce mode : il vaut "
                 + "pour toutes à la fois, et c'est vous qui le choisissez.")
            // Pas de bouton ici, et c'est mesuré : `showSystemUserInterface`
            // n'ouvre rien tant qu'aucune capture n'est en cours. macOS ne
            // propose ce choix que pendant qu'une application utilise le
            // micro. Le bouton existait, ne faisait rien depuis les réglages,
            // et laissait croire à une panne.
            Note("Le choix ne s'offre que **pendant** qu'une application "
                 + "utilise le micro. Depuis la barre de Caspr, en pleine "
                 + "dictée, un clic sur le mode l'ouvre ; sinon, il est dans "
                 + "le Centre de contrôle, sous « Micro ».")
        }
        // Il change depuis le Centre de contrôle, sans nous prévenir.
        .onAppear { mode = AudioRecorder.microphoneModeLabel }
    }
}

/// Démarrage à l'ouverture de session.
///
/// L'état est relu à chaque affichage plutôt que mémorisé : ce réglage existe
/// aussi dans Réglages Système › Général › Ouverture, et l'utilisateur peut
/// l'y couper sans nous prévenir. Un interrupteur qui afficherait l'inverse de
/// la réalité serait pire que pas d'interrupteur du tout.
private struct LoginItemCard: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var refused = false

    var body: some View {
        Card {
            SettingsToggleRow(
                title: "Lancer Caspr à l'ouverture de session",
                description: "Disponible dans la barre de menus dès le "
                    + "démarrage de votre Mac.",
                isOn: $enabled, isCard: false)
                .onChange(of: enabled) { _, wanted in
                    let actual = LoginItem.set(wanted)
                    refused = actual != wanted
                    // Recaler l'interrupteur sur ce que le système a vraiment
                    // fait, pas sur ce qu'on lui a demandé.
                    if actual != enabled { enabled = actual }
                }

            if refused, LoginItem.requiresApproval {
                Note("macOS a gardé le refus enregistré dans Réglages Système "
                     + "› Général › Ouverture : c'est là qu'il faut "
                     + "réautoriser Caspr.", warning: true)
                Button("Ouvrir Réglages Système › Ouverture") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            } else {
                Note("Caspr vit dans la barre de menus : s'il ne tourne pas, "
                     + "la touche de dictée ne fait rien, et rien n'indique "
                     + "que c'est la raison.")
            }
        }
        .onAppear { enabled = LoginItem.isEnabled }
    }
}

// MARK: - Transcription

// MARK: - Collecte

/// L'archive locale des dictées, et les moteurs qu'on fait tourner pour
/// comparer.
private struct CollectionTab: View {
    @State private var prefs = Preferences.shared
    @State private var stats = Corpus.Statistics()
    @State private var confirmingClear = false

    var body: some View {
        SettingsToggleRow(
            title: "Archiver mes dictées (Collecte & Comparatif)",
            description: "Garde le texte produit par chaque moteur à partir du "
                + "**même enregistrement** pour mesurer leur précision sur votre "
                + "propre voix.",
            note: "🔒 **100 % sur votre Mac.** Rien n'est envoyé nulle part, ni à "
                + "l'auteur de l'application ni à personne — il n'existe aucun "
                + "serveur pour le recevoir. Vous pouvez ouvrir le dossier et "
                + "l'effacer quand vous voulez.",
            isOn: $prefs.corpusEnabled)

        if prefs.corpusEnabled {
            Card {
                SettingsToggleRow(
                    title: "Conserver aussi l'audio (.wav)",
                    description: "Permet de ré-exécuter de futurs modèles sur vos "
                        + "enregistrements passés (~2 Mo par minute).",
                    isOn: $prefs.corpusKeepsAudio,
                    isCard: false)

                Divider().opacity(0.25)
                engines
                Divider().opacity(0.25)
                statistics
            }
        }

        Note("💡 **À quoi ça sert ?** Permet de lancer des scripts de "
             + "comparaison (bancs de test) pour calculer le taux d'erreur mot à "
             + "mot (WER) de chaque moteur sur votre propre voix.")
            .onAppear { stats = Corpus.shared.statistics() }
    }

    // MARK: Les moteurs à comparer

    private var engines: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MOTEURS EXÉCUTÉS EN TÂCHE DE FOND POUR COMPARAISON")
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.63)
                .foregroundStyle(Style.textTertiary)
                .padding(.bottom, 2)

            ForEach(EngineChoice.allCases, id: \.self) { choice in
                engineCheck(choice)
            }

            Note("⚡ Exécuté en arrière-plan **après l'insertion**. Les moteurs "
                 + "indisponibles sont grisés et ne participent pas à la collecte.")
        }
    }

    /// Une case par moteur, grisée quand ce moteur ne peut rien produire ici.
    ///
    /// ## Grisé, jamais masqué
    ///
    /// Le prototype **retire** Apple Intelligence de la liste sur un Mac Intel.
    /// On ne le suit pas, et c'est le seul écart de cette carte : une ligne
    /// absente ne se distingue pas d'une ligne qu'on n'a pas trouvée. Savoir
    /// qu'une version existe et qu'elle ne marche pas *ici* est une
    /// information ; son absence n'en est pas une, et laisse chercher.
    ///
    /// Le prototype a raison en revanche sur CrisperWhisper, qu'il grise avec
    /// un libellé qui dit pourquoi — c'est ce qu'on fait pour les trois.
    ///
    /// La case reste **cochable** malgré tout : elle vaudra le jour où le moteur
    /// sera là, et d'ici là rien ne tourne. Seul le moteur d'écriture est
    /// verrouillé, puisqu'il figure de toute façon dans chaque entrée.
    private func engineCheck(_ choice: EngineChoice) -> some View {
        let available = choice.isAvailable(for: prefs.primaryLanguage)
        let isWriter = choice == prefs.engine
        let checked = prefs.corpusEngines.contains(choice)

        return HStack(alignment: .top, spacing: 10) {
            CheckBox(checked: checked && available)
            VStack(alignment: .leading, spacing: 1) {
                Text(label(for: choice, available: available))
                    .font(.system(size: 12))
                    .foregroundStyle(available ? Style.textPrimary : Style.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if isWriter {
                    Text("Moteur d'écriture — toujours archivé")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Style.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(checked && available ? Color.white.opacity(0.04) : .clear))
        .opacity(available ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isWriter else { return }
            if checked { prefs.corpusEngines.remove(choice) }
            else { prefs.corpusEngines.insert(choice) }
        }
        .help(available ? "" : indisponibility(choice))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? [.isSelected, .isButton] : .isButton)
    }

    /// Un `switch` plutôt qu'une égalité, et ici la raison n'est pas la même
    /// qu'ailleurs : ces libellés **nomment une version et un modèle actif**.
    /// Sous une égalité, un moteur ajouté demain aurait composé tout seul
    /// « <NouveauMoteur> 2.0 (Modèle TURBO actif) » — une phrase fausse,
    /// affichée sans que rien n'ait échoué. Le compilateur pose maintenant la
    /// question.
    private func label(for choice: EngineChoice, available: Bool) -> String {
        switch choice {
        case .crisperWhisper:
            return available
                ? "\(choice.label) 2.0 (Modèle "
                    + "\(EngineInstall.selectedModel.label.uppercased()) actif)"
                : "CrisperWhisper 2.0 — non téléchargé (indisponible)"
        case .apple, .appleLegacy:
            return available
                ? choice.fullLabel
                : "\(choice.fullLabel) — indisponible sur ce Mac"
        }
    }

    private func indisponibility(_ choice: EngineChoice) -> String {
        switch choice {
        case .crisperWhisper:
            "Téléchargez d'abord un modèle dans l'onglet Moteur IA pour "
                + "activer ce comparatif."
        case .apple, .appleLegacy:
            "Cette version du moteur de macOS n'est pas utilisable ici, dans "
                + "la langue active."
        }
    }

    // MARK: L'état du corpus

    private var statistics: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Corpus local")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    if stats.count > 0 {
                        Text(stats.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Style.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Style.accent.opacity(0.1))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Style.accentBorder, lineWidth: 1)))
                    } else {
                        Text("(0 dictée enregistrée)")
                            .font(.system(size: 11))
                            .foregroundStyle(Style.textTertiary)
                    }
                }
                Text(.init("Format JSON Lines · Version active de l'app : "
                           + "**\(UpdateChecker.currentVersion)**"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Style.textTertiary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Afficher dans le Finder") { Corpus.shared.reveal() }
                    .buttonStyle(CasprSecondaryButtonStyle())
                if stats.count > 0 {
                    DangerLink("Tout effacer") { confirmingClear = true }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)))
        // Une confirmation, parce que c'est irréversible et que ces dictées ne
        // se reconstituent pas : ce sont des heures de parole réelle.
        .alert("Effacer tout le corpus ?", isPresented: $confirmingClear) {
            Button("Annuler", role: .cancel) {}
            Button("Tout effacer", role: .destructive) {
                Corpus.shared.clear()
                stats = Corpus.shared.statistics()
            }
        } message: {
            Text("\(stats.summary) seront supprimés, audio compris. Rien ne "
                 + "permet de les reconstituer.")
        }
    }
}

/// La case à cocher du prototype : carré arrondi de 16 pt qui se remplit
/// d'accent avec une coche sombre.
struct CheckBox: View {
    let checked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(checked ? Style.accent : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(checked ? Style.accent : Style.textTertiary,
                                  lineWidth: 1.5))
                .frame(width: 16, height: 16)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Style.onAccent)
            }
        }
        .padding(.top, 1)
    }
}

// MARK: - Historique

/// Les dernières transcriptions, et ce qu'on en garde.
private struct HistoryTab: View {
    let history: TranscriptionHistory
    @State private var entries: [TranscriptionHistory.Entry] = []
    @State private var justCopied: UUID?
    @State private var enabled = true
    @State private var limit = TranscriptionHistory.defaultLimit

    var body: some View {
        SettingsToggleRow(
            title: "Conserver l'historique des dictées",
            description: "Garde en mémoire vos dernières transcriptions locales "
                + "pour les réutiliser sans reparler.",
            note: enabled ? nil
                : "Rien n'est écrit. Les transcriptions passées ne sont pas "
                  + "conservées, même localement.",
            isOn: $enabled)
            .onChange(of: enabled) { _, on in
                history.isEnabled = on
                entries = history.entries
            }
            // Lu à l'ouverture, sinon jamais. Les trois états partaient de
            // valeurs par défaut et n'étaient repris de l'historique qu'au
            // basculement d'un réglage : la page s'ouvrait donc sur « Aucune
            // transcription » alors que le menu de la barre en listait cinq,
            // et le nombre d'entrées conservées affichait le défaut plutôt que
            // le réglage en vigueur.
            .onAppear {
                enabled = history.isEnabled
                limit = history.limit
                entries = history.entries
            }

        if enabled {
            AccentCard {
                capacityRow
                Divider().opacity(0.25)
                list
                Divider().opacity(0.25)
                footerRow
            }

            Note("Le texte complet est copié, pas la version tronquée. "
                 + "L'historique reste également accessible en direct depuis le "
                 + "menu de la barre des menus.")
        }
    }

    /// Le sélecteur de capacité, et ce qu'il implique dit en toutes lettres.
    private var capacityRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nombre d'entrées conservées")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(.init("Caspr conserve uniquement les **\(limit)** "
                           + "dernières dictées. Les plus anciennes sont "
                           + "écrasées."))
                    .font(.system(size: 11))
                    .foregroundStyle(Style.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            PillPicker(options: TranscriptionHistory.limits.map { ($0, "\($0)") },
                       selection: $limit)
                .onChange(of: limit) { _, new in
                    // Réduire tronque, ça n'efface pas — cf. `TranscriptionHistory`.
                    history.limit = new
                    entries = history.entries
                }
        }
    }

    @ViewBuilder
    private var list: some View {
        if entries.isEmpty {
            Text("Aucune transcription dans l'historique pour l'instant.")
                .font(.system(size: 12))
                .foregroundStyle(Style.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 2) {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: TranscriptionHistory.Entry) -> some View {
        HStack(spacing: 12) {
            // Tronqué sur une ligne : la fenêtre doit rester lisible d'un coup
            // d'œil, pas devenir une liste qu'on fait défiler. Le texte entier
            // est dans l'infobulle, et c'est lui qui part au presse-papiers.
            Text(entry.preview)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(entry.text)
            Spacer(minLength: 8)
            Text(entry.relativeAge)
                .font(.system(size: 10.5))
                .foregroundStyle(Style.textTertiary)
            copyButton(entry)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)))
    }

    /// Le bouton de copie, qui confirme puis redevient lui-même.
    ///
    /// Sans le retour visuel, copier ne produit **aucun** signe : le
    /// presse-papiers est invisible, et on reclique pour être sûr.
    private func copyButton(_ entry: TranscriptionHistory.Entry) -> some View {
        let copied = justCopied == entry.id
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            justCopied = entry.id
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if justCopied == entry.id { justCopied = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: copied ? .semibold : .regular))
                if copied {
                    Text("Copié").font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(copied ? Style.accent : Style.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(copied ? Style.accent.opacity(0.15) : Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(copied ? Style.accentBorder
                                             : Color.white.opacity(0.08),
                                      lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .help("Copier le texte entier")
        .animation(.easeOut(duration: 0.15), value: copied)
    }

    private var footerRow: some View {
        HStack {
            DangerLink("Effacer l'historique", enabled: !entries.isEmpty) {
                history.clear()
                entries = []
            }
            Spacer()
            Text("Seul le texte est conservé · 0 Mo d'audio stocké")
                .font(.system(size: 10.5))
                .foregroundStyle(Style.textTertiary)
        }
    }
}

/// Une carte bordée d'accent, pour la section qui porte le contenu vivant d'un
/// onglet — la liste des dictées, le lexique. Le prototype la distingue ainsi
/// de la carte de réglage qui la précède.
struct AccentCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                    .fill(Style.accent.opacity(0.03))
                    .overlay(RoundedRectangle(cornerRadius: Style.cardRadius,
                                              style: .continuous)
                        .strokeBorder(Style.accentBorder, lineWidth: 1)))
            // La même marge basse que `Card` — elle manquait ici, et le texte
            // qui suit la carte s'y collait.
            .padding(.bottom, 12)
    }
}

/// Une action destructive discrète, en rouge, qui se grise quand il n'y a rien
/// à détruire — plutôt que de disparaître, ce qui ferait chercher où elle est
/// passée.
struct DangerLink: View {
    let label: String
    var enabled = true
    let action: () -> Void

    init(_ label: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.label = label
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(enabled ? Style.danger : Style.textTertiary)
            .opacity(enabled ? 1 : 0.4)
            .disabled(!enabled)
    }
}
