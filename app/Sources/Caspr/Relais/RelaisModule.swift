import Foundation

/// La place que la consigne tient dans un module.
enum RelaisPlaceDeLaConsigne: String, Codable {
    /// Le module envoie ce qui est dicté, tel quel. Rien à régler.
    case aucune
    /// Le module en propose une, qu'on peut retirer.
    case facultative
    /// Le module n'existe que par elle. La retirer en ferait un autre.
    case essentielle
}

/// Où atterrit ce qui a été dicté.
///
/// Une seule décision, et non trois. Elle emporte la fenêtre et le clavier
/// avec elle : `aucune` veut dire que la page reste ouverte et prend le
/// clavier, les deux autres qu'elle se referme. Les traiter séparément
/// permettrait d'écrire « insertion au curseur **et** fenêtre qui prend le
/// clavier » — c'est-à-dire le texte qui part dans ChatGPT au lieu de
/// l'éditeur, un défaut déjà payé une fois.
enum RelaisSortie: String, CaseIterable, Codable {
    case curseur, note, aucune

    var libelle: String {
        switch self {
        case .curseur: "Curseur"
        case .note: "Notes…"
        case .aucune: "Discuter"
        }
    }

    /// Faut-il rapatrier la réponse de ChatGPT ?
    ///
    /// Conséquence, jamais choix. Une case « copier le résultat » à cocher à
    /// côté d'une sortie qui l'implique déjà, c'est deux réglages qui peuvent
    /// se contredire.
    var demandeLaReponse: Bool { self != .aucune }

    /// La page se referme-t-elle après ?
    var refermeLaPage: Bool { self != .aucune }
}

/// Ce que Caspr fait d'une dictée, du micro jusqu'à la sortie.
///
/// **Un module est un module, qu'on l'ait écrit ou non.** Ceux que
/// l'application livre ne sont que des modules pré-remplis : même structure,
/// mêmes réglages, la seule différence est qu'ils existent au premier
/// lancement. C'est ce qui permet à quelqu'un de recréer « Réorganiser » à sa
/// façon, ou d'en tirer une variante, sans qu'on ait rien prévu pour lui.
///
/// ## L'ordre des étapes n'appartient pas au module
///
/// Le chemin est toujours le même — écouter, encadrer, envoyer, attendre,
/// récupérer, dire à haute voix, livrer, refermer — et un module ne fait que
/// dire lesquelles de ces étapes le concernent. Le laisser réordonner
/// permettrait d'écrire « récupérer la réponse » avant « envoyer », c'est-à-dire
/// une configuration qu'il faudrait valider au lieu de la rendre impossible.
///
/// Le module reste malgré tout lisible comme une recette : on affiche les
/// étapes actives dans l'ordre du chemin, et l'on voit ce qu'il fait.
struct RelaisModule: Codable, Equatable, Identifiable {
    /// Stable, et jamais traduit : c'est lui qu'on enregistre.
    var identifiant: String
    var nom: String
    /// Livré avec l'application. Ne se supprime pas ; se modifie.
    var integre: Bool

    /// Ce qui est ajouté devant et derrière la transcription.
    ///
    /// Deux textes plutôt qu'un gabarit à trou, et c'est une contrainte du
    /// mécanisme, pas un choix de commodité : la transcription est **déjà**
    /// dans la zone de saisie de ChatGPT. On ne peut que l'encadrer. Un
    /// gabarit obligerait à réécrire l'ensemble, ce qui produisait des à-coups
    /// et un envoi parfois amputé.
    var avant: String
    var apres: String

    /// Quelle place la consigne tient dans ce module.
    ///
    /// Trois états, parce qu'il y en a trois, et deux booléens se seraient
    /// contredits à mi-chemin. « Discuter » envoie ce qu'on dit, tel quel :
    /// une consigne n'y a pas sa place, et lui en proposer une reviendrait à
    /// proposer d'en faire un autre module. « Réorganiser » sans consigne ne
    /// réorganise plus rien : elle y est l'identité même. Et un module écrit
    /// par l'utilisateur choisit.
    var consigne: RelaisPlaceDeLaConsigne

    /// Ce module propose-t-il de faire lire la réponse ?
    ///
    /// Pas une règle déduite de la sortie : la lecture à haute voix est
    /// utilisable partout, y compris avec un texte qui part au curseur — rien
    /// n'interdit d'écrire *et* d'entendre. C'est un choix de conception, module
    /// par module.
    ///
    /// Les trois modules livrés restent simples : seul « Discuter » l'offre,
    /// parce que sa réponse ne vit qu'à l'écran. Les modules écrits par
    /// l'utilisateur l'offrent tous — ce qu'il en fait le regarde.
    var lectureProposee: Bool

