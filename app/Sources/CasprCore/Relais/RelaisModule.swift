import Foundation

/// La place que la consigne tient dans un module.
public enum RelaisPlaceDeLaConsigne: String, Codable {
    /// Le module envoie ce qui est dicté, tel quel. Rien à régler.
    case aucune
    /// Le module en propose une, qu'on peut retirer.
    case facultative
    /// Le module n'existe que par elle. La retirer en ferait un autre.
    case essentielle
}

/// Ce qu'un module fait de la transcription, une fois l'écoute finie.
///
/// Un seul choix, et non des actions et des sorties à combiner. Les deux
/// listes d'avant permettaient d'écrire « rapatrier la réponse » sans rien
/// envoyer, ou « écrire au curseur » un texte resté à l'écran : des
/// combinaisons qu'il fallait valider, et que chaque lecteur interprétait à
/// sa façon — la barre et la dictée ne retenaient pas le même module. Ici,
/// une combinaison invalide ne s'écrit pas.
///
/// La fenêtre et le clavier suivent : `discuter` est le seul qui laisse la
/// page ouverte et lui donne le clavier. Les deux autres écrivent au curseur
/// ou dans les notes, et la page ne doit jamais le prendre — le texte
/// partirait dans ChatGPT au lieu de l'éditeur, un défaut déjà payé une fois.
public enum RelaisEnvoi: String, CaseIterable, Codable {
    /// Rien ne part : on écrit la transcription elle-même.
    case aucun
    /// On envoie, on récupère la réponse, et c'est elle qu'on écrit.
    case remplacer
    /// On envoie, et la réponse reste à l'écran : rien ne s'écrit.
    case discuter

    public var libelle: String {
        switch self {
        case .aucun: "Écrire la dictée"
        case .remplacer: "Écrire la réponse"
        case .discuter: "Discuter"
        }
    }
}

/// Ce que Caspr fait d'une dictée, du micro jusqu'à la sortie.
///
/// **Un module est un module, qu'on l'ait écrit ou non.** Ceux que
/// l'application livre ne sont que des modules pré-remplis : même structure,
/// mêmes réglages, la seule différence est qu'ils existent au premier
/// lancement. C'est ce qui permet à quelqu'un de recréer « Réorganiser » à sa
/// façon, ou d'en tirer une variante, sans qu'on ait rien prévu pour lui.
///
/// Le chemin est toujours le même — écouter, encadrer, envoyer, attendre,
/// récupérer, dire à haute voix, livrer — et un module ne dit que ce qu'il
/// fait de la transcription (`envoi`), ce qu'il ajoute autour, ce qu'il
/// montre et s'il fait lire la réponse. Le tuyau de dictée ne lit rien
/// d'autre : un module écrit demain par l'utilisateur tourne sans qu'une
/// ligne n'y change.
public struct RelaisModule: Codable, Equatable, Identifiable {
    /// Stable, et jamais traduit : c'est lui qu'on enregistre.
    public var identifiant: String
    public var nom: String
    /// Livré avec l'application. Ne se supprime pas ; se modifie.
    public var integre: Bool

    /// Ce qui est ajouté devant et derrière la transcription.
    ///
    /// Deux textes plutôt qu'un gabarit à trou, et c'est une contrainte du
    /// mécanisme, pas un choix de commodité : la transcription est **déjà**
    /// dans la zone de saisie de ChatGPT. On ne peut que l'encadrer. Un
    /// gabarit obligerait à réécrire l'ensemble, ce qui produisait des à-coups
    /// et un envoi parfois amputé.
    public var avant: String
    public var apres: String

    /// Quelle place la consigne tient dans ce module.
    ///
    /// Trois états, parce qu'il y en a trois, et deux booléens se seraient
    /// contredits à mi-chemin. « Discuter » envoie ce qu'on dit, tel quel :
    /// une consigne n'y a pas sa place, et lui en proposer une reviendrait à
    /// proposer d'en faire un autre module. « Réorganiser » sans consigne ne
    /// réorganise plus rien : elle y est l'identité même. Et un module écrit
    /// par l'utilisateur choisit.
    public var consigne: RelaisPlaceDeLaConsigne

    /// Ce module propose-t-il de faire lire la réponse ?
    ///
    /// Un choix de conception, module par module : la lecture à haute voix
    /// marche partout, y compris avec un texte qui part au curseur. Les
    /// modules livrés restent simples — seul « Discuter » l'offre, parce que
    /// sa réponse ne vit qu'à l'écran. Ceux de l'utilisateur l'offrent tous.
    public var lectureProposee: Bool

