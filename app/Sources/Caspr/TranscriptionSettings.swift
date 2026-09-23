import SwiftUI

/// Comment Caspr transcrit : par ChatGPT, ou par macOS.
///
/// Cette vue ne contient plus rien d'elle-même, et c'est l'aboutissement de ce
/// qu'elle poursuivait déjà. Elle est née de la fusion de deux implémentations
/// — l'accueil et les Réglages posaient les mêmes questions dans deux fichiers
/// distincts, et avaient divergé en silence. Chaque question vit désormais
/// dans une vue autonome qui porte sa propre logique système et sa propre
/// validité, et l'accueil instancie les mêmes.
///
/// **La langue ne se change pas ici.** Le sélecteur y était aussi, en double
/// avec l'onglet Général — deux endroits pour un seul réglage, donc deux
/// endroits à tenir d'accord. Cet onglet choisit qui écrit, celui-là la
/// langue.
struct TranscriptionSettings: View {
    var body: some View {
        // RELAIS — la carte enveloppe celle de macOS, dont elle décide
        // l'affichage : les deux s'excluent à l'écran comme en fonctionnement.
        RelaisCard { AppleEngineCard() }
    }
}
