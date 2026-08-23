import SwiftUI

/// Comment Caspr transcrit : la langue, puis le moteur.
///
/// Cette vue ne contient plus rien d'elle-même, et c'est l'aboutissement de ce
/// qu'elle poursuivait déjà. Elle est née de la fusion de deux implémentations
/// — l'accueil et les Réglages posaient les mêmes questions dans deux fichiers
/// distincts, et avaient divergé en silence : le mode et le vocabulaire
/// n'existaient que dans les Réglages, le choix du modèle que dans l'accueil,
/// la langue nulle part dans l'accueil.
///
/// Aucun de ces écarts n'était une décision. Ils sont la conséquence mécanique
/// de deux copies : on ajoute une fonctionnalité là où on travaille, et elle
/// manque ailleurs sans que rien ne le signale.
///
/// Le découpage en composants va au bout de la même idée : chaque question vit
/// dans une vue autonome qui porte sa propre logique système et sa propre
/// validité.
///
/// **La langue ne se change pas ici.** Le sélecteur y était aussi, en double
/// avec l'onglet Général — deux endroits pour un seul réglage, donc deux
/// endroits à tenir d'accord, et la question « laquelle des deux fait foi »
/// posée à qui les voit. Le prototype ne la propose que dans Général ; cet
/// onglet choisit le moteur, celui-là choisit la langue.
struct TranscriptionSettings: View {
    var body: some View {
        // RELAIS — la carte enveloppe la liste des moteurs, dont elle décide
        // l'affichage : les deux s'excluent à l'écran comme en fonctionnement.
        // Retrait : remplacer cette ligne par `FinalEngineCard()`.
        RelaisCard { FinalEngineCard() }
        // Le même constat qu'ailleurs, à l'endroit où on le provoque : changer
        // de moteur, arrêter le service ou retirer des poids fait basculer la
        // dictée sur autre chose que ce qui est coché, et c'est ici que ça se
        // fait. Le bandeau n'existait que sous le sélecteur de langue.
        //
        // **Sous** les deux cartes, et non au-dessus : il rend compte du geste
        // qu'on vient de faire dessus. Posé en tête de page, il repoussait les
        // cartes vers le bas au moment même où on venait d'y cliquer.
        EngineNoticeBanner()
    }
}
