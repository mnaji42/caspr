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
    @State private var dialogue = Relais.partage.saitDialoguer

    var body: some View {
        SettingsToggleRow(
            title: "ChatGPT Web Preview",
            description: "Dicter par le transcripteur de ChatGPT, dans une page "
                       + "que Caspr héberge. La touche de dictée ne change pas.",
            note: note,
            noteIsWarning: actif && !calibre,
            isOn: Binding(get: { actif }, set: basculer))
            .onAppear(perform: relire)

        if actif {
            // Un bloc par mode, dans l'ordre où ils se débloquent.
            //
            // Ils ne sont pas trois variantes d'un même réglage : chacun exige
            // ce que le précédent a obtenu, **plus** une chose de son cru — le
            // deuxième deux boutons supplémentaires, le troisième une
            // autorisation système. Les empiler dans une seule carte, comme
            // c'était le cas, cachait cette progression et laissait croire
            // qu'on pouvait commencer par le milieu.
            etape(numero: 1,
                  titre: "Dicter — session ChatGPT",
                  faite: calibre,
                  explication: calibre
                    ? "Votre compte, votre session : Caspr ne fait que l'héberger, aucun "
                      + "identifiant ne lui est confié. En mode « Brut », rien n'est jamais "
                      + "envoyé dans une conversation."
                    : "Connectez-vous à ChatGPT, puis montrez à Caspr trois boutons de la "
                      + "page : le micro, l'arrêt, et la zone de texte.") {
                Button(calibre ? "Recalibrer les boutons…" : "Terminer la configuration…") {
                    Relais.partage.configurer(relire)
                }
                Button("Ouvrir la fenêtre…") { Relais.partage.ouvrirFenetre() }
                Button("Diagnostic…") { Relais.partage.diagnostic() }
                Button("Se déconnecter…") { deconnecter() }
            }

            etape(numero: 2,
                  titre: "Réorganiser — remettre en ordre ce qui a été dit",
                  faite: dialogue,
                  disponible: calibre,
                  explication: dialogue
                    ? "Ce que vous venez de dicter repart à ChatGPT pour être remis en "
                      + "ordre : hésitations, redites et faux départs disparaissent, toutes "
                      + "les idées restent. Le mode se choisit sur la barre de dictée, à "
                      + "côté de « Brut ».\n\nComptez une trentaine de secondes de plus, et "
                      + "sachez que le texte part alors dans votre historique ChatGPT — ce "
                      + "qui n'arrive jamais en mode « Brut »."
                    : "Deux boutons de plus à montrer : l'envoi, et la réponse. La "
                      + "calibration enverra un message d'essai — c'est le seul moyen de "
                      + "faire exister une réponse à désigner.") {
                Button(dialogue ? "Recalibrer l'aller-retour…" : "Activer « Réorganiser »…") {
                    Relais.partage.calibrerDialogue(relire)
                }
            }
        } else {
            // Les moteurs de Caspr n'apparaissent qu'à l'extinction. Les
            // laisser visibles sous un interrupteur qui les neutralise invite
            // à y cliquer, puis à chercher pourquoi rien ne change.
            moteurs
        }
    }

    /// Une étape de configuration : son rang, son état, ses actions.
    ///
    /// `disponible` grise l'étape tant que la précédente n'est pas faite,
    /// plutôt que de la masquer : on doit pouvoir lire d'avance ce qui attend,
    /// et comprendre pourquoi ce n'est pas encore accessible.
    @ViewBuilder
    private func etape(numero: Int, titre: String, faite: Bool, disponible: Bool = true,
                       explication: String,
                       @ViewBuilder actions: () -> some View) -> some View {
        Card {
            HStack(spacing: 8) {
                Text("\(numero).")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Style.textSecondary)
                Text(titre)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if faite {
                    Text("configuré")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Style.textSecondary)
                }
            }
            Note(disponible ? explication
                            : "Terminez l'étape précédente pour débloquer celle-ci.",
                 warning: !disponible)
            if disponible {
                HStack(spacing: 8) { actions() }
                    .buttonStyle(CasprSecondaryButtonStyle())
            }
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

    /// Relire l'état à chaque apparition de l'écran.
    ///
    /// `@State` ne s'initialise qu'à la création de la vue. Une calibration
    /// menée depuis un autre chemin — ou avant que cet écran n'existe — la
    /// laissait donc périmée : les réglages annonçaient « configuration
    /// inachevée » à quelqu'un qui venait de la terminer.
    private func relire() {
        actif = Relais.partage.actif
        calibre = Relais.partage.estCalibre
        dialogue = Relais.partage.saitDialoguer
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
            Relais.partage.configurer(relire)
        }
        // Le moteur local s'arrête ou repart selon la bascule : garder trois
        // gigaoctets de poids chargés pour un moteur qu'on ne peut plus appeler
        // n'a pas de sens. `needsLocalEngine` tient déjà compte du mode.
        EngineService.reconcile(needed: Preferences.shared.needsLocalEngine)
    }
}
