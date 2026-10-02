import SwiftUI
import CasprCore

/// Un module, tel qu'on le lit et le règle.
///
/// La carte dit d'abord **ce que le module fait** — ses étapes dans l'ordre du
/// chemin, puis où atterrit le résultat. C'est ce qui manquait : on voyait des
/// boutons de calibration sans jamais voir ce qu'un module était censé faire,
/// et il fallait se souvenir de la différence entre « Brut » et « Réorganiser »
/// au lieu de la lire.
///
/// Le reste ne se déplie qu'à la demande. Un module se règle rarement ; le lire
/// doit rester immédiat.
struct RelaisModuleCard: View {
    let module: RelaisModule
    let selecteurs: RelaisSelecteurs
    /// Le module qu'on crée, tant qu'il n'est pas créé : la carte s'ouvre
    /// sur ses réglages, et rien n'est rangé avant « Créer ». Rangé dès le
    /// clic sur « Nouveau module… », il rejoignait la barre avant d'avoir un
    /// nom ou une consigne, et choisi par mégarde il envoyait la dictée brute
    /// à ChatGPT pour en écrire la réponse.
    var brouillon: Binding<RelaisModule?>?

    @State private var deplie = false
    @State private var avant = ""
    @State private var apres = ""
    @State private var avecConsigne = false
    @State private var nom = ""

    private var manquantes: [RelaisCapacite] { module.capacitesManquantes(selecteurs) }

    var body: some View {
        Card {
            entete
            recette
            // Offerte par le module, et seulement s'il l'offre : la lecture à
            // haute voix marche partout, mais les trois modules livrés restent
            // simples. La case n'apparaît de toute façon que si Caspr sait le
            // faire.
            if module.lectureProposee,
               RelaisCapacite.direAHauteVoix.estAcquise(selecteurs) {
                OptionCheck(title: "Faire lire la réponse à haute voix par ChatGPT",
                            isOn: reglage(\.ditLaReponse))
            }
            if module.affichageImpose != nil {
                Note("La réponse n'existe qu'à l'écran : ce module l'affiche en grand, "
                     + "et ce choix ne se règle pas. Il se libérera le jour où le module "
                     + "fera lire la réponse à haute voix — on peut écouter sans regarder.")
            }
            if !manquantes.isEmpty {
                Note("Indisponible : il manque « "
                     + manquantes.map(\.libelle).joined(separator: " », « ")
                     + " ». Lancez la calibration ci-dessus.", warning: true)
            }
            // Pas de panneau pour un module sans consigne, Brut ou Discuter :
            // leur seul réglage, l'affichage, est déjà dans l'en-tête, et un
            // bouton qui ouvre sur du vide se lit comme une promesse non tenue.
            if module.consigne != .aucune {
                Divider().opacity(0.25)
                if brouillon == nil { bascule }
                if deplie || brouillon != nil { reglages }
            }
        }
        .onAppear { if brouillon != nil { charger() } }
    }

    /// Ce qui se règle d'un geste, sans « Enregistrer » : sur le module rangé,
    /// ou sur le brouillon.
    private func changer(_ module: RelaisModule) {
        if let brouillon { brouillon.wrappedValue = module } else { RelaisMagasin.partage.remplacer(module) }
    }

    private func reglage<V>(_ chemin: WritableKeyPath<RelaisModule, V>) -> Binding<V> {
        Binding(get: { module[keyPath: chemin] },
                set: { valeur in
                    var maj = module
                    maj[keyPath: chemin] = valeur
                    changer(maj)
                })
    }

    // MARK: - Ce que le module fait

    /// Son nom, et à droite ce qu'il montre pendant qu'il travaille.
    ///
    /// L'affichage est ici plutôt que dans un panneau à déplier : c'est le seul
    /// réglage que tout module possède, et le seul qu'on change souvent.
    private var entete: some View {
        HStack(spacing: 12) {
            Text(module.nom.isEmpty ? "Nouveau module" : module.nom)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            PillPicker(options: RelaisAffichage.allCases.map { ($0, $0.libelleCourt) },
                       selection: Binding(get: { module.affichageEffectif },
                                          set: { reglage(\.affichage).wrappedValue = $0 }),
                       // Grisé quand le module impose son affichage : laisser
                       // choisir une valeur sans effet est pire que ne pas la
                       // proposer.
                       disabled: module.affichageImpose != nil)
        }
    }

    /// Ce qui se passe, dans l'ordre du chemin, jusqu'à la destination — lu
    /// de l'envoi, la seule chose qui distingue un module d'un autre.
    ///
    /// « Récupérer la réponse » n'est cochée nulle part, elle découle de
    /// l'envoi. La cacher laisserait croire que le module fait moins qu'il ne
    /// fait.
    private var recette: some View {
        FlowLayout(spacing: 6) {
            jeton("Dicter", ton: .socle)
            if module.envoi != .aucun {
                jeton(module.avant.isEmpty && module.apres.isEmpty
                      ? "Envoyer à ChatGPT" : "Envoyer à ChatGPT (avec consigne)", ton: .etape)
            }
            if module.envoi == .remplacer { jeton("Récupérer la réponse", ton: .deduite) }
            if module.ditLaReponse { jeton("Faire lire la réponse", ton: .etape) }
            jeton(module.ecrit ? "→ Curseur ou Notes…" : "→ Réponse à l'écran", ton: .sortie)
        }
    }

