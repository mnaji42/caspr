import Foundation
import CasprCore

/// Ce que le relais a appris de la page et ce qu'on en a réglé : les
/// sélecteurs, les modules, le module choisi, le point de départ.
///
/// En mémoire et publiés, écrits à chaque changement sous leurs clés de
/// toujours (`RelaisCatalogue.cle…`, 139), et relus par `RelaisCatalogue`,
/// sous tests contre ce que `main` rangeait. Chaque lecteur relisait les
/// réglages et redécodait le JSON à chaque accès — la barre plusieurs fois
/// par dictée —, et les écrans gardaient leur propre copie, qu'il fallait
/// penser à relire après chaque calibration : une calibration finie ailleurs
/// laissait les réglages annoncer « configuration inachevée » à qui venait de
/// la terminer (86, 162). Ici, une seule copie, et les écrans l'observent.
///
/// Ce qui se décide — la fusion des modules, celui qui est retenu, les
/// formes d'avant — vit dans `RelaisCatalogue`, pur et sous tests ; les
/// formes d'avant sont traduites une fois, par `Migration.run`, avant que le
/// magasin ne lise quoi que ce soit.
@MainActor
final class RelaisMagasin: ObservableObject {
    static let partage = RelaisMagasin()

    private let defaults = UserDefaults.standard

    /// Écrit par la calibration seule.
    @Published var selecteurs: RelaisSelecteurs {
        didSet { RelaisCatalogue.ranger(selecteurs, sous: RelaisCatalogue.cleSelecteurs, dans: defaults) }
    }
    /// Les livrés, tels que l'utilisateur les a réglés, puis les siens.
    @Published private(set) var modules: [RelaisModule] {
        didSet { RelaisCatalogue.ranger(modules, sous: RelaisCatalogue.cleModules, dans: defaults) }
    }
    /// L'identifiant choisi sur la barre ; ce qui compte est `retenu`.
    @Published private var choisi: String {
        didSet { defaults.set(choisi, forKey: RelaisCatalogue.cleMode) }
    }

    /// La page d'où part chaque conversation.
    ///
    /// Par défaut chatgpt.com, qui ouvre un fil neuf. Mais on peut lui
    /// substituer n'importe quelle page de ChatGPT — typiquement un projet
    /// dédié : les conversations qu'y crée Caspr s'y rangent alors, groupées et
    /// à l'écart des vraies. Une URL et non un bouton à calibrer : elle ne
    /// dépend d'aucun élément de la page, donc rien ne casse au prochain
    /// remaniement de ChatGPT.
    ///
    /// L'hôte est vérifié à l'écriture, et de nouveau à chaque lecture (88) :
    /// une adresse enregistrée est rechargée à chaque dictée sans que
    /// personne ne la relise, elle doit rester ce qu'elle prétend être.
    var depart: URL { departChoisi.flatMap { RelaisPage.estChatGPT($0) ? $0 : nil } ?? RelaisPage.accueil }
    @Published private var departChoisi: URL? {
        didSet { defaults.set(departChoisi?.absoluteString, forKey: RelaisCatalogue.cleDepart) }
    }

    private init() {
        selecteurs = RelaisCatalogue.selecteurs(dans: defaults)
        modules = RelaisCatalogue.modules(dans: defaults)
        choisi = defaults.string(forKey: RelaisCatalogue.cleMode) ?? RelaisCatalogue.brut.identifiant
        departChoisi = defaults.string(forKey: RelaisCatalogue.cleDepart).flatMap(URL.init(string:))
    }

    /// Faux quand `url` n'est pas une page de ChatGPT : rien n'est changé.
    func adopter(_ url: URL) -> Bool {
        guard RelaisPage.estChatGPT(url) else { return false }
        departChoisi = url
        return true
    }

    func revenirALAccueil() { departChoisi = nil }

    // MARK: - Les modules

    /// Ceux qu'on peut réellement proposer, ici et maintenant (87).
    ///
    /// Un module dont les repères manquent n'apparaît pas sur la barre. Le
    /// proposer laisserait le choisir en pleine phrase pour n'apprendre l'échec
    /// qu'à la fin, quand il est trop tard pour redire.
    var proposes: [RelaisModule] { modules.filter { $0.estUtilisable(selecteurs) } }

    /// Celui que la barre montre et que la dictée fige (cf.
    /// `RelaisCatalogue.retenu`).
    var retenu: RelaisModule {
        RelaisCatalogue.retenu(choisi, parmi: modules, selecteurs: selecteurs)
    }

    func choisir(_ module: RelaisModule) { choisi = module.identifiant }

    /// Remplace un module par sa version modifiée.
    func remplacer(_ module: RelaisModule) {
        guard let i = modules.firstIndex(where: { $0.identifiant == module.identifiant }) else { return }
        modules[i] = module
    }

    /// Un module de l'utilisateur, en fin de liste (cf.
    /// `RelaisCatalogue.nouveau`). Il rejoint la barre dès que ses capacités
    /// sont acquises : le tuyau de dictée ne lit que ce qu'il déclare (163).
    func ajouter(_ module: RelaisModule) { modules.append(module) }

    /// Choisi sur la barre, il y cède la place à Brut (cf. `retenu`).
    func supprimer(_ module: RelaisModule) { RelaisCatalogue.supprimer(module.identifiant, de: &modules) }
}
