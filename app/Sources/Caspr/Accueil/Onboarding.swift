import AppKit
import SwiftUI
import CasprCore

/// L'accueil du premier lancement.
///
/// Caspr ne peut pas se contenter d'apparaître dans la barre de menus. Il lui
/// faut le micro et l'accessibilité, puis, selon la voie, un modèle de macOS
/// qui se télécharge ou une page ChatGPT connectée et calibrée — des
/// conditions qu'une app sans fenêtre n'a aucun moyen d'expliquer une fois
/// lancée et invisible. Sans accueil, le premier lancement se solde par une
/// icône muette et une dictée qui ne fait rien.
///
/// ## Cinq étapes, et aucune n'est une page vide
///
/// Une version précédente en comptait six, dont quatre ne portaient qu'un titre
/// et deux phrases ; celle d'après en comptait cinq mais réimplémentait les
/// questions que les Réglages posaient déjà, si bien que les deux avaient
/// divergé. L'écran du moteur de la passe finale est parti quand la version de
/// macOS a cessé d'être un choix ; celui de la voie est venu quand ChatGPT est
/// devenu la moitié du produit. Celle-ci n'écrit **aucun** réglage de son
/// côté : chaque étape instancie les mêmes vues que les Réglages, et sa seule
/// responsabilité est l'ordre dans lequel on les rencontre.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    /// N'ouvre que si l'accueil n'a jamais été mené à terme.
    func showIfNeeded() {
        guard !Preferences.shared.onboarded else { return }
        show()
    }

    func show() {
        if let window {
            window.showCentered()
            return
        }

        // `weak var` capturé plus bas : la vue met à jour le titre de la
        // fenêtre qui la contient, ce que SwiftUI ne sait pas faire seul.
        var host: NSWindow?
        let window = NSWindow.caspr(title: OnboardingStep.resumed.windowTitle(Preferences.shared.voie)) {
            OnboardingView(onFinish: { [weak self] in self?.close() },
                           onOpenSettings: { [weak self] in
                               self?.close()
                               self?.openSettings?()
                           },
                           onTitleChange: { title in host?.title = title },
                           onCalibrationEnded: { [weak self] in self?.comeBack() })
        }
        host = window
        self.window = window

        window.showCentered()
    }

    /// Ouvre les Réglages, posé par le delegate : l'accueil ne connaît pas la
    /// fenêtre des Réglages et n'a aucune raison de la connaître.
    var openSettings: (() -> Void)?

    private func close() {
        window?.close()
        window = nil
    }

    /// Ramène l'accueil devant, là où il était.
    ///
    /// Une calibration de la page ChatGPT se termine en cachant Caspr tout
    /// entier, pour rendre la main à l'application d'où l'on venait — et
    /// l'accueil disparaissait avec elle, au milieu du parcours, comme s'il
    /// était fini. Sans `center()` : on le retrouve où on l'avait laissé.
    private func comeBack() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