    /// Faire lire la réponse à haute voix — un réglage, pas une nature.
    ///
    /// Il vit à part des `actions` parce qu'il appartient à l'utilisateur,
    /// tandis que les actions décrivent ce que le module *est* et suivent les
    /// versions de l'application. Rangé parmi les actions, il était réenregistré
    /// puis aussitôt écrasé par la définition d'usine à la lecture suivante : la
    /// case se décochait toute seule sans que rien ne le dise.
    var ditLaReponse: Bool

    /// Les étapes que ce module demande, entre l'écoute et la sortie.
    ///
    /// Une liste et non des drapeaux : ajouter une étape au produit ne doit
    /// obliger à retoucher ni le module, ni le calcul des capacités, ni le
    /// tuyau qui les exécute. L'ordre d'exécution vient de `RelaisAction`, pas
    /// d'ici — celui qui écrit un module choisit ce qu'il veut, jamais quand.
    var actions: [RelaisAction]

    /// Les sorties que ce module autorise, et celle qu'il propose d'abord.
    ///
    /// Plusieurs, parce que le choix se fait au dernier moment sur la barre —
    /// comme aujourd'hui pour Curseur et Notes. Un module qui n'en autorise
    /// qu'une l'impose.
    var sorties: [RelaisSortie]
    var sortieParDefaut: RelaisSortie

    /// La capture d'écran est-elle jointe par défaut ?
    ///
    /// Éteinte, toujours, et c'est un choix d'ergonomie : cliquer pour ajouter
    /// une capture se comprend, cliquer pour en éviter une s'oublie. Un module
    /// dont c'est l'usage courant peut la rallumer.
    var ecranParDefaut: Bool

    /// Ce qu'on montre de la page pendant l'écoute.
    var affichage: RelaisAffichage

    var id: String { identifiant }

    /// Les noms qu'un enregistrement plus ancien pouvait porter.
    private enum AnciennesCles: String, CodingKey {
        case consigneEssentielle
    }

