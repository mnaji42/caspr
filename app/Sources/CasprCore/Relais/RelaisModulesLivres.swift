import Foundation

/// Les modules livrés avec l'application, et celui qui est retenu.
///
/// Ce ne sont que des modules pré-remplis. Rien ne les distingue de ceux que
/// l'utilisateur écrira, sinon qu'ils existent au premier lancement — ce qui
/// permet de dicter sans avoir rien à configurer.
public enum RelaisCatalogue {
    public static let brut = RelaisModule(
        identifiant: "brut", nom: "Brut", integre: true,
        consigne: .aucune, lectureProposee: false,
        actions: [],
        sorties: [.curseur, .note], sortieParDefaut: .curseur,
        affichage: .barre)

    public static let reorganiser = RelaisModule(
        identifiant: "reorganiser", nom: "Réorganiser", integre: true,
        avant: RelaisPrompt.reorganiser + "\n\n=== DÉBUT DE LA TRANSCRIPTION ===\n",
        apres: "\n=== FIN DE LA TRANSCRIPTION ===",
        consigne: .essentielle, lectureProposee: false,
        actions: [.demanderUneReponse],
        sorties: [.curseur, .note], sortieParDefaut: .curseur,
        affichage: .barre)

    /// Poser une question, et rester dans la conversation.
    ///
    /// Le premier module dont la sortie n'écrit nulle part, et c'est ce qui le
    /// distingue : rien n'est inséré, la page reste ouverte et prend le
    /// clavier, et la touche de dictée relance une dictée **dans le même fil**
    /// au lieu d'ouvrir une conversation neuve. Fermer et rouvrir détruirait
    /// justement ce qu'on veut garder.
    ///
    /// Aucune consigne : ce qui est dit part tel quel. En ajouter une le
    /// rapprocherait d'un module de rédaction, qui est un autre besoin.
    public static let discuter = RelaisModule(
        identifiant: "discuter", nom: "Discuter", integre: true,
        consigne: .aucune,
        actions: [.demanderUneReponse],
        sorties: [.aucune], sortieParDefaut: .aucune,
        affichage: .page)
}

/// L'emballage que Caspr ajoute autour de ce qui a été dicté.
///
/// La consigne, elle, se **dit** — « traduis ça en anglais », « réponds-lui
/// cordialement ». Elle ne se configure pas : un réglage figé ne peut pas
/// suivre ce qu'on veut faire d'une phrase à l'autre. Ce qui se configure ici
/// n'est que l'emballage, dont le seul rôle est d'obtenir un résultat
/// utilisable — sans « Bien sûr ! Voici… » devant.
public enum RelaisPrompt {
    /// Réorganiser, sans résumer.
    ///
    /// La distinction est le cœur du mode et elle est dite trois fois dans la
    /// consigne, parce que les modèles condensent spontanément : quelqu'un qui
    /// tourne autour d'une idée pendant dix minutes veut la retrouver
    /// entière et lisible, pas en trois lignes. Ce qui disparaît, ce sont les
    /// hésitations et les redites — jamais le contenu.
    public static let reorganiser = """
        Voici la transcription d'une personne qui réfléchit à voix haute.

        Réorganise-la en un texte clair et lisible :
        — garde toutes les idées, sans exception ;
        — supprime les hésitations, les redites et les faux départs ;
        — remets dans l'ordre ce qui a été dit dans le désordre, et regroupe ce \
        qui va ensemble ;
        — structure en paragraphes, en sections ou en liste à puces si le propos \
        s'y prête ;
        — garde la langue, le ton et le niveau de langue d'origine.

        Ne résume pas. Ne raccourcis pas au-delà de ce que la suppression des \
        redites impose. N'ajoute aucune idée qui ne soit pas dans la \
        transcription.

        Réponds uniquement par le texte réorganisé, sans introduction, sans \
        commentaire et sans guillemets autour.
        """
}
