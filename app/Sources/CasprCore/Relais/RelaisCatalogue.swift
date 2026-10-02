import Foundation

/// Les modules livrés avec l'application, leur fusion avec ceux qu'on a
/// enregistrés, et celui qui est retenu.
///
/// Les livrés ne sont que des modules pré-remplis. Rien ne les distingue de
/// ceux que l'utilisateur écrira, sinon qu'ils existent au premier lancement
/// — ce qui permet de dicter sans avoir rien à configurer.
///
/// Pur, et sous tests : ce qui touche aux réglages réels vit dans
/// `RelaisMagasin`, qui ne fait que ranger ce qu'on décide ici.
public enum RelaisCatalogue {
    /// Les clés de rangement. Leurs noms ne changent jamais : les versions
    /// antérieures les relisent (139).
    public static let cleModules = "relais.modules"
    public static let cleMode = "relais.mode"
    public static let cleSelecteurs = "relais.selecteurs"
    public static let cleDepart = "relais.pointDeDepart"
    /// L'affichage, du temps où il valait pour toute la fonctionnalité.
    /// Lu par `migrer`, jamais effacé : les clés `relais.*` restent pour une
    /// version antérieure relancée (cf. `VoieDeDictee.cleHeritee`).
    public static let cleAffichage = "relais.affichage"

    // MARK: - Le rangement
    //
    // Ici, sous tests, et non dans l'application : un test relit ce que
    // chaque version a rangé. Toucher à la persistance est le geste qui a
    // effacé le calibrage de tout le monde en 0.13.0.

    /// Le calibrage rangé ; illisible ou absent, il est vide — « rien n'a été
    /// calibré », jamais une erreur.
    public static func selecteurs(dans d: UserDefaults) -> RelaisSelecteurs {
        d.data(forKey: cleSelecteurs)
            .flatMap { try? JSONDecoder().decode(RelaisSelecteurs.self, from: $0) } ?? RelaisSelecteurs()
    }

    /// Les modules rangés, fusionnés avec les livrés (cf. `fusion`).
    public static func modules(dans d: UserDefaults) -> [RelaisModule] {
        fusion(d.data(forKey: cleModules).map(RelaisModule.liste(depuis:)) ?? [])
    }

    public static func ranger(_ valeur: some Encodable, sous cle: String, dans d: UserDefaults) {
        guard let data = try? JSONEncoder().encode(valeur) else { return }
        d.set(data, forKey: cle)
    }

    public static let brut = RelaisModule(
        identifiant: "brut", nom: "Brut", integre: true,
        consigne: .aucune, lectureProposee: false,
        envoi: .aucun, affichage: .barre)

    public static let reorganiser = RelaisModule(
        identifiant: "reorganiser", nom: "Réorganiser", integre: true,
        avant: RelaisPrompt.reorganiser + "\n\n=== DÉBUT DE LA TRANSCRIPTION ===\n",
        apres: "\n=== FIN DE LA TRANSCRIPTION ===",
        consigne: .essentielle, lectureProposee: false,
        envoi: .remplacer, affichage: .barre)

    /// Poser une question, et rester dans la conversation.
    ///
    /// Rien n'est inséré, la page reste ouverte et prend le clavier, et la
    /// touche de dictée relance une dictée **dans le même fil** au lieu
    /// d'ouvrir une conversation neuve. Fermer et rouvrir détruirait
    /// justement ce qu'on veut garder.
    ///
    /// Aucune consigne : ce qui est dit part tel quel. En ajouter une le
    /// rapprocherait d'un module de rédaction, qui est un autre besoin.
    public static let discuter = RelaisModule(
        identifiant: "discuter", nom: "Discuter", integre: true,
        consigne: .aucune, envoi: .discuter, affichage: .page)

    public static let livres = [brut, reorganiser, discuter]

    // MARK: - Livrés et enregistrés

    /// Tous les modules connus — les livrés, tels que l'utilisateur les a
    /// réglés, plus les siens.
    ///
    /// Un livré garde sa nature et reprend les réglages qu'on lui a faits
    /// (157) ; un module de l'utilisateur est repris tel quel ; un livré
    /// absent de l'enregistrement est **ajouté** (158) : une version future
    /// peut en livrer un nouveau sans que personne n'ait à réinitialiser quoi
    /// que ce soit, et un réglage déjà fait n'est jamais écrasé par la valeur
    /// d'usine. Rien d'enregistré — ou rien de lisible — rend les livrés.
    public static func fusion(_ enregistres: [RelaisModule],
                              livres: [RelaisModule] = livres) -> [RelaisModule] {
        let parIdentifiant = Dictionary(uniqueKeysWithValues: livres.map { ($0.identifiant, $0) })
        let connus = Set(enregistres.map(\.identifiant))
        return enregistres.map { parIdentifiant[$0.identifiant]?.avecLesReglagesDe($0) ?? $0 }
            + livres.filter { !connus.contains($0.identifiant) }
    }