    /// Faire lire la réponse à haute voix — un réglage, pas une nature.
    ///
    /// À part de l'`envoi` parce qu'il appartient à l'utilisateur, tandis que
    /// l'envoi d'un module livré suit les versions de l'application. Rangé
    /// parmi les actions d'autrefois, il était réenregistré puis aussitôt
    /// écrasé par la définition d'usine à la lecture suivante : la case se
    /// décochait toute seule sans que rien ne le dise.
    public var ditLaReponse: Bool

    public var envoi: RelaisEnvoi

    /// Ce qu'on montre de la page pendant l'écoute.
    public var affichage: RelaisAffichage

    public var id: String { identifiant }

    /// Les clés rangées, et après elles celles qu'un enregistrement plus
    /// ancien portait, ou que les versions antérieures lisent encore (cf.
    /// `encode(to:)`).
    private enum CodingKeys: String, CodingKey {
        case identifiant, nom, integre, avant, apres, consigne, lectureProposee,
             ditLaReponse, envoi, affichage
        case consigneEssentielle, actions, sorties, sortieParDefaut
    }

    // MARK: - Décodage tolérant
    //
    // Même règle que pour les sélecteurs, et pour la même raison : un champ
    // ajouté plus tard ne doit pas rendre illisibles les modules déjà
    // enregistrés. Le décodage synthétisé de Swift échoue sur une clé absente,
    // et l'on efface alors le travail de l'utilisateur sans le lui dire.
    public init(from decoder: Decoder) throws {
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
        } else {
            consigne = try c.decodeIfPresent(Bool.self, forKey: .consigneEssentielle) == true
                ? .essentielle : .facultative
        }
        lectureProposee = try c.decodeIfPresent(Bool.self, forKey: .lectureProposee) ?? true
        ditLaReponse = try c.decodeIfPresent(Bool.self, forKey: .ditLaReponse) ?? false
        // Traduit des actions et de la sortie d'avant, pour un module écrit
        // avant que l'envoi n'existe — ou réécrit depuis par une version
        // antérieure, qui l'aura laissé tomber. Lues en chaînes : `main`
        // rangeait aussi `joindreEcran`, qu'aucune énumération d'ici ne
        // connaît, et une valeur inconnue faisait perdre tout le module.
        if let envoi = try c.decodeIfPresent(RelaisEnvoi.self, forKey: .envoi) {
            self.envoi = envoi
        } else if try c.decodeIfPresent([String].self, forKey: .actions)?
                    .contains("demanderUneReponse") == true {
            envoi = try c.decodeIfPresent(String.self, forKey: .sortieParDefaut) == "aucune"
                ? .discuter : .remplacer
        } else {
            envoi = .aucun
        }
        affichage = try c.decodeIfPresent(RelaisAffichage.self, forKey: .affichage) ?? .barre
    }

    /// Écrit l'envoi, **et** les actions et sorties qui le disaient avant lui.
    ///
    /// Le propriétaire peut réinstaller une version antérieure. Elle ne connaît
    /// pas `envoi`, et relirait sans les anciennes clés un « Discuter » comme
    /// un module qui écrit au curseur, et ses modules à consigne comme
    /// « Brut » — le souci déjà payé avec l'historique d'une 0.14 (323b6e5).
    /// Seulement des valeurs que toutes ces versions connaissent : elles
    /// décodent la liste d'un bloc, et une seule inconnue la leur ferait
    /// perdre entière.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identifiant, forKey: .identifiant)
        try c.encode(nom, forKey: .nom)
        try c.encode(integre, forKey: .integre)
        try c.encode(avant, forKey: .avant)
        try c.encode(apres, forKey: .apres)
        try c.encode(consigne, forKey: .consigne)
        try c.encode(lectureProposee, forKey: .lectureProposee)
        try c.encode(ditLaReponse, forKey: .ditLaReponse)
        try c.encode(envoi, forKey: .envoi)
        try c.encode(affichage, forKey: .affichage)
        let sorties = envoi == .discuter ? ["aucune"] : ["curseur", "note"]
        try c.encode(envoi == .aucun ? [] : ["demanderUneReponse"], forKey: .actions)
        try c.encode(sorties, forKey: .sorties)
        try c.encode(sorties[0], forKey: .sortieParDefaut)
    }

    public init(identifiant: String, nom: String, integre: Bool = false,
         avant: String = "", apres: String = "",
         consigne: RelaisPlaceDeLaConsigne = .facultative,
         lectureProposee: Bool = true, ditLaReponse: Bool = false,
         envoi: RelaisEnvoi = .aucun, affichage: RelaisAffichage = .barre) {
        self.identifiant = identifiant
        self.nom = nom
        self.integre = integre
        self.avant = avant
        self.apres = apres
        self.consigne = consigne
        self.lectureProposee = lectureProposee
        self.ditLaReponse = ditLaReponse
        self.envoi = envoi
        self.affichage = affichage
    }

    /// Reprend les choix de l'utilisateur, sans reprendre la définition.
    ///
    /// Un module livré a deux moitiés. Sa **nature** — son nom, son envoi, la
    /// place de sa consigne — appartient à l'application et doit suivre ses
    /// versions. Ses **réglages** — la consigne elle-même, ce qu'il affiche,
    /// la lecture — appartiennent à celui qui s'en sert.
    ///
    /// Tout reprendre de l'enregistré gelait la définition au jour où elle avait
    /// été rangée : un attribut ajouté ensuite n'atteignait jamais les
    /// installations existantes, et l'on croyait le code sans effet. Tout
    /// reprendre du livré effacerait au contraire le travail de l'utilisateur à
    /// chaque mise à jour.
    public func avecLesReglagesDe(_ enregistre: RelaisModule) -> RelaisModule {
        var fusion = self
        fusion.avant = enregistre.avant
        fusion.apres = enregistre.apres
        fusion.affichage = enregistre.affichage
        fusion.ditLaReponse = enregistre.ditLaReponse
        return fusion
    }

    /// Le seul prédicat de destination : la barre, la fenêtre, la fin d'une
    /// dictée et la carte le lisent tous ici. Quatre façons de le dire
    /// (sortie par défaut, liste des sorties, drapeau de la dictée…) finissaient
    /// par ne plus dire la même chose.
    public var ecrit: Bool { envoi != .discuter }

    /// L'affichage que ce module ne laisse pas choisir, s'il en impose un.
    ///
    /// Un module qui n'écrit nulle part met la réponse **à l'écran** : c'est
    /// le seul endroit où elle existe. Choisir « Rien » reviendrait alors à
    /// demander une réponse qu'on ne verra jamais — sauf s'il la fait lire à
    /// haute voix : on peut écouter sans regarder.
    public var affichageImpose: RelaisAffichage? {
        !ecrit && !ditLaReponse ? .page : nil
    }

    /// Ce qu'on montre réellement, contrainte comprise.
    public var affichageEffectif: RelaisAffichage { affichageImpose ?? affichage }

    // MARK: - Ce qu'il exige de la page

    /// Tout ce qu'il faut avoir appris pour que ce module tourne.
    ///
    /// « Brut » n'envoie rien et n'exige que le socle. Il exigeait autrefois
    /// « Récupérer la réponse », si bien qu'une installation qui n'avait
    /// jamais montré le bouton copier voyait ses modules passer
    /// « indisponibles », et leur pastille disparaître de la barre — la seule
    /// qui permette d'en changer.
    public var capacitesRequises: [RelaisCapacite] {
        var requises: Set<RelaisCapacite> = [.dicter]
        if envoi != .aucun { requises.insert(.envoyer) }
        if envoi == .remplacer { requises.insert(.recuperer) }
        if ditLaReponse { requises.insert(.direAHauteVoix) }
        return RelaisCapacite.allCases.filter { requises.contains($0) }
    }

    public func capacitesManquantes(_ s: RelaisSelecteurs) -> [RelaisCapacite] {
        capacitesRequises.filter { !$0.estAcquise(s) }
    }

    public func estUtilisable(_ s: RelaisSelecteurs) -> Bool { capacitesManquantes(s).isEmpty }
}

