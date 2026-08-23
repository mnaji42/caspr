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
    @State private var depart = Relais.partage.departPersonnalise
    @State private var modules = RelaisCatalogue.tous
    @State private var selecteurs = RelaisSelecteurs.charger()
    @ObservedObject private var relais = Relais.partage

    var body: some View {
        // Une carte pour la fonctionnalité et ce que Caspr a appris, puis une
        // carte par module. Les étapes numérotées ont disparu : elles
        // suggéraient un escalier, alors que les capacités sont indépendantes —
        // un module peut exiger d'envoyer sans jamais récupérer, donc moins
        // qu'un autre qui venait pourtant avant lui.
        Card {
            SettingsToggleRow(
                title: "ChatGPT Web Preview",
                description: "Dicter par le transcripteur de ChatGPT, dans une page "
                           + "que Caspr héberge. La touche de dictée ne change pas.",
                note: note,
                noteIsWarning: actif && !calibre,
                isOn: Binding(get: { actif }, set: basculer),
                isCard: false)
                .onAppear(perform: relire)

            if actif {
                Divider().opacity(0.25)
                capacites
                // Grisés pendant qu'un autre flux pilote la page. Un bouton
                // qu'on peut cliquer et qui refusera ensuite vaut moins qu'un
                // bouton qui dit d'emblée que ce n'est pas le moment.
                ButtonRow {
                    Button(calibre ? "Tout recalibrer…" : "Apprendre les boutons…") {
                        Relais.partage.calibrerTout(relire)
                    }
                    Button("Ouvrir la fenêtre…") { Relais.partage.ouvrirFenetre() }
                    Button("Diagnostic…") { Relais.partage.diagnostic() }
                    Button("Se déconnecter…") { deconnecter() }
                }
                .disabled(relais.occupation != .libre)
                if let raison = relais.occupation.raison {
                    Note(raison + " Les réglages de la page attendent qu'elle se termine.",
                         warning: true)
                }
            }
        }

        if actif {
            SectionLabel("Modules")
            ForEach(modules) { module in
                RelaisModuleCard(module: module, selecteurs: selecteurs,
                                 surChangement: relire)
            }

            if depart || modules.contains(where: \.demandeUnAllerRetour) {
                Card {
                    Row(label: "Conversations créées par Caspr") {
                        Text(depart ? "dans un projet dédié" : "dans l'historique général")
                            .font(.system(size: 12))
                            .foregroundStyle(Style.textSecondary)
                    }
                    Note("Chaque dictée qui envoie ouvre une conversation neuve, sans quoi "
                         + "la précédente orienterait la suivante. Pour les tenir à "
                         + "l'écart : créez un projet dans ChatGPT, ouvrez-le dans la "
                         + "fenêtre du relais, puis adoptez-le.")
                    ButtonRow {
                        Button("Adopter la page ouverte…") {
                            Relais.partage.adopterPageDeDepart()
                            relire()
                        }
                        if depart {
                            Button("Revenir à l'accueil") {
                                Relais.partage.oublierPageDeDepart()
                                relire()
                            }
                        }
                    }
                }
            }
        } else {
            // Les moteurs de Caspr n'apparaissent qu'à l'extinction. Les
            // laisser visibles sous un interrupteur qui les neutralise invite
            // à y cliquer, puis à chercher pourquoi rien ne change.
            moteurs
        }
    }

    /// Ce que Caspr a appris de la page — et ce qui lui manque encore.
    ///
    /// Les capacités sont montrées telles quelles, sans être rangées en étapes :
    /// elles ne se conditionnent pas les unes les autres, et les numéroter
    /// laissait croire le contraire. Chaque module dit ensuite lesquelles il
    /// exige, ce qui est la seule dépendance réelle.
    private var capacites: some View {
        FlowLayout(spacing: 6) {
            ForEach(RelaisCapacite.allCases, id: \.rawValue) { capacite in
                let acquise = capacite.estAcquise(selecteurs)
                HStack(spacing: 5) {
                    Image(systemName: acquise ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .bold))
                    Text(capacite.libelle).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(acquise ? Style.accent : Style.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(acquise ? Style.accent.opacity(0.12)
                                                   : Color.primary.opacity(0.05)))
                .help(acquise ? capacite.libelle : capacite.commentAcquerir)
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
        depart = Relais.partage.departPersonnalise
        modules = RelaisCatalogue.tous
        selecteurs = RelaisSelecteurs.charger()
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
            Relais.partage.calibrerTout(relire)
        }
        // Le moteur local s'arrête ou repart selon la bascule : garder trois
        // gigaoctets de poids chargés pour un moteur qu'on ne peut plus appeler
        // n'a pas de sens. `needsLocalEngine` tient déjà compte du mode.
        EngineService.reconcile(needed: Preferences.shared.needsLocalEngine)
    }
}