    /// Le module choisi s'il est utilisable, sinon « Brut ».
    ///
    /// La barre **et** la dictée le lisent. La barre montrait le premier
    /// module proposé quand le choisi ne l'était pas, tandis que la dictée
    /// figeait le choisi : un « Discuter » dont l'envoi n'était pas appris
    /// ouvrait une discussion où rien n'était parti, et n'écrivait rien.
    public static func retenu(_ choisi: String, parmi modules: [RelaisModule],
                              selecteurs: RelaisSelecteurs) -> RelaisModule {
        if let module = modules.first(where: { $0.identifiant == choisi }),
           module.estUtilisable(selecteurs) { return module }
        return modules.first { $0.identifiant == brut.identifiant } ?? brut
    }

    /// Un module de l'utilisateur, ajouté à `modules`.
    ///
    /// Il remplace le texte par la réponse de ChatGPT : c'est ce qu'on crée
    /// un module pour faire — traduire, reformuler, résumer —, le reste se
    /// règle ensuite sur sa carte. L'identifiant est tiré au sort, pour qu'un
    /// renommage ne le change pas et qu'un nom pris ne gêne personne.
    @discardableResult
    public static func ajouter(nom: String, a modules: inout [RelaisModule]) -> RelaisModule {
        let module = RelaisModule(identifiant: UUID().uuidString, nom: nom,
                                  consigne: .facultative, envoi: .remplacer)
        modules.append(module)
        return module
    }

    /// Retire un module de l'utilisateur ; un livré ne se supprime pas, il
    /// reviendrait de toute façon à la lecture suivante.
    public static func supprimer(_ identifiant: String, de modules: inout [RelaisModule]) {
        modules.removeAll { $0.identifiant == identifiant && !$0.integre }
    }

    // MARK: - Les formes d'avant

    /// Les anciens noms de module, traduits plutôt qu'ignorés : un
    /// identifiant qui change et un repli silencieux, c'est le réglage de
    /// l'utilisateur qui disparaît à la mise à jour (161).
    public static func identifiant(migre ancien: String) -> String {
        switch ancien {
        case "auPropre": "reorganiser"
        case "consigne", "rediger": "brut"
        default: ancien
        }
    }

    /// Les livrés, avec l'affichage qui valait pour toute la fonctionnalité.
    ///
    /// Il appartient maintenant à chaque module, et devient la valeur de
    /// départ de ceux qui écrivent : un réglage qu'on a pris la peine de faire
    /// ne disparaît pas parce que le code a changé d'avis sur l'endroit où le
    /// ranger. « Discuter » garde la page, où sa réponse existe.
    public static func livres(affichage: RelaisAffichage) -> [RelaisModule] {
        livres.map { module in
            var m = module
            if m.ecrit { m.affichage = affichage }
            return m
        }
    }

    /// Traduit une fois les formes d'avant dans `defaults` ; ce qui a été
    /// fait, pour le journal.
    ///
    /// Repasse à chaque lancement sans rien refaire : l'affichage n'est versé
    /// qu'aux livrés absents de l'enregistrement, qui n'y manquent plus
    /// ensuite, et un mode déjà traduit n'a plus rien à traduire.
    public static func migrer(_ defaults: UserDefaults) -> [String] {
        var faits: [String] = []
        if let affichage = defaults.string(forKey: cleAffichage).flatMap(RelaisAffichage.init(rawValue:)) {
            let enregistres = defaults.data(forKey: cleModules).map(RelaisModule.liste(depuis:)) ?? []
            let modules = fusion(enregistres, livres: livres(affichage: affichage))
            if modules.count != enregistres.count {
                ranger(modules, sous: cleModules, dans: defaults)
                faits.append("affichage du relais (\(affichage.rawValue)) repris par les modules livrés")
            }
        }
        if let mode = defaults.string(forKey: cleMode), identifiant(migre: mode) != mode {
            defaults.set(identifiant(migre: mode), forKey: cleMode)
            faits.append("module du relais « \(mode) » devenu « \(identifiant(migre: mode)) »")
        }
        return faits
    }
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