// MARK: - Relire une liste enregistrée

extension RelaisModule {
    /// Relit la liste enregistrée sous `relais.modules`, module par module.
    ///
    /// Décodée d'un bloc, la liste échouait tout entière dès qu'**un** module
    /// portait une valeur que cette version ne connaît pas — une action
    /// renommée (`envoyer` est devenu `demanderUneReponse`), un affichage
    /// ajouté par une version plus récente. Le catalogue retombait alors sur
    /// les modules d'usine : les réglages des modules livrés et tous les
    /// modules écrits par l'utilisateur disparaissaient, pour un seul champ
    /// illisible. Seul le module fautif est perdu désormais.
    ///
    /// Une donnée qui n'est pas une liste rend une liste vide, que l'appelant
    /// traite comme l'absence d'enregistrement.
    public static func liste(depuis data: Data) -> [RelaisModule] {
        guard let lus = try? JSONDecoder().decode([Lisible].self, from: data)
        else { return [] }
        return lus.compactMap(\.module)
    }

    /// Un élément de la liste qui ne lève jamais : c'est ce qui fait avancer
    /// le décodage au module suivant quand celui-ci est illisible.
    private struct Lisible: Decodable {
        let module: RelaisModule?

        init(from decoder: Decoder) throws {
            module = try? RelaisModule(from: decoder)
        }
    }
}
