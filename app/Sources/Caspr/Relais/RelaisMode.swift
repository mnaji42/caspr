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
    /// La transcription est renvoyée à ChatGPT pour être remise en ordre.
    case reorganiser
    /// La parole est la commande d'un texte à produire. Pas encore construit.
    case rediger

    var libelle: String {
        switch self {
        case .brut: "Brut"
        case .reorganiser: "Réorganiser"
        case .rediger: "Rédiger"
        }
    }

    /// Vrai quand le texte doit repartir dans la conversation.
    var demandeUnAllerRetour: Bool { self != .brut }

    // MARK: - Persistance

    private static let cle = "relais.mode"

    static var courant: RelaisMode {
        get {
            let brut = UserDefaults.standard.string(forKey: cle) ?? ""
            // Les anciens noms sont traduits plutôt qu'ignorés. Un `rawValue`
            // qui change et un repli silencieux sur `.brut`, c'est le réglage
            // de l'utilisateur qui disparaît à la mise à jour — la même faute
            // que celle qui a effacé les calibrages en 0.13.0, sous une autre
            // forme.
            switch brut {
            case "auPropre": return .reorganiser
            case "consigne": return .rediger
            default: return RelaisMode(rawValue: brut) ?? .brut
            }
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cle) }
    }

    /// Les modes réellement proposés.
    ///
    /// `rediger` en est absent tant qu'il n'est pas construit : afficher un
    /// choix qui ne fait rien est pire que de ne pas le proposer.
    static var proposes: [RelaisMode] { [.brut, .reorganiser] }
}

/// Ce qu'on montre de la page ChatGPT pendant qu'elle travaille.
///
/// Trois niveaux, parce que trois usages. Rien, pour qui veut juste dicter et
/// à qui la mécanique est indifférente. La barre, pour voir que ça écoute et
/// que ça transcrit. La page entière, pour comprendre ce qui se passe quand
/// quelque chose cloche — c'est le seul mode qui rende un défaut
/// diagnosticable sans lire un journal.
///
/// Quelle que soit la taille, la fenêtre ne prend **jamais** le clavier
/// pendant une dictée : c'est la fenêtre de la barre qu'on agrandit, pas celle
/// des réglages. Une fenêtre capable de devenir clé ferait écrire la dictée
/// dans la page au lieu de l'éditeur.
enum RelaisAffichage: String, CaseIterable, Codable {
    case rien, barre, page

    /// Un mot par pastille : le composant tient sur une ligne de réglages, à
    /// côté de son libellé, et trois phrases n'y entreraient pas. Ce que chaque
    /// choix implique se lit en dessous, pour celui qui est retenu.
    var libelleCourt: String {
        switch self {
        case .rien: "Rien"
        case .barre: "Barre"
        case .page: "Page"
        }
    }

    var explication: String {
        switch self {
        case .rien:
            "ChatGPT travaille hors champ : seule la barre de Caspr est visible."
        case .barre:
            "Une bande fine au-dessus de la barre de Caspr, où l'on voit ChatGPT "
            + "écouter puis transcrire."
        case .page:
            "La page en grand, le temps de la dictée — pour voir le texte envoyé, "
            + "la réponse, ou une erreur."
        }
    }

    private static let cle = "relais.affichage"

    static var courant: RelaisAffichage {
        get { RelaisAffichage(rawValue: UserDefaults.standard.string(forKey: cle) ?? "")
              ?? .barre }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cle) }
    }
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
    static let reorganiser = """
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

    /// Rendre le texte à écrire, quelle que soit la façon de le demander.
    ///
    /// Tout l'enjeu de ce mode tient dans cette consigne, et la difficulté est
    /// qu'on ne peut rien supposer de la formulation. « Réponds-lui que je
    /// serai présent », « j'ai envie que tu me traduises ça en anglais »,
    /// « regarde le mail et fais un refus poli » : ce sont trois grammaires
    /// différentes — un ordre adressé au modèle, un souhait, une description —
    /// et elles attendent toutes la même chose, un texte prêt à coller.
    ///
    /// Deux interdits comptent plus que le reste.
    ///
    /// **Ne pas répondre à la personne.** « Quel temps fera-t-il demain » doit
    /// produire le texte qu'elle veut écrire, pas une conversation. C'est la
    /// différence entre un outil d'écriture et un chatbot, et c'est elle qui
    /// justifie ce mode.
    ///
    /// **Ne jamais demander de précision.** Il n'y a pas de dialogue possible :
    /// une question du modèle atterrirait telle quelle dans le mail de
    /// l'utilisateur. Devant une ambiguïté, il tranche et écrit quand même.
    static let rediger = """
        Contexte : la personne dicte à la voix dans un outil qui écrit \
        directement à l'endroit où elle travaille — un e-mail, un document, une \
        note. Ce que tu produis sera collé tel quel, sans relecture ni \
        retouche.

        Le texte ci-dessus est cette dictée. Sa formulation est libre : ce peut \
        être un ordre qui t'est adressé (« réponds-lui que… »), un souhait \
        (« j'aimerais un mot poli pour… »), une description du texte voulu, ou \
        un mélange des trois. La forme ne change rien à l'attente : dans tous \
        les cas, on veut **le texte à écrire**, jamais une réponse qui te serait \
        adressée en retour.

        Règles :
        — Rends uniquement ce texte. Pas d'introduction, pas de commentaire, \
        pas de guillemets autour, pas de blocs de code.
        — Ne réponds jamais à la personne. Si la dictée ressemble à une \
        question, écris le texte qu'elle veut poser ou publier, pas la réponse \
        à cette question.
        — Ne demande jamais de précision : rien ne te sera répondu, et ta \
        question serait collée telle quelle. Devant une ambiguïté, tranche au \
        plus vraisemblable et écris.
        — La dictée peut contenir des hésitations, des reprises et des \
        corrections. Suis la dernière intention exprimée, pas la première.
        — Écris dans la langue demandée ; à défaut, dans celle de la dictée.
        — Respecte le ton, le destinataire et la longueur indiqués, s'ils le \
        sont.
        """

    /// Ce qu'on ajoute **autour** du texte déjà présent.
    ///
    /// Un délimiteur en toutes lettres plutôt que des accents graves : dans un
    /// éditeur ProseMirror, trois accents graves déclenchent la création d'un
    /// bloc de code, qui capture ensuite la touche d'envoi. Le but — dire sans
    /// ambiguïté où commence et où finit la matière — est atteint aussi bien.
    static func encadrement(_ mode: RelaisMode) -> (avant: String, apres: String) {
        switch mode {
        case .brut:
            ("", "")
        case .reorganiser:
            (reorganiser + "\n\n=== DÉBUT DE LA TRANSCRIPTION ===\n",
             "\n=== FIN DE LA TRANSCRIPTION ===")
        case .rediger:
            ("=== DÉBUT DE LA DEMANDE ===\n",
             "\n=== FIN DE LA DEMANDE ===\n\n" + rediger)
        }
    }

    /// Le message complet à déposer dans la zone de saisie.
    ///
    /// L'emballage vient **avant** le texte pour `reorganiser` : la consigne doit
    /// être lue avant la matière, sans quoi un long monologue la noie. Il vient
    /// **après** pour `rediger`, où le texte est l'instruction et où le rappel
    /// de format se place naturellement en dernier.
    static func envelopper(_ dicte: String, mode: RelaisMode) -> String {
        switch mode {
        case .brut: dicte
        case .reorganiser: reorganiser + "\n\n---\n\n" + dicte
        case .rediger: dicte + "\n\n---\n\n" + rediger
        }
    }
}
