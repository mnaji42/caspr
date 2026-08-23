import Foundation

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

}

/// Les modules livrés avec l'application, et celui qui est retenu.
///
/// Ce ne sont que des modules pré-remplis. Rien ne les distingue de ceux que
/// l'utilisateur écrira, sinon qu'ils existent au premier lancement — ce qui
/// permet de dicter sans avoir rien à configurer.
enum RelaisCatalogue {
    static let brut = RelaisModule(
        identifiant: "brut", nom: "Brut", integre: true,
        actions: [],
        sorties: [.curseur, .note], sortieParDefaut: .curseur,
        affichage: .barre)

    static let reorganiser = RelaisModule(
        identifiant: "reorganiser", nom: "Réorganiser", integre: true,
        avant: RelaisPrompt.reorganiser + "\n\n=== DÉBUT DE LA TRANSCRIPTION ===\n",
        apres: "\n=== FIN DE LA TRANSCRIPTION ===",
        consigneEssentielle: true,
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
    static let discuter = RelaisModule(
        identifiant: "discuter", nom: "Discuter", integre: true,
        actions: [.demanderUneReponse],
        sorties: [.aucune], sortieParDefaut: .aucune,
        affichage: .page)

    /// Ceux que l'application livre.
    static var livres: [RelaisModule] {
        // L'affichage était un réglage unique pour toute la fonctionnalité ; il
        // appartient maintenant à chaque module. Le sien est repris comme
        // valeur de départ des modules livrés, plutôt que de le laisser
        // retomber au défaut d'usine : un réglage qu'on a pris la peine de
        // faire ne disparaît pas parce que le code a changé d'avis sur l'endroit
        // où le ranger.
        let ancien = UserDefaults.standard.string(forKey: "relais.affichage")
            .flatMap(RelaisAffichage.init(rawValue:))
        guard let ancien else { return [brut, reorganiser, discuter] }
        var b = brut, r = reorganiser
        b.affichage = ancien
        r.affichage = ancien
        var d = discuter
        d.affichage = .page
        return [b, r, d]
    }

    private static let cleModules = "relais.modules"

    /// Tous les modules connus — les livrés, tels que l'utilisateur les a
    /// réglés, plus les siens.
    ///
    /// La fusion est faite dans ce sens et pas l'autre : ce qui est enregistré
    /// l'emporte, et un module livré qui n'y figure pas est **ajouté**. C'est
    /// ce qui fait qu'une version future peut en livrer un nouveau sans que
    /// personne n'ait à réinitialiser quoi que ce soit — et qu'un réglage déjà
    /// fait n'est jamais écrasé par la valeur d'usine.
    static var tous: [RelaisModule] {
        guard let data = UserDefaults.standard.data(forKey: cleModules),
              let enregistres = try? JSONDecoder().decode([RelaisModule].self, from: data),
              !enregistres.isEmpty
        else { return livres }
        // Un module livré garde sa définition et reprend les réglages qu'on lui
        // a faits ; un module écrit par l'utilisateur est repris tel quel ; un
        // module livré absent de l'enregistrement est ajouté.
        let parIdentifiant = Dictionary(uniqueKeysWithValues:
            livres.map { ($0.identifiant, $0) })
        let fusionnes = enregistres.map { enregistre in
            parIdentifiant[enregistre.identifiant]?.avecLesReglagesDe(enregistre)
                ?? enregistre
        }
        let connus = Set(enregistres.map(\.identifiant))
        return fusionnes + livres.filter { !connus.contains($0.identifiant) }
    }

    static func enregistrer(_ modules: [RelaisModule]) {
        guard let data = try? JSONEncoder().encode(modules) else { return }
        UserDefaults.standard.set(data, forKey: cleModules)
    }

    /// Remplace un module par sa version modifiée.
    static func remplacer(_ module: RelaisModule) {
        var liste = tous
        guard let i = liste.firstIndex(where: { $0.identifiant == module.identifiant })
        else { return }
        liste[i] = module
        enregistrer(liste)
    }

    /// Ceux qu'on peut réellement proposer, ici et maintenant.
    ///
    /// Un module dont les repères manquent n'apparaît pas sur la barre. Le
    /// proposer laisserait le choisir en pleine phrase pour n'apprendre l'échec
    /// qu'à la fin, quand il est trop tard pour redire.
    static var proposes: [RelaisModule] {
        let s = RelaisSelecteurs.charger()
        return tous.filter { $0.estUtilisable(s) }
    }

    private static let cle = "relais.mode"

    static var courant: RelaisModule {
        get {
            let enregistre = UserDefaults.standard.string(forKey: cle) ?? ""
            // Les anciens noms sont traduits plutôt qu'ignorés : un
            // identifiant qui change et un repli silencieux, c'est le réglage
            // de l'utilisateur qui disparaît à la mise à jour.
            let identifiant: String
            switch enregistre {
            case "auPropre": identifiant = "reorganiser"
            case "consigne", "rediger": identifiant = "brut"
            default: identifiant = enregistre
            }
            return tous.first { $0.identifiant == identifiant } ?? brut
        }
        set { UserDefaults.standard.set(newValue.identifiant, forKey: cle) }
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

}
