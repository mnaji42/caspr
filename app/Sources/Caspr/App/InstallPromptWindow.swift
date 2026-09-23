import AppKit
import SwiftUI

/// « Caspr n'est pas encore installé », au premier double-clic depuis l'image.
///
/// ## Pourquoi une fenêtre plutôt qu'une alerte
///
/// C'était un `NSAlert`. Il disait la bonne chose, mais il la disait comme le
/// système : un panneau gris devant une application qu'on découvre. Or c'est le
/// tout premier écran de Caspr, avant même l'accueil — et il pose une question
/// dont la réponse conditionne tout le reste.
///
/// ## Rien d'autre ne s'ouvre tant qu'on n'a pas répondu
///
/// L'accueil attendait derrière. Configurer des langues et des autorisations
/// depuis une copie en lecture seule n'a pourtant aucun sens : les
/// autorisations sont attachées au chemin, et ce chemin va disparaître avec
/// l'image. Tout ce travail serait à refaire, sans que rien ne le dise. Les
/// deux réponses mènent donc à l'accueil, mais **après**.
@MainActor
final class InstallPromptWindowController {
    private var window: NSWindow?

    /// Ce qu'on propose, selon qu'une copie installée existe déjà.
    struct Choice {
        let alreadyInstalled: Bool
        let onPrimary: () -> Void
        let onContinue: () -> Void
    }

    func show(_ choice: Choice) {
        guard window == nil else { return }
        let window = NSWindow.caspr(title: "") {
            InstallPromptView(choice: choice, onFinish: { [weak self] in
                self?.close()
            })
        }
        window.setContentSize(NSSize(width: 380, height: 416))
        window.styleMask.remove(.closable)
        window.styleMask.remove(.miniaturizable)
        self.window = window
        window.showCentered()
    }

    private func close() {
        window?.close()
        window = nil
    }
}

private struct InstallPromptView: View {
    let choice: InstallPromptWindowController.Choice
    let onFinish: () -> Void

    @State private var working = false

    var body: some View {
        VStack(spacing: 0) {
            // L'icône de l'application
            if let icon = BrandIcon("caspr-app-icon", height: 74) {
                icon.shadow(color: Color(hex: 0x33E1FF).opacity(0.35),
                            radius: 16, y: 6)
                    .padding(.bottom, 18)
            }

            // Titre
            Text(choice.alreadyInstalled
                 ? "Ce n'est pas la copie installée"
                 : "Caspr n'est pas encore installé")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.bottom, 14)

            // Description
            VStack(spacing: 12) {
                Text(choice.alreadyInstalled
                     ? "Caspr est bien dans Applications, mais c'est la "
                       + "copie restée dans l'image disque qui vient de "
                       + "s'ouvrir — les deux icônes se ressemblent."
                     : "Il est ouvert depuis l'image disque, en lecture "
                       + "seule : les autorisations accordées seraient "
                       + "perdues et les mises à jour impossibles.")
                Text(choice.alreadyInstalled
                     ? "Ouvrez plutôt celle d'Applications : c'est elle qui "
                       + "garde vos autorisations."
                     : "Caspr peut s'installer dans **Applications** et "
                       + "s'y rouvrir tout seul.")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Style.textSecondary)
            .lineSpacing(2.5)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 22)

            // Boutons en pleine largeur
            VStack(spacing: 10) {
                Button {
                    working = true
                    choice.onPrimary()
                } label: {
                    Text(primaryLabel)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Style.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Capsule().fill(Style.accent))
                        .shadow(color: working ? .clear : Style.accentGlow, radius: 10, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(working)
                .opacity(working ? 0.4 : 1)

                Button {
                    choice.onContinue()
                    onFinish()
                } label: {
                    Text("Continuer quand même")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackground().ignoresSafeArea())
    }

    private var primaryLabel: String {
        if working { return "Installation en cours…" }
        return choice.alreadyInstalled ? "Ouvrir la copie installée"
                                       : "Installer et ouvrir"
    }
}
