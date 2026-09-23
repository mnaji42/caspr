/// Échap en raccourci global, pris et rendu à la demande.
///
/// Échap n'est capté que quand il a quelque chose à fermer : le monopoliser en
/// permanence casserait son usage normal dans toutes les autres apps. Quand le
/// prendre se décide ailleurs (cf. `DictationController.ajusterEchap`) ; ici,
/// seulement comment le prendre sans se marcher dessus.
@MainActor
final class Echap {
    private var monitor: HotkeyMonitor?
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    /// Prend Échap, ou le rend. Sans effet quand c'est déjà le cas.
    func tenir(_ voulu: Bool) {
        if !voulu {
            rendre()
        } else if monitor == nil {
            prendre()
        }
    }

    private func prendre() {
        // Rendu d'abord. Un second moniteur enregistré par-dessus le premier
        // se faisait refuser par Carbon, puis la libération de l'ancien
        // désenregistrait la touche : relancer une dictée depuis une
        // discussion laissait Échap sans aucun effet.
        rendre()
        let monitor = HotkeyMonitor(onTrigger: action)
        // Le résultat était jeté : un échec d'enregistrement laissait Échap
        // sans effet, sans que rien ne le signale nulle part.
        if !monitor.register(.cancel) {
            Log.info("Échap indisponible pendant cette dictée — raccourci déjà pris ?")
        }
        self.monitor = monitor
    }

    private func rendre() {
        monitor?.unregister()
        monitor = nil
    }
}
