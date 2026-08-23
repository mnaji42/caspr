import AppKit
import SwiftUI

/// Prévient que CrisperWhisper charge encore, au démarrage de l'application.
///
/// Le service tourne sous launchd et met jusqu'à une minute à lire ses poids.
/// Pendant ce temps la dictée fonctionne — le repli l'envoie sur macOS — mais
/// elle ne rend pas ce qu'on attend, et rien ne le disait : on croyait dicter
/// avec CrisperWhisper et on obtenait autre chose, sans savoir pourquoi.
///
/// **Uniquement quand il y a quelque chose à attendre.** Sous macOS, rien ne
/// charge : le moteur est dans le système, il répond au premier mot. Ouvrir une
/// fenêtre pour annoncer que tout va bien serait une interruption sans objet.
@MainActor
final class EngineStartupNoticeController {
    private var window: NSWindow?

    /// À appeler au lancement, une fois les réglages appliqués.
    func showIfNeeded() {
        let prefs = Preferences.shared
        // RELAIS — le service local n'est pas démarré quand ChatGPT écrit, donc
        // annoncer son chargement promet une attente qui ne finira jamais.
        guard !Relais.partage.actif else { return }
        guard prefs.finalEngine.isLocalService,
              EngineInstall.selectedModel.isDownloaded,
              !EngineService.isAnswering,
              window == nil
        else { return }

        let window = NSWindow.caspr(title: "CrisperWhisper") {
            EngineStartupNoticeView(onClose: { [weak self] in self?.close() },
                                    onSettings: { [weak self] in
                                        self?.close()
                                        self?.openSettings?()
                                    })
        }
        // Plus petite que les autres fenêtres de Caspr : elle ne porte qu'une
        // phrase et deux boutons. La géométrie commune ferait 580 × 700 de vide.
        window.setContentSize(NSSize(width: 400, height: 196))
        window.styleMask.remove(.miniaturizable)
        self.window = window
        // Sans voler le focus : quelqu'un vient d'ouvrir sa session ou une
        // autre application, et cette fenêtre n'attend rien de lui.
        window.orderFrontRegardless()
        window.center()
    }

    /// Ouvre les Réglages, posé par le delegate.
    var openSettings: (() -> Void)?

    private func close() {
        window?.close()
        window = nil
    }
}

private struct EngineStartupNoticeView: View {
    let onClose: () -> Void
    let onSettings: () -> Void

    /// Dit que c'est prêt, laisse le temps de le lire, puis referme.
    ///
    /// Idempotente : elle est appelée à l'affichage **et** au changement d'état,
    /// et deux appels ne doivent pas programmer deux fermetures.
    private func announceReady() {
        guard !ready else { return }
        ready = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            onClose()
        }
    }

    @State private var ready = false
    @State private var monitor = EngineStateMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if ready {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Style.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(ready ? "CrisperWhisper est prêt."
                           : "CrisperWhisper démarre…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(ready
                 ? "Vos dictées passent désormais par lui."
                 : "Le modèle se charge en mémoire — jusqu'à une minute au "
                   + "premier démarrage. En attendant, Caspr dicte avec macOS.")
                .font(.system(size: 11.5))
                .foregroundStyle(Style.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if !ready {
                ProgressView().progressViewStyle(.linear).tint(Style.accent)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Réglages…") { onSettings() }
                    .buttonStyle(CasprSecondaryButtonStyle())
                Button("Fermer") { onClose() }
                    .buttonStyle(CasprPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        // La fenêtre est en `fullSizeContentView` : sans cette réserve, la
        // première ligne passe sous les feux tricolores. SwiftUI applique déjà
        // un décalage de sécurité, mais il colle le texte au titre.
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowBackground().ignoresSafeArea())
        .tint(Style.accent)
        // Le socket n'est pas observable : quelqu'un doit regarder. C'est
        // `EngineStateMonitor`, pour toute l'application — cette fenêtre avait
        // sa propre boucle, la carte CrisperWhisper une deuxième et la carte du
        // moteur final une troisième.
        //
        // Puis la fenêtre s'efface d'elle-même : elle a dit ce qu'elle avait à
        // dire, et deux secondes suffisent à lire « c'est prêt ».
        .onAppear {
            monitor.observe()
            // L'état courant compte autant que ses changements : le service a
            // pu finir de charger entre l'ouverture de la fenêtre et son
            // premier affichage, et `onChange` ne se déclenche que sur une
            // transition. Sans ça, la fenêtre resterait sur « démarre… »
            // devant un service prêt.
            if monitor.isAnswering { announceReady() }
        }
        .onDisappear { monitor.release() }
        .onChange(of: monitor.isAnswering) { _, answering in
            if answering { announceReady() }
        }
    }
}
