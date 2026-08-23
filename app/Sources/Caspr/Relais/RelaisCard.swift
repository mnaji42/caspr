import SwiftUI

/// La bascule du relais, en tête de l'onglet Moteur IA.
///
/// **Un interrupteur, pas un choix de moteur.** ChatGPT et les moteurs de
/// Caspr s'excluent, et ce n'est pas une préférence de présentation : les deux
/// ne peuvent pas ouvrir le micro en même temps. Une capture par la page
/// ChatGPT laisse celle de Caspr sur du silence — mesuré au niveau crête, 0.072
/// avant, 0.000 après. Les proposer côte à côte dans une même liste laisserait
/// croire qu'on peut passer de l'un à l'autre d'une dictée sur l'autre ; on ne
/// peut pas, et l'exclusion doit se voir.
///
/// Elle a aussi une vertu pratique : tant que le relais est allumé, Caspr ne
/// touche jamais au micro, donc la page peut rester ouverte entre deux dictées.
/// C'est ce qui rend le raccourci instantané au lieu de recharger chatgpt.com à
/// chaque fois.
/// La liste des moteurs de Caspr lui est passée en paramètre plutôt que posée
/// à côté d'elle. C'est ce qui permet à l'exclusion de vivre entièrement ici :
/// la vue parente ne connaît qu'un appel, et le retrait consiste à remplacer
/// `RelaisCard { FinalEngineCard() }` par `FinalEngineCard()`. Un `if` chez le
/// parent aurait supposé qu'il observe un état qui ne le regarde pas, et il ne
/// se serait pas rafraîchi à la bascule.
struct RelaisCard<Moteurs: View>: View {
    @ViewBuilder var moteurs: Moteurs

    @State private var actif = Relais.partage.actif
    @State private var calibre = Relais.partage.estCalibre

    var body: some View {
        SettingsToggleRow(
            title: "ChatGPT Web Preview",
            description: "Dicter par le transcripteur de ChatGPT, dans une page "
                       + "que Caspr héberge. La touche de dictée ne change pas.",
            note: note,
            noteIsWarning: actif && !calibre,
            isOn: Binding(get: { actif }, set: basculer))

        if actif {
            Card {
                Text("Session ChatGPT")
                    .font(.system(size: 13, weight: .semibold))
                Note("Votre compte, votre session. Caspr ne fait que l'héberger : "
                     + "aucun identifiant ne lui est confié, et rien n'est envoyé "
                     + "dans une conversation — le message n'est jamais expédié.")
                HStack(spacing: 8) {
                    Button(calibre ? "Recalibrer les boutons…" : "Terminer la configuration…") {
                        Relais.partage.configurer()
                    }
                    Button("Ouvrir la fenêtre…") { Relais.partage.ouvrirFenetre() }
                    Button("Diagnostic…") { Relais.partage.diagnostic() }
                    Button("Se déconnecter…") { deconnecter() }
                }
                .buttonStyle(CasprSecondaryButtonStyle())
            }
        } else {
            // Les moteurs de Caspr n'apparaissent qu'à l'extinction. Les
            // laisser visibles sous un interrupteur qui les neutralise invite
            // à y cliquer, puis à chercher pourquoi rien ne change.
            moteurs
        }
    }

    /// Se déconnecter est une action qu'on ne défait pas d'un clic : il faudra
    /// ressaisir un mot de passe. On demande donc confirmation, en disant ce
    /// qui part et ce qui reste.
    private func deconnecter() {
        let a = NSAlert()
        a.messageText = "Se déconnecter de ChatGPT ?"
        a.informativeText = "La session est effacée de Caspr — cookies et stockage local. "
            + "Il faudra vous reconnecter pour dicter à nouveau.\n\n"
            + "Le calibrage des boutons est conservé : il ne dépend pas de la session."
        a.addButton(withTitle: "Se déconnecter")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task { await Relais.partage.deconnecter() }
    }

    private var note: String? {
        if actif && !calibre {
            return "Configuration inachevée : la dictée ne partira pas tant que les "
                 + "boutons de la page n'auront pas été montrés une fois."
        }
        if actif {
            return "Les moteurs ci-dessous sont sans effet tant que ce réglage est "
                 + "actif, et le moteur local est arrêté pour libérer sa mémoire. "
                 + "La transcription est faite par les serveurs d'OpenAI : elle "
                 + "exige une connexion, et l'aperçu en direct n'est pas possible."
        }
        return nil
    }

    private func basculer(_ nouveau: Bool) {
        Relais.partage.actif = nouveau
        actif = nouveau
        if nouveau, !Relais.partage.estCalibre {
            Relais.partage.configurer { calibre = Relais.partage.estCalibre }
        }
        // Le moteur local s'arrête ou repart selon la bascule : garder trois
        // gigaoctets de poids chargés pour un moteur qu'on ne peut plus appeler
        // n'a pas de sens. `needsLocalEngine` tient déjà compte du mode.
        EngineService.reconcile(needed: Preferences.shared.needsLocalEngine)
    }
}
