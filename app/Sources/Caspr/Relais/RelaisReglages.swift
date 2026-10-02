import SwiftUI
import CasprCore

/// Les réglages de la voie ChatGPT, sous sa ligne dans `CarteVoie`.
///
/// La session, ce que Caspr a appris de la page, les modules, puis le point de
/// départ des conversations. Rien ici ne choisit la voie : c'est `CarteVoie`
/// qui la tient, et cette vue n'existe que lorsqu'elle est retenue. Tant que la
/// voie est macOS, la page n'existe pas (cf. `Relais.pageActive`) — des
/// boutons qui la pilotent n'auraient rien à piloter.
struct RelaisReglages: View {
    @ObservedObject private var magasin = RelaisMagasin.partage

    var body: some View {
        // Une carte pour la session et ce que Caspr a appris, puis une carte
        // par module. Les étapes numérotées ont disparu : elles suggéraient un
        // escalier, alors que les capacités sont indépendantes — un module
        // peut exiger d'envoyer sans jamais récupérer, donc moins qu'un autre
        // qui venait pourtant avant lui.
        RelaisSession()

        SectionLabel("Modules")
        ForEach(magasin.modules) { module in
            RelaisModuleCard(module: module, selecteurs: magasin.selecteurs)
        }

        let depart = magasin.depart != RelaisPage.accueil
        if depart || magasin.modules.contains(where: { $0.envoi != .aucun }) {
            SectionLabel("Point de départ")
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
                    Button("Adopter la page ouverte…") { Relais.partage.adopterPageDeDepart() }
                    if depart {
                        Button("Revenir à l'accueil") { Relais.partage.oublierPageDeDepart() }
                    }
                }
            }
        }
    }
}

/// La session ChatGPT et ce que Caspr a appris de la page : ce que la voie
/// exige avant de dicter.
///
/// La même carte dans Réglages › Voie et dans l'accueil. Les deux posaient la
/// même question, et une seconde version aurait fini par dire autre chose —
/// l'accueil a déjà payé ce genre de divergence (cf. `OnboardingView`).
struct RelaisSession: View, ValidatingComponent {
    @ObservedObject private var relais = Relais.partage
    /// Une calibration se termine souvent ailleurs que dans cette vue —
    /// lancée à la bascule de voie, finie depuis l'accueil, abandonnée en
    /// fermant la fenêtre : la carte suit le magasin, sans relecture (162).
    @ObservedObject private var magasin = RelaisMagasin.partage

    /// Ce qui manque pour dicter par ChatGPT, lu comme `Relais.saitDicter` :
    /// une session que la page n'a pas vue perdue, et un calibrage.
    static func validate() -> ComponentValidationError? {
        if Relais.partage.sessionVue == .deconnecte { return .chatgptSignedOut }
        return Relais.partage.estCalibre ? nil : .chatgptNotCalibrated
    }

    var body: some View {
        Card {
            connexion
            Divider().opacity(0.25)
            if !magasin.selecteurs.estCalibre {
                Note("Configuration inachevée : la dictée ne partira pas tant que "
                     + "Caspr n'aura pas appris les boutons de la page — seul, ou "
                     + "en vous les faisant montrer.",
                     warning: true)
            }
            capacites
            // Grisés pendant qu'un autre flux pilote la page. Un bouton qu'on
            // peut cliquer et qui refusera ensuite vaut moins qu'un bouton qui
            // dit d'emblée que ce n'est pas le moment.
            //
            // L'automatique d'abord, la main ensuite, et les deux toujours là :
            // le parcours manuel est le repli d'une page que l'automate ne
            // sait pas lire, et ce jour-là il ne doit pas falloir le chercher.
            VStack(alignment: .leading, spacing: 8) {
                ButtonRow {
                    Button("Calibrer automatiquement…") { Relais.partage.calibrerAutomatiquement() }
                    Button("Montrer à la main…") { Relais.partage.calibrerALaMain() }
                }
                ButtonRow {
                    Button("Ouvrir la fenêtre…") { Relais.partage.ouvrirFenetre() }
                    Button("Diagnostic…") { Relais.partage.diagnostic() }
                    // Pas devant une session déjà perdue : il n'y a plus rien à
                    // effacer, et c'est « Se connecter… » qu'on cherche alors.
                    if relais.sessionVue != .deconnecte {
                        Button("Se déconnecter…") { deconnecter() }
                    }
                }
            }
            .disabled(empechement != nil)
            if let raison = empechement {
                Note(raison + " Les réglages de la page attendent qu'elle se termine.",
                     warning: true)
            }
        }
    }

    // MARK: - La session

    /// La session ChatGPT, telle que la page l'a montrée en dernier.
    ///
    /// C'est la dernière chose **vue** (cf. `Relais.sessionVue`), pas une
    /// mesure prise ici : l'interroger demande la page, et pas sans attendre.
    /// La page se remesure à chaque chargement — au lancement, après chaque
    /// dictée, à chaque ouverture de sa fenêtre.
    @ViewBuilder
    private var connexion: some View {
        switch relais.sessionVue {
        case .connecte:
            GrantedLine("Connecté à ChatGPT")
        case .deconnecte:
            Note("**Pas connecté à ChatGPT.** Les dictées sont refusées tant que "
                 + "vous ne vous êtes pas connecté, dans la fenêtre du relais. "
                 + "Un calibrage déjà fait est conservé.", warning: true)
            ButtonRow {
                Button("Se connecter…") { Relais.partage.ouvrirFenetre() }
            }
            .disabled(empechement != nil)
        case .inconnu:
            Note("La page n'a pas encore dit si vous êtes connecté : elle le dira "
                 + "à son prochain chargement, ou à l'ouverture de sa fenêtre.")
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

    // MARK: - Ce que Caspr a appris

    /// Ce que Caspr a appris de la page — et ce qui lui manque encore.
    ///
    /// Les capacités sont montrées telles quelles, sans être rangées en étapes :
    /// elles ne se conditionnent pas les unes les autres, et les numéroter
    /// laissait croire le contraire. Chaque module dit ensuite lesquelles il
    /// exige, ce qui est la seule dépendance réelle.
    private var capacites: some View {
        FlowLayout(spacing: 6) {
            ForEach(RelaisCapacite.allCases, id: \.rawValue) { capacite in
                let acquise = capacite.estAcquise(magasin.selecteurs)
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

    /// Ce qui interdit de toucher à la page maintenant, s'il y a quelque
    /// chose : un flux qui la pilote, ou une dictée macOS qui garde le micro
    /// et devant laquelle la page ne doit pas naître (cf.
    /// `Relais.ecouteMacOS`).
    private var empechement: String? {
        if let raison = relais.occupation.raison { return raison }
        return relais.ecouteMacOS ? "Une dictée macOS est en cours." : nil
    }
}
