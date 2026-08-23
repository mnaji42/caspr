import Foundation

/// Ce que ChatGPT fait de ce qu'on vient de dire.
///
/// Trois modes, et ce qui les sépare n'est pas la quantité de traitement mais
/// **le rôle que joue la parole**. Dans `brut` elle est le texte lui-même ;
/// dans `auPropre` elle est la matière à remettre en ordre ; dans `consigne`
/// elle est l'instruction à exécuter. Confondre les deux derniers ferait
/// réorganiser une demande au lieu de l'honorer.
enum RelaisMode: String, CaseIterable, Codable {
    /// La transcription, telle quelle. Rien n'est envoyé à ChatGPT.
    case brut
    /// La transcription est renvoyée à ChatGPT pour être réorganisée.
    case auPropre
    /// La transcription est une instruction. Réservé au mode avec capture
    /// d'écran, pas encore construit.
    case consigne

    var libelle: String {
        switch self {
        case .brut: "Brut"
        case .auPropre: "Au propre"
        case .consigne: "Consigne"
        }
    }

    /// Vrai quand le texte doit repartir dans la conversation.
    var demandeUnAllerRetour: Bool { self != .brut }

    // MARK: - Persistance

    private static let cle = "relais.mode"

    static var courant: RelaisMode {
        get { RelaisMode(rawValue: UserDefaults.standard.string(forKey: cle) ?? "") ?? .brut }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cle) }
    }

    /// Les modes réellement proposés.
    ///
    /// `consigne` en est absent tant que la capture d'écran n'existe pas :
    /// afficher un choix qui ne fait rien est pire que de ne pas le proposer.
    static var proposes: [RelaisMode] { [.brut, .auPropre] }
}

/// L'emballage que Caspr ajoute autour de ce qui a été dicté.
///
/// La consigne, elle, se **dit** — « traduis ça en anglais », « réponds-lui
/// cordialement ». Elle ne se configure pas : un réglage figé ne peut pas
/// suivre ce qu'on veut faire d'une phrase à l'autre. Ce qui se configure ici
/// n'est que l'emballage, dont le seul rôle est d'obtenir un résultat
/// utilisable — sans « Bien sûr ! Voici… » devant.
enum RelaisPrompt {
    /// Réorganiser, sans résumer.
    ///
    /// La distinction est le cœur du mode et elle est dite trois fois dans la
    /// consigne, parce que les modèles condensent spontanément : quelqu'un qui
    /// tourne autour d'une idée pendant dix minutes veut la retrouver
    /// entière et lisible, pas en trois lignes. Ce qui disparaît, ce sont les
    /// hésitations et les redites — jamais le contenu.
    static let auPropre = """
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

    /// Exécuter ce qui est demandé, et rien d'autre.
    static let consigne = """
        Réponds uniquement par le résultat demandé, sans introduction, sans \
        commentaire, sans guillemets autour et sans répéter la question.
        """

    /// Le message complet à déposer dans la zone de saisie.
    ///
    /// L'emballage vient **avant** le texte pour `auPropre` : la consigne doit
    /// être lue avant la matière, sans quoi un long monologue la noie. Il vient
    /// **après** pour `consigne`, où le texte est l'instruction et où le rappel
    /// de format se place naturellement en dernier.
    static func envelopper(_ dicte: String, mode: RelaisMode) -> String {
        switch mode {
        case .brut: dicte
        case .auPropre: auPropre + "\n\n---\n\n" + dicte
        case .consigne: dicte + "\n\n---\n\n" + consigne
        }
    }
}
