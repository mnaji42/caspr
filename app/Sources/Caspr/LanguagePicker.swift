import SwiftUI

/// Le catalogue des langues, avec recherche et puces de sélection.
///
/// La même vue dans l'accueil (écran 2, déployée) et dans les Réglages (repliée
/// dans un tiroir, cf. `PrimaryLanguageSelector`).
///
/// ## Ce qui est montré, et ce qui est grisé
///
/// Le prototype liste les langues sans distinction. Sur une machine réelle,
/// c'est trompeur : un Mac Intel n'a pas Apple Intelligence, une machine
/// virtuelle n'a aucun modèle système, et la Dictée ne couvre que les langues
/// que macOS a installées. Laisser choisir une langue qu'aucun moteur ne sait
/// transcrire ici, c'est laisser quelqu'un configurer une dictée qui ne dira
/// rien — et le lui apprendre à la première phrase.
///
/// Les langues sont donc **listées toutes**, mais celles qu'aucun moteur ne
/// peut honorer sur cette machine sont grisées et le disent. Les masquer aurait
/// été pire : une liste où l'espagnol n'apparaît pas ne se distingue pas d'une
/// liste où on ne l'a pas trouvé.
///
/// La disponibilité est **mesurée** — `SpeechTranscriber.supportedLocales`,
/// `SFSpeechRecognizer`, la couverture des poids Whisper — jamais déduite d'un
/// numéro de version. Cf. `03_REGLES_SYSTEME_MACOS`.
struct LanguagePicker: View, ValidatingComponent {
    @State private var prefs = Preferences.shared
    @State private var search = ""
    /// Les locales qu'`SpeechTranscriber` propose ici. Vide tant que la mesure
    /// n'est pas revenue, et vide aussi quand ce moteur n'existe pas.
    @State private var systemLocales: Set<String> = []
    @State private var measured = false

