import AppKit
import SwiftUI

/// La fenêtre de désinstallation.
///
/// Une fenêtre à elle, ni les réglages ni l'accueil : on n'entre pas ici par
/// hasard, et on ne doit pas tomber dessus en cherchant autre chose.
@MainActor
final class UninstallWindowController {
    /// Partagé, parce que deux surfaces l'ouvrent désormais : le menu de la
    /// barre pour la désinstallation complète, et les Réglages pour le retrait
    /// de CrisperWhisper seul. Deux instances laisseraient deux fenêtres
    /// ouvertes sur la même suppression.
    static let shared = UninstallWindowController()

    private var window: NSWindow?
    private var scope: UninstallScope = .everything

    /// - Parameter scope: tout, ou CrisperWhisper seul. La seconde portée est
    ///   ouverte depuis les Réglages ; elle emprunte cette fenêtre plutôt
    ///   qu'une copie, pour que le retrait passe par le code déjà éprouvé.
    func show(scope: UninstallScope = .everything) {
        if let window, self.scope == scope {
            window.showCentered()
            return
        }

        // Une portée différente demande une fenêtre neuve : la sélection
        // initiale se calcule à l'apparition.
        close()
        self.scope = scope
        let window = NSWindow.caspr(
            title: scope.removesApp ? "Désinstaller Caspr" : "Retirer CrisperWhisper"
        ) {
            UninstallView(onCancel: { [weak self] in self?.close() }, scope: scope)
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
    /// Ce que cette fenêtre a le droit de proposer.
    ///
    /// La désinstallation complète les présente tous ; le retrait de
    /// CrisperWhisper depuis les Réglages n'en montre que deux. Une portée
    /// plutôt qu'une seconde fenêtre : ce sont les mêmes fonctions qui
    /// effacent, et deux chemins vers un `rm` de plusieurs gigaoctets
    /// finiraient par diverger — c'est exactement le défaut qu'on vient de
    /// corriger entre l'accueil et les Réglages.
    var scope: UninstallScope = .everything

    @State private var selected: Set<Uninstall.Item> = []
    @State private var report: [String]?
    @State private var initialised = false

    private var title: String {
        switch (scope, report == nil) {
        case (.everything, true): "Désinstaller Caspr"
        case (.everything, false): "Caspr est désinstallé"
        case (.crisperWhisper, true): "Retirer CrisperWhisper"
        case (.crisperWhisper, false): "CrisperWhisper est retiré"
        }
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
        // La sélection dépend de la portée, qui n'est pas connue à
        // l'initialisation d'un @State. Le drapeau évite de recocher ce que
        // l'utilisateur vient de décocher si la vue réapparaît.
        .onAppear {
            guard !initialised else { return }
            initialised = true
            selected = Set(scope.items.filter(scope.isCheckedByDefault))
        }
    }

    // MARK: Choix

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(scope.removesApp
                 ? "L'application part dans tous les cas. Choisissez ce qui "
                   + "s'en va avec elle."
                 : "Caspr reste installé et continue de dicter avec le "
                   + "moteur de macOS. Seul CrisperWhisper s'en va.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            SectionLabel("à retirer aussi")
            Card {
                // Seulement ce qui est réellement là. Les absents étaient
                // listés puis grisés : on proposait de retirer un modèle jamais
                // téléchargé, un corpus jamais écrit. Une case morte n'informe
                // pas — elle fait douter de ce qu'on a installé, à l'instant
                // précis où l'on veut être sûr de ce qu'on efface.
                let present = scope.items.filter(Uninstall.isPresent)
                ForEach(present) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        OptionCheck(title: item.label, isOn: Binding(
                            get: { selected.contains(item) },
                            set: { on in
                                if on { selected.insert(item) } else { selected.remove(item) }
                            }))

                        Text(Uninstall.detail(for: item))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)

                        Note(item.explanation, warning: item.irreversible && selected.contains(item))
                            .padding(.leading, 20)
                    }

                    if item != present.last {
                        Divider().opacity(0.25)
                    }
                }

                // Tout est déjà parti, ou rien n'a jamais été installé.
                if present.isEmpty {
                    Note("Rien d'autre à retirer : ni modèle téléchargé, ni "
                         + "corpus, ni environnement Python sur cette machine.")
                }
            }

            if selected.contains(.corpus), Corpus.shared.statistics().count > 0 {
                SectionLabel("attention")
                Card {
                    Note("Vous avez coché **\(Corpus.shared.statistics().count) "
                         + "dictées archivées**. Elles vont à la corbeille, "
                         + "donc elles sont récupérables tant que vous ne "
                         + "l'avez pas vidée — mais rien ne permettrait de les "
                         + "reconstituer ensuite.", warning: true)
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

            if !selected.contains(.corpus), Corpus.shared.statistics().count > 0 {
                SectionLabel("ce qui reste")
                Card {
                    Note("Vos dictées archivées sont toujours là, dans "
                         + "`~/Library/Application Support/Caspr`. "
                         + "Réinstaller Caspr les retrouvera.")
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
                Button(scope.removesApp ? "Désinstaller" : "Retirer") {
                    // RELAIS — la session ChatGPT s'efface par l'API de
                    // WebKit, avant le balayage des fichiers : c'est la seule
                    // voie qu'Apple garantisse, et elle demande d'attendre.
                    Task {
                        if selected.contains(.settings) {
                            await Relais.partage.deconnecter()
                        }
                        report = Uninstall.perform(selected, removingApp: scope.removesApp)
                    }
                }
                    .buttonStyle(.borderedProminent)
                    // Rouge, et non l'ambre de la collecte : « ceci est
                    // archivé » et « ceci part » ne sont pas le même registre,
                    // et c'est le seul bouton de l'application dont l'effet ne
                    // se défait pas.
                    .tint(Style.dangerSurface)
            } else {
                // Quitter n'a de sens que si l'application vient de partir.
                Button(scope.removesApp ? "Quitter Caspr" : "Fermer") {
                    if scope.removesApp { NSApp.terminate(nil) } else { onCancel() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Style.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Style.windowPadding)
        .padding(.vertical, 18)
    }
}

/// Ce qu'une fenêtre de retrait a le droit de proposer.
///
/// Une portée plutôt qu'une seconde fenêtre : ce sont les mêmes fonctions qui
/// effacent, et deux chemins vers la suppression de plusieurs gigaoctets
/// finiraient par diverger — c'est exactement le défaut qu'on vient de
/// corriger entre l'accueil et les Réglages.
enum UninstallScope: Equatable {
    case everything
    /// CrisperWhisper seul : l'application reste, et rien de ce qui touche aux
    /// réglages, au corpus ou aux autorisations n'est même proposé — donc rien
    /// d'irréversible ne peut être coché par mégarde.
    case crisperWhisper

    var items: [Uninstall.Item] {
        switch self {
        case .everything: Uninstall.Item.allCases
        case .crisperWhisper: [.model, .service, .engine]
        }
    }

    /// Cochés d'avance. Pour un retrait ciblé, les poids et le service oui —
    /// c'est ce qu'on est venu retirer. L'environnement Python non : c'est ce
    /// qui coûte le plus à reconstruire, et son nom inquiète même quand il ne
    /// désigne que le nôtre.
    func isCheckedByDefault(_ item: Uninstall.Item) -> Bool {
        switch self {
        case .everything: item.checkedByDefault
        case .crisperWhisper: item != .engine
        }
    }

    var removesApp: Bool { self == .everything }
}