    private enum Ton { case socle, etape, deduite, sortie }

    private func jeton(_ texte: String, ton: Ton) -> some View {
        Text(texte)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ton == .sortie ? Style.accent
                             : ton == .etape ? Style.textPrimary : Style.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Capsule().fill(ton == .sortie ? Style.accent.opacity(0.12)
                                              : Color.primary.opacity(0.06)))
    }

    // MARK: - La consigne

    /// On crée un module pour encadrer ce qu'on dit — traduire, reformuler :
    /// le brouillon s'ouvre sur sa consigne.
    private func charger() {
        (avant, apres, nom) = (module.avant, module.apres, module.nom)
        avecConsigne = module.consigne == .essentielle || !avant.isEmpty || !apres.isEmpty
            || brouillon != nil
    }

    /// Le module tel que le panneau le règle. Un livré ne change que sa
    /// consigne : son nom suit les versions (cf. `avecLesReglagesDe`).
    private var regle: RelaisModule {
        var m = module
        (m.avant, m.apres) = (avant, apres)
        if !module.integre { m.nom = nom.trimmingCharacters(in: .whitespacesAndNewlines) }
        return m
    }

    private var bascule: some View {
        Button {
            if !deplie { charger() }
            withAnimation(.easeOut(duration: 0.18)) { deplie.toggle() }
        } label: {
            HStack(spacing: 8) {
                let quoi = module.integre ? "la consigne" : "le module"
                Image(systemName: "text.quote").font(.system(size: 12))
                Text(deplie ? "Masquer \(quoi)" : "Modifier \(quoi)…")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Text(module.avant.isEmpty && module.apres.isEmpty ? "aucune" : "personnalisée")
                    .font(.system(size: 11))
                    .foregroundStyle(Style.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(deplie ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
    }

    @ViewBuilder
    private var reglages: some View {
        if !module.integre {
            Row(label: "Nom") {
                TextField("", text: $nom).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            // Appliqué aussitôt, comme l'affichage : la recette, l'affichage
            // imposé et la consigne en dépendent, et doivent le suivre.
            Row(label: "Ce qu'il écrit") {
                PillPicker(options: RelaisEnvoi.allCases.map { ($0, $0.libelle) },
                           selection: reglage(\.envoi))
            }
        }
        // Une case plutôt que deux champs toujours ouverts : la plupart des
        // modules n'ont pas de consigne, et deux zones de texte vides occupent
        // l'écran sans rien dire. Rien à encadrer pour qui n'envoie rien.
        if module.consigne == .facultative, module.envoi != .aucun {
            OptionCheck(title: "Ajouter une consigne autour de ce qui est dicté",
                        isOn: Binding(get: { avecConsigne },
                                      set: { actif in
                                          avecConsigne = actif
                                          if !actif { avant = ""; apres = "" }
                                      }))
        }
        if (avecConsigne && module.envoi != .aucun) || module.consigne == .essentielle {
            Note("Le texte dicté est glissé entre ces deux blocs.")
            champ("Avant", texte: $avant)
            champ("Après", texte: $apres)
        }
        ButtonRow {
            if let brouillon {
                // Un nom d'abord : c'est par lui qu'on le choisit sur la barre.
                Button("Créer") {
                    RelaisMagasin.partage.ajouter(regle)
                    brouillon.wrappedValue = nil
                }
                .disabled(regle.nom.isEmpty)
                Button("Annuler") { brouillon.wrappedValue = nil }
            } else {
                Button("Enregistrer") { RelaisMagasin.partage.remplacer(regle) }
                    .disabled(regle == module || regle.nom.isEmpty)
                if module.integre {
                    Button("Revenir à l'origine") {
                        guard let origine = RelaisCatalogue.livres
                            .first(where: { $0.identifiant == module.identifiant })
                        else { return }
                        (avant, apres) = (origine.avant, origine.apres)
                        avecConsigne = !avant.isEmpty || !apres.isEmpty
                    }
                } else {
                    Button("Supprimer…") {
                        if RelaisDialogues.choisir("Supprimer « \(module.nom) » ?",
                                                   "Sa consigne et ses réglages seront perdus.",
                                                   ["Supprimer", "Annuler"]) == 0 {
                            RelaisMagasin.partage.supprimer(module)
                        }
                    }
                }
            }
        }
    }

    private func champ(_ titre: String, texte: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(titre)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Style.textSecondary)
            TextEditor(text: texte)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 72, maxHeight: 160)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}