    static func validate() -> ComponentValidationError? {
        Preferences.shared.selectedLanguages.isEmpty ? .noLanguageSelected : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            selectedTags
            searchField
            catalog
        }
        // Une seule mesure par affichage : interroger le système à chaque
        // frappe dans la recherche ferait un aller-retour par caractère.
        .task {
            guard !measured else { return }
            systemLocales = Set(await Language.systemSupportedLocales())
            measured = true
        }
    }

    // MARK: - Les langues retenues

    private var selectedTags: some View {
        FlowLayout(spacing: 6) {
            ForEach(prefs.activeLanguages) { language in
                tag(for: language)
            }
        }
    }

    private func tag(for language: Language) -> some View {
        let isPrimary = language.code == prefs.primaryLanguage
        // La dernière langue ne se retire pas : sans langue, aucun moteur ne
        // sait quoi charger. La croix disparaît plutôt que d'échouer au clic.
        let canRemove = prefs.selectedLanguages.count > 1

        return HStack(spacing: 5) {
            Text(language.badge)
                .font(.system(size: 12, weight: isPrimary ? .semibold : .medium))
            if isPrimary {
                Text("(Principale)")
                    .font(.system(size: 10))
                    .opacity(0.85)
            }
            if canRemove {
                Button {
                    prefs.selectedLanguages.removeAll { $0 == language.code }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Retirer cette langue")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(Style.accent)
        .background(
            Capsule()
                // La principale se distingue par un fond plus dense et une
                // bordure pleine, pas par une couleur différente : ce sont les
                // mêmes objets, l'un est simplement actif.
                .fill(Style.accent.opacity(isPrimary ? 0.2 : 0.12))
                .overlay(Capsule().strokeBorder(
                    isPrimary ? Style.accent : Style.accentBorder, lineWidth: 1)))
    }

    // MARK: - Recherche

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Rechercher une langue (ex: Anglais, Espagnol)...", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Style.fieldRadius, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: Style.fieldRadius,
                                          style: .continuous)
                    .strokeBorder(Style.cardStroke, lineWidth: 1)))
    }

    // MARK: - Catalogue

    private var results: [Language] { Language.matching(search) }

    @ViewBuilder
    private var catalog: some View {
        if results.isEmpty {
            Note("Aucune langue ne correspond à « \(search) ».")
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(results) { language in
                        row(for: language)
                    }
                }
            }
            .frame(height: 125)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: Style.fieldRadius, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: Style.fieldRadius,
                                              style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)))
        }
    }

    private func row(for language: Language) -> some View {
        let selected = prefs.selectedLanguages.contains(language.code)
        let usable = isUsable(language)

        // Un vrai bouton : la ligne était un `HStack` avec un `onTapGesture`,
        // donc on ne pouvait ni ajouter ni retirer une langue au clavier, et
        // VoiceOver n'annonçait pas qu'il y avait quelque chose à activer.
        return Button {
            toggle(language)
        } label: {
            content(for: language, selected: selected, usable: usable)
        }
        .buttonStyle(.plain)
        .help(usable ? "" : indisponibilityReason(language))
        .accessibilityLabel("\(language.displayName)\(selected ? ", retenue" : "")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func content(for language: Language,
                         selected: Bool, usable: Bool) -> some View {
        HStack(spacing: 8) {
            Text(language.flag).font(.system(size: 13))
            Text(language.name).font(.system(size: 12, weight: .medium))
            if !language.region.isEmpty {
                Text("(\(language.region))")
                    .font(.system(size: 11))
                    .foregroundStyle(Style.textTertiary)
            }
            Spacer(minLength: 8)
            if !usable {
                Text("indisponible ici")
                    .font(.system(size: 10))
                    .foregroundStyle(Style.warning)
            } else if !selected, systemLocales.contains(language.code) {
                // Le poids ne concerne que la version Apple Intelligence, et
                // il est approximatif — Apple n'expose pas la taille d'un
                // actif avant son installation. « environ » n'est pas une
                // précaution de style, c'est la vérité de la mesure.
                Text("~\(language.estimatedSizeLabel)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(selected ? "✓" : "+")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Style.accent : Style.textTertiary)
                .frame(width: 12)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .opacity(usable ? 1 : 0.45)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Style.accent.opacity(0.12) : .clear))
    }

    private func toggle(_ language: Language) {
        if prefs.selectedLanguages.contains(language.code) {
            // Refusé plutôt qu'échoué : `Preferences` remettrait le français
            // par défaut, ce qui changerait la langue sous les yeux de
            // quelqu'un qui essayait juste de retirer une entrée.
            guard prefs.selectedLanguages.count > 1 else { return }
            prefs.selectedLanguages.removeAll { $0 == language.code }
        } else {
            prefs.selectedLanguages.append(language.code)
        }
    }

    // MARK: - Ce que cette machine sait faire

    /// Cette langue peut-elle être dictée ici ?
    ///
    /// Sous macOS, deux chances, et il en suffit d'une : le moteur de macOS 26
    /// propose la locale, ou la Dictée sait la traiter hors ligne.
    ///
    /// **Sous ChatGPT, rien n'est grisé.** Le relais ne dépend d'aucun modèle
    /// de cette machine : c'est le transcripteur de ChatGPT qui écoute. Griser
    /// une langue que macOS ne sait pas écrire dirait « indisponible » à
    /// quelqu'un qui peut la dicter tout de suite.
    private func isUsable(_ language: Language) -> Bool {
        if Relais.partage.actif { return true }                    // RELAIS —
        if !measured { return true }
        if systemLocales.contains(language.code) { return true }
        return LegacySpeechEngine.isAvailable(for: language.code)
    }

    private func indisponibilityReason(_ language: Language) -> String {
        "macOS ne transcrit pas le \(language.displayName) sur cette machine : "
            + "Apple Intelligence ne propose pas cette locale, et la Dictée n'a "
            + "pas ses modèles."
    }
}

#Preview("Catalogue de langues") {
    ScrollView {
        Card {
            LanguagePicker()
        }
        .padding(Style.windowPadding)
    }
    .frame(width: Style.windowWidth, height: Style.windowHeight)
    .background(Color(hex: 0x141821))
}
