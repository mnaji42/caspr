import Foundation
import CasprCore

// Les définitions des modules livrés vivent dans CasprCore, où l'on vérifie
// ce qu'elles exigent de la page ; ce qui suit les range et les relit dans
// les réglages de l'utilisateur.
extension RelaisCatalogue {
    /// Tous les modules connus — les livrés, tels que l'utilisateur les a
    /// réglés, plus les siens (cf. `fusion`).
    static var tous: [RelaisModule] {
        let affichage = UserDefaults.standard.string(forKey: cleAffichage)
            .flatMap(RelaisAffichage.init(rawValue:))
        return fusion(UserDefaults.standard.data(forKey: cleModules).map(RelaisModule.liste(depuis:)) ?? [],
                      livres: affichage.map(livres(affichage:)) ?? livres)
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

    /// Le module retenu (cf. `retenu`) ; l'écrire le choisit.
    static var courant: RelaisModule {
        get {
            retenu(identifiant(migre: UserDefaults.standard.string(forKey: cleMode) ?? ""),
                   parmi: tous, selecteurs: RelaisSelecteurs.charger())
        }
        set { UserDefaults.standard.set(newValue.identifiant, forKey: cleMode) }
    }
}
