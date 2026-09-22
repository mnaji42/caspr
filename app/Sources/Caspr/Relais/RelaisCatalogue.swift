import Foundation
import CasprCore

// Les définitions des modules livrés vivent dans CasprCore, où l'on vérifie
// ce qu'elles exigent de la page ; ce qui suit les range et les relit dans
// les réglages de l'utilisateur.
extension RelaisCatalogue {
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
        guard let data = UserDefaults.standard.data(forKey: cleModules) else { return livres }
        let enregistres = RelaisModule.liste(depuis: data)
        guard !enregistres.isEmpty else { return livres }
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

