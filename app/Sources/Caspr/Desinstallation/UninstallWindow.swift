import AppKit
import SwiftUI

/// La fenêtre de désinstallation.
///
/// Une fenêtre à elle, ni les réglages ni l'accueil : on n'entre pas ici par
/// hasard, et on ne doit pas tomber dessus en cherchant autre chose.
@MainActor
final class UninstallWindowController {
    /// Partagé : deux instances laisseraient deux fenêtres ouvertes sur la
    /// même suppression.
    static let shared = UninstallWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.showCentered()
            return
        }

        let window = NSWindow.caspr(title: "Désinstaller Caspr") {
            UninstallView(onCancel: { [weak self] in self?.close() })
        }
        self.window = window

        window.showCentered()
    }

    private func close() {
        window?.close()
        window = nil
    }
}

// MARK: - Vue

private struct UninstallView: View {
    let onCancel: () -> Void

    @State private var selected: Set<Uninstall.Item> = []
    @State private var report: [String]?
    @State private var initialised = false
    /// Ce qui est là, relevé une fois à l'ouverture : cocher une case ne
    /// change rien au disque.
    @State private var present: [Uninstall.Item] = []
    @State private var details: [Uninstall.Item: String] = [:]
    /// Le bouton restait actif pendant l'effacement de la session ChatGPT,
    /// qui prend un instant : un second clic lançait un second balayage, qui
    /// ne trouvait plus rien, et c'est son compte rendu — « rien à retirer »
    /// partout — qui s'affichait à la place du vrai.
    @State private var enCours = false

    private var title: String {
        report == nil ? "Désinstaller Caspr" : "Caspr est désinstallé"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 28)
                .padding(.horizontal, Style.windowPadding)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let report { summary(report) } else { chooser }
                }
                .padding(.horizontal, Style.windowPadding)
                .padding(.top, 18)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowBackground().ignoresSafeArea())
        // Tout est coché d'avance : rien de ce qui est listé ne sert plus une
        // fois l'application partie. L'environnement Python de l'ancien moteur
        // restait décoché tant qu'un dépôt de travail pouvait encore relancer
        // ce moteur à la main ; le code en a quitté le dépôt, l'environnement
        // n'est plus qu'un reste.
        // Le drapeau évite de recocher ce que l'utilisateur vient de décocher
        // si la vue réapparaît.
        .onAppear {
            guard !initialised else { return }
            initialised = true
            selected = Set(Uninstall.Item.allCases)
            present = Uninstall.Item.allCases.filter(Uninstall.isPresent)
        }
        .task { details = await Uninstall.details() }
    }

    // MARK: Choix

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("L'application part dans tous les cas. Choisissez ce qui "
                 + "s'en va avec elle.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            SectionLabel("à retirer aussi")
            Card {
                // Seulement ce qui est réellement là. Les absents étaient
                // listés puis grisés : on proposait de retirer un modèle jamais
                // téléchargé, un service jamais installé. Une case morte n'informe
                // pas — elle fait douter de ce qu'on a installé, à l'instant
                // précis où l'on veut être sûr de ce qu'on efface.
                ForEach(present) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        OptionCheck(title: item.label, isOn: Binding(
                            get: { selected.contains(item) },
                            set: { on in
                                if on { selected.insert(item) } else { selected.remove(item) }
                            }))

                        Text(details[item] ?? "")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)

                        Note(item.explanation)
                            .padding(.leading, 20)
                    }

                    if item != present.last {
                        Divider().opacity(0.25)
                    }
                }

                // Tout est déjà parti, ou rien n'a jamais été installé.
                if present.isEmpty {
                    Note("Rien d'autre à retirer sur cette machine.")
                }
            }

            SectionLabel("ce qui n'est jamais touché")
            Card {
                Note("**Votre fichier de notes.** S'il en existe un, c'est "
                     + "votre document : Caspr y écrivait, il ne lui "
                     + "appartient pas.")
                Note("**Tout part à la corbeille**, jamais en suppression "
                     + "définitive. Vous gardez la main jusqu'à ce que vous la "
                     + "vidiez.")
            }
        }
    }

    // MARK: Compte rendu

    private func summary(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("ce qui a été fait")
            Card {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("✗") ? Style.warning : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Note("Merci de l'avoir essayé.")
        }
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            if report == nil {
                Button("Annuler", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(enCours)
                Button("Désinstaller") {
                    guard !enCours else { return }
                    enCours = true
                    // La session ChatGPT s'efface par l'API de
                    // WebKit, avant le balayage des fichiers : c'est la seule
                    // voie qu'Apple garantisse, et elle demande d'attendre.
                    Task {
                        if selected.contains(.settings) {
                            await Relais.partage.deconnecter()
                        }
                        report = Uninstall.perform(selected)
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(enCours)
                    // Rouge, et non l'ambre des avertissements : « attention »
                    // et « ceci part » ne sont pas le même registre, et c'est
                    // le seul bouton de l'application dont l'effet ne se
                    // défait pas.
                    .tint(Style.dangerSurface)
            } else {
                Button("Quitter Caspr") { NSApp.terminate(nil) }
                .buttonStyle(.borderedProminent)
                .tint(Style.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Style.windowPadding)
        .padding(.vertical, 18)
    }
}
