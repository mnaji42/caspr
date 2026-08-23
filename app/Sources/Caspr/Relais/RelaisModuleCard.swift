import SwiftUI

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
    let surChangement: () -> Void

    @State private var deplie = false
    @State private var avant = ""
    @State private var apres = ""
    @State private var avecConsigne = false

    private var manquantes: [RelaisCapacite] { module.capacitesManquantes(selecteurs) }

    var body: some View {
        Card {
            entete
            recette
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
            // Rien à déplier pour un module qui n'envoie rien : son seul
            // réglage est l'affichage, et il est déjà dans l'en-tête. Un bouton
            // qui ouvre un panneau vide se lit comme une promesse non tenue.
            if module.demandeUnAllerRetour {
                Divider().opacity(0.25)
                bascule
                if deplie { consigne }
            }
        }
    }

    // MARK: - Ce que le module fait

    /// Son nom, et à droite ce qu'il montre pendant qu'il travaille.
    ///
    /// L'affichage est ici plutôt que dans un panneau à déplier : c'est le seul
    /// réglage que tout module possède, et le seul qu'on change souvent.
    private var entete: some View {
        HStack(spacing: 12) {
            Text(module.nom).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            PillPicker(options: RelaisAffichage.allCases.map { ($0, $0.libelleCourt) },
                       selection: Binding(
                           get: { module.affichageEffectif },
                           set: { choisi in
                               var maj = module
                               maj.affichage = choisi
                               RelaisCatalogue.remplacer(maj)
                               surChangement()
                           }),
                       // Grisé quand le module impose son affichage : laisser
                       // choisir une valeur sans effet est pire que ne pas la
                       // proposer.
                       disabled: module.affichageImpose != nil)
        }
    }

    /// Ce qui se passe, dans l'ordre, jusqu'à la destination.
    ///
    /// Les étapes déduites y figurent aussi — « Récupérer la réponse »
    /// n'est cochée nulle part, elle découle de la destination. La cacher
    /// laisserait croire que le module fait moins qu'il ne fait.
    private var recette: some View {
        FlowLayout(spacing: 6) {
            jeton("Dicter", ton: .socle)
            ForEach(module.etapes, id: \.rawValue) { etape in
                jeton(etape == .demanderUneReponse && !module.avant.isEmpty
                      ? etape.libelle + " (avec consigne)"
                      : etape.libelle,
                      ton: .etape)
            }
            if module.sorties.contains(where: \.demandeLaReponse) {
                jeton("Récupérer la réponse", ton: .deduite)
            }
            jeton("→ " + module.sorties.map(\.libelle).joined(separator: " ou "),
                  ton: .sortie)
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

    private var bascule: some View {
        Button {
            if !deplie {
                avant = module.avant
                apres = module.apres
                avecConsigne = module.consigneEssentielle || !avant.isEmpty || !apres.isEmpty
            }
            withAnimation(.easeOut(duration: 0.18)) { deplie.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.quote").font(.system(size: 12))
                Text(deplie ? "Masquer la consigne" : "Modifier la consigne…")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Text(module.avant.isEmpty ? "aucune" : "personnalisée")
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
    private var consigne: some View {
        // Une case plutôt que deux champs toujours ouverts : la plupart des
        // modules n'ont pas de consigne, et deux zones de texte vides occupent
        // l'écran sans rien dire.
        if !module.consigneEssentielle {
            OptionCheck(title: "Ajouter une consigne autour de ce qui est dicté",
                        isOn: Binding(get: { avecConsigne },
                                      set: { actif in
                                          avecConsigne = actif
                                          if !actif { avant = ""; apres = "" }
                                      }))
        }
        if avecConsigne || module.consigneEssentielle {
            Note("Le texte dicté est glissé entre ces deux blocs.")
            champ("Avant", texte: $avant)
            champ("Après", texte: $apres)
        }
        ButtonRow {
            Button("Enregistrer") {
                var maj = module
                maj.avant = avant
                maj.apres = apres
                RelaisCatalogue.remplacer(maj)
                surChangement()
            }
            .disabled(avant == module.avant && apres == module.apres)
            if module.integre {
                Button("Revenir à l'origine") {
                    guard let origine = RelaisCatalogue.livres
                        .first(where: { $0.identifiant == module.identifiant })
                    else { return }
                    avant = origine.avant
                    apres = origine.apres
                    avecConsigne = !avant.isEmpty || !apres.isEmpty
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