    // MARK: - Décodage tolérant
    //
    // Même règle que pour les sélecteurs, et pour la même raison : un champ
    // ajouté plus tard ne doit pas rendre illisibles les modules déjà
    // enregistrés. Le décodage synthétisé de Swift échoue sur une clé absente,
    // et l'on efface alors le travail de l'utilisateur sans le lui dire.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifiant = try c.decode(String.self, forKey: .identifiant)
        nom = try c.decodeIfPresent(String.self, forKey: .nom) ?? identifiant
        integre = try c.decodeIfPresent(Bool.self, forKey: .integre) ?? false
        avant = try c.decodeIfPresent(String.self, forKey: .avant) ?? ""
        apres = try c.decodeIfPresent(String.self, forKey: .apres) ?? ""
        // L'ancien booléen est traduit plutôt qu'ignoré : un champ qui change
        // de forme ne doit pas effacer ce qui était enregistré.
        if let place = try c.decodeIfPresent(RelaisPlaceDeLaConsigne.self, forKey: .consigne) {
            consigne = place
        } else if let vieux = try? decoder.container(keyedBy: AnciennesCles.self),
                  try vieux.decodeIfPresent(Bool.self, forKey: .consigneEssentielle) == true {
            consigne = .essentielle
        } else {
            consigne = .facultative
        }
        lectureProposee = try c.decodeIfPresent(Bool.self, forKey: .lectureProposee) ?? true
        ditLaReponse = try c.decodeIfPresent(Bool.self, forKey: .ditLaReponse) ?? false
        actions = try c.decodeIfPresent([RelaisAction].self, forKey: .actions) ?? []
        sorties = try c.decodeIfPresent([RelaisSortie].self, forKey: .sorties) ?? [.curseur, .note]
        sortieParDefaut = try c.decodeIfPresent(RelaisSortie.self, forKey: .sortieParDefaut) ?? .curseur
        ecranParDefaut = try c.decodeIfPresent(Bool.self, forKey: .ecranParDefaut) ?? false
        affichage = try c.decodeIfPresent(RelaisAffichage.self, forKey: .affichage) ?? .barre
    }

    init(identifiant: String, nom: String, integre: Bool = false,
         avant: String = "", apres: String = "",
         consigne: RelaisPlaceDeLaConsigne = .facultative,
         lectureProposee: Bool = true, ditLaReponse: Bool = false,
         actions: [RelaisAction] = [],
         sorties: [RelaisSortie] = [.curseur, .note],
         sortieParDefaut: RelaisSortie = .curseur,
         ecranParDefaut: Bool = false,
         affichage: RelaisAffichage = .barre) {
        self.identifiant = identifiant
        self.nom = nom
        self.integre = integre
        self.avant = avant
        self.apres = apres
        self.consigne = consigne
        self.lectureProposee = lectureProposee
        self.ditLaReponse = ditLaReponse
        self.actions = actions
        self.sorties = sorties
        self.sortieParDefaut = sortieParDefaut
        self.ecranParDefaut = ecranParDefaut
        self.affichage = affichage
    }

    /// Reprend les choix de l'utilisateur, sans reprendre la définition.
    ///
    /// Un module livré a deux moitiés. Sa **nature** — son nom, ses actions, ses
    /// sorties, le fait que sa consigne lui soit essentielle — appartient à
    /// l'application et doit suivre ses versions. Ses **réglages** — la consigne
    /// elle-même, ce qu'il affiche — appartiennent à celui qui s'en sert.
    ///
    /// Tout reprendre de l'enregistré gelait la définition au jour où elle avait
    /// été rangée : un attribut ajouté ensuite n'atteignait jamais les
    /// installations existantes, et l'on croyait le code sans effet. Tout
    /// reprendre du livré effacerait au contraire le travail de l'utilisateur à
    /// chaque mise à jour. On prend donc la nature d'un côté, les réglages de
    /// l'autre.
    func avecLesReglagesDe(_ enregistre: RelaisModule) -> RelaisModule {
        var fusion = self
        fusion.avant = enregistre.avant
        fusion.apres = enregistre.apres
        fusion.affichage = enregistre.affichage
        fusion.ecranParDefaut = enregistre.ecranParDefaut
        fusion.sortieParDefaut = enregistre.sortieParDefaut
        fusion.ditLaReponse = enregistre.ditLaReponse
        return fusion
    }

    /// L'affichage que ce module ne laisse pas choisir, s'il en impose un.
    ///
    /// Une sortie qui n'écrit nulle part met la réponse **à l'écran** : c'est
    /// le seul endroit où elle existe. Choisir « Rien » reviendrait alors à
    /// demander une réponse qu'on ne verra jamais.
    ///
    /// Sauf si le module la fait lire à haute voix — on peut écouter sans
    /// regarder. La contrainte n'est donc pas attachée au module « Discuter »
    /// mais à ce qui la justifie, et elle vaudra d'elle-même pour les modules
    /// que l'utilisateur écrira.
    var affichageImpose: RelaisAffichage? {
        sortieParDefaut == .aucune && !ditLaReponse ? .page : nil
    }

    /// Ce qu'on montre réellement, contrainte comprise.
    var affichageEffectif: RelaisAffichage { affichageImpose ?? affichage }

    // MARK: - Ce qu'il exige de la page

    /// Les étapes actives, dans l'ordre du chemin.
    ///
    /// L'ordre vient de `RelaisAction.allCases` et non de la liste
    /// enregistrée : un module ne choisit pas quand, seulement quoi.
    var etapes: [RelaisAction] {
        var demandees = Set(actions)
        if ditLaReponse { demandees.insert(.direLaReponse) }
        return RelaisAction.allCases.filter { demandees.contains($0) }
    }

    var demandeUnAllerRetour: Bool { actions.contains(.demanderUneReponse) }
    var ecranPossible: Bool { actions.contains(.joindreEcran) }

    /// Tout ce qu'il faut avoir appris pour que ce module tourne.
    ///
    /// Le socle, plus ce que réclament ses étapes, plus ce que réclament les
    /// sorties qu'il autorise. Rien n'est écrit à la main : une action nouvelle
    /// déclare ses exigences et cette liste s'allonge d'elle-même.
    ///
    /// Les sorties ne comptent que pour un module qui envoie quelque chose.
    /// Ce qu'elles exigent — rapatrier la réponse — n'a de sens que s'il y a
    /// une réponse : « Brut » n'envoie rien, et écrit au curseur la
    /// transcription elle-même. Il exigeait pourtant « Récupérer la réponse »,
    /// si bien qu'une installation qui n'avait jamais montré le bouton copier
    /// voyait ses trois modules passer « indisponibles », et leur pastille
    /// disparaître de la barre — la seule qui permette d'en changer.
    var capacitesRequises: [RelaisCapacite] {
        var requises: Set<RelaisCapacite> = [.dicter]
        for etape in etapes { requises.formUnion(etape.capacitesRequises) }
        if demandeUnAllerRetour {
            for sortie in sorties { requises.formUnion(sortie.capacitesRequises) }
        }
        return RelaisCapacite.allCases.filter { requises.contains($0) }
    }

    func capacitesManquantes(_ s: RelaisSelecteurs) -> [RelaisCapacite] {
        capacitesRequises.filter { !$0.estAcquise(s) }
    }

    func estUtilisable(_ s: RelaisSelecteurs) -> Bool { capacitesManquantes(s).isEmpty }
}
