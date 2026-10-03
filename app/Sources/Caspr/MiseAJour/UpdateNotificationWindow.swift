import AppKit
import SwiftUI
import CasprCore

/// « Une nouvelle version est disponible », au lancement.
///
/// ## Trois réponses, et elles ne veulent pas dire la même chose
///
/// - **Mettre à jour** : tout se passe ici, comme depuis les Réglages.
/// - **Plus tard** : on referme, et la proposition reviendra. C'est le défaut,
///   parce que « pas maintenant » est la réponse la plus courante et la moins
///   engageante.
/// - **Ignorer cette version** : on ne la reproposera plus — *celle-ci*. La
///   suivante, si. Sans cette distinction, « Ignorer » serait un interrupteur
///   déguisé dont on ne saurait plus revenir.
///
/// ## Elle ne paraît pas d'elle-même
///
/// Uniquement si la vérification automatique a été activée — c'est la seule
/// requête réseau de l'application — et uniquement quand une version plus
/// récente existe vraiment.
@MainActor
final class UpdateNotificationWindowController {
    private var window: NSWindow?

    func showIfNeeded() {
        let prefs = Preferences.shared
        guard prefs.checksForUpdates,
              let update = UpdateChecker.shared.proposee,
              window == nil
        else { return }

        let window = NSWindow.caspr(title: "Mise à jour") {
            UpdateNotificationView(update: update, onClose: { [weak self] in
                self?.close()
            })
        }
        // Plus haute quand il y a des nouveautés à lire, et pas autrement :
        // une fenêtre qui réserve la place d'une section absente laisse un vide
        // au-dessus des boutons. Le cas vide n'est plus 260 mais 300 : la liste
        // ne disparaît plus, elle dit qu'elle est vide (cf. `ReleaseNotesList`),
        // et il lui faut la place de le dire.
        let hasNotes = !ReleaseNotes.lines(from: update.notes).isEmpty
        window.setContentSize(NSSize(width: 400, height: hasNotes ? 400 : 300))
        window.styleMask.remove(.miniaturizable)
        self.window = window
        // Sans voler le focus : on vient d'ouvrir sa session, pas de demander
        // une mise à jour.
        window.orderFrontRegardless()
        window.center()
    }

    private func close() {
        window?.close()
        window = nil
    }
}

private struct UpdateNotificationView: View {
    let update: UpdateChecker.Release
    let onClose: () -> Void

    @State private var installer = UpdateInstaller.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Style.accent)
                Text("Caspr \(update.version) est disponible")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text("Vous utilisez la \(UpdateChecker.buildLabel). Tout se passe "
                 + "ici : le téléchargement, la vérification que la nouvelle "
                 + "version porte la même signature que celle-ci, le "
                 + "remplacement et le redémarrage. Vos réglages, votre "
                 + "historique et vos autorisations restent en place.")
                .font(.system(size: 12))
                .foregroundStyle(Style.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // Ce que la version apporte. C'est la seule raison d'accepter de
            // remplacer une application qui marche, et la fenêtre ne la disait
            // pas : elle demandait un geste sans donner son motif.
            ReleaseNotesList(notes: update.notes, maxHeight: 110)

            Spacer(minLength: 0)

            switch installer.phase {
            case .idle, .failed:
                if case .failed(let message) = installer.phase {
                    Note(message, warning: true)
                }
                actions
            case .downloading(let fraction):
                step("Téléchargement… \(Int(fraction * 100)) %") {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Style.accent)
                }
            case .verifying:
                step("Vérification de la signature…")
            case .installing:
                step("Installation…")
            case .relaunching:
                step("Mise à jour posée. Caspr redémarre…")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowBackground().ignoresSafeArea())
        .tint(Style.accent)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            // À gauche et discret : c'est la réponse la plus définitive des
            // trois, elle ne doit pas être la plus facile à cliquer.
            Button("Ignorer cette version") {
                Preferences.shared.ignoredUpdateVersion = update.version
                onClose()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .help("Ne plus proposer la \(update.version). Les suivantes seront "
                  + "proposées normalement.")

            Spacer(minLength: 8)

            Button("Plus tard") { onClose() }
                .buttonStyle(CasprSecondaryButtonStyle())

            if UpdateInstaller.obstacle == nil, update.asset != nil {
                Button("Mettre à jour") {
                    Task { await installer.install(update) }
                }
                .buttonStyle(CasprPrimaryButtonStyle())
            } else {
                Button("Voir la version") {
                    NSWorkspace.shared.open(update.page)
                }
                .buttonStyle(CasprPrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func step<Extra: View>(
        _ label: String, @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label).font(.system(size: 12))
            }
            extra()
        }
    }
}
