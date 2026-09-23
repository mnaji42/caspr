import AppKit
import SwiftUI

/// Les dernières transcriptions, et ce qu'on en garde.
struct HistoryTab: View {
    let history: TranscriptionHistory
    @State private var entries: [TranscriptionHistory.Entry] = []
    /// Le bouton qui vient de copier : l'entrée, ou sa transcription brute.
    @State private var justCopied: String?
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
            if let brut = entry.brut {
                copyButton(brut, cle: "\(entry.id)-brut", libelle: "Brut",
                           aide: "Copier ce que ChatGPT avait transcrit, avant la "
                               + "reprise du module")
            }
            copyButton(entry.text, cle: entry.id.uuidString, libelle: nil,
                       aide: "Copier le texte entier")
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
    ///
    /// `libelle` nomme ce qu'il copie quand ce n'est pas l'entrée elle-même :
    /// deux icônes identiques côte à côte ne diraient pas laquelle est le brut.
    private func copyButton(_ texte: String, cle: String, libelle: String?,
                            aide: String) -> some View {
        let copied = justCopied == cle
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(texte, forType: .string)
            justCopied = cle
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if justCopied == cle { justCopied = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: copied ? .semibold : .regular))
                if copied {
                    Text("Copié").font(.system(size: 10, weight: .semibold))
                } else if let libelle {
                    Text(libelle).font(.system(size: 10, weight: .semibold))
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
        .help(aide)
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
/// onglet — la liste des dictées. Le prototype la distingue ainsi
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
