import WebKit
import CasprCore

// Ce que la page offre aux deux calibrations : le message d'essai, et les
// guetteurs qui attendent un clic pour en retenir le repère.
extension RelaisPage {
    /// Le message d'essai de la calibration.
    ///
    /// Court et explicite : il part réellement dans la conversation de
    /// l'utilisateur, et il vaut mieux qu'on comprenne pourquoi en le relisant
    /// six mois plus tard.
    static let essai = "Bonjour — message d'essai envoyé par Caspr pour repérer les "
                     + "boutons de la page. Réponds simplement « c'est noté »."

    /// Écrit un message d'essai, pour que le bouton d'envoi apparaisse.
    ///
    /// Il n'existe pas tant que la zone est vide — ChatGPT y met son bouton de
    /// dictée à la place. On ne peut donc pas le désigner sans lui donner une
    /// raison d'être là.
    ///
    /// L'écriture est **vérifiée**, et c'est tout l'objet de cette méthode. La
    /// version précédente écrivait une fois et considérait l'affaire close.
    /// Or la zone de saisie existe dans le DOM avant que ChatGPT n'en ait
    /// repris le contrôle : le texte y était bien déposé, puis effacé par le
    /// rendu qui suivait. L'utilisateur se retrouvait devant une zone vide,
    /// sans bouton d'envoi à désigner, et sans rien qui explique pourquoi.
    ///
    /// Par les heuristiques, et non par le repère qu'on vient d'apprendre : on
    /// est au milieu d'une calibration, et s'appuyer sur ce qu'elle est en
    /// train de remplacer est précisément ce qui a produit le message « le
    /// message d'essai n'a pas pu être écrit » devant une zone où il était
    /// pourtant écrit. Le repère désignait le bloc autour de la zone ; on
    /// relisait donc un conteneur, qui n'a pas de texte à lui.
    func preparerCalibrationEnvoi() async -> Bool {
        charger()
        guard await attendreComposeur(secondes: 30, selecteur: "") else { return false }
        let limite = Date.now.addingTimeInterval(6)
        var essai = 0
        while Date.now < limite {
            if Task.isCancelled { return false }
            _ = try? await appeler("return window.__relais.ecrire(sel, texte);",
                                   ["sel": "", "texte": Self.essai])
            try? await Task.sleep(for: .milliseconds(500))
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": ""])
            if let texte = lu?["texte"] as? String, !texte.isEmpty {
                if essai > 0 { Log.info("relais : message d'essai écrit au \(essai + 1)e essai") }
                return true
            }
            essai += 1
        }
        return false
    }

    /// Calibre « Lire à haute voix », menu compris s'il y en a un.
    func calibrerLecture() async throws {
        let r = try await guetter("return await window.__relais.calibrerAvecMenu();", [:],
                                  .lecture)
        guard r["ok"] as? Bool == true else { throw CancellationError() }
        guard let sel = r["selecteur"] as? String, !sel.isEmpty else {
            throw Erreur.introuvable(.lecture)
        }
        selecteurs.lecture = sel
        selecteurs.lectureParent = (r["parent"] as? String) ?? ""
        selecteurs.lectureMenu = (r["menu"] as? String) ?? ""
        selecteurs.lectureMenuParent = (r["menuParent"] as? String) ?? ""
        selecteurs.enregistrer()
    }

    /// Fait renoncer une calibration qui attend un clic.
    func abandonnerCalibration() async {
        _ = try? await appeler("return window.__relais.abandonnerCalibration();")
    }

    /// Attend que la zone de saisie soit là et lisible.
    private func attendreComposeur(secondes: Double,
                                   selecteur: String? = nil) async -> Bool {
        let limite = Date.now.addingTimeInterval(secondes)
        while Date.now < limite {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
            // La navigation d'abord : une zone de saisie trouvée pendant le
            // chargement est celle de la page qu'on est en train de quitter.
            guard !chargementEnCours else { continue }
            let lu = try? await appeler("return window.__relais.lire(sel);",
                                        ["sel": selecteur ?? selecteurs.composeur])
            if lu?["ok"] as? Bool == true { return true }
        }
        return false
    }

    /// Attend que l'utilisateur clique un élément, et en retient un sélecteur.
    ///
    /// Le clic n'est pas intercepté : il atteint la page normalement. C'est
    /// nécessaire — le bouton d'arrêt n'existe dans le DOM que pendant
    /// l'enregistrement, donc il faut que le clic sur le micro ait réellement
    /// démarré l'écoute pour pouvoir désigner l'arrêt juste après.
    func calibrer(_ cible: RelaisCible) async throws -> String {
        let r = try await guetter("return await window.__relais.calibrer(genre);",
                                  ["genre": cible.genre], cible)
        guard r["ok"] as? Bool == true else { throw CancellationError() }
        guard let sel = r["selecteur"] as? String, !sel.isEmpty else {
            throw Erreur.introuvable(cible)
        }
        selecteurs[cible] = sel
        // Le bloc qui porte l'élément, retenu avec lui pour les boutons des
        // barres d'actions : la page en pose une sous chaque message, et seul
        // le couple dit de laquelle il s'agit.
        switch cible {
        case .copier: selecteurs.copierParent = (r["parent"] as? String) ?? ""
        case .lecture: selecteurs.lectureParent = (r["parent"] as? String) ?? ""
        default: break
        }
        selecteurs.enregistrer()
        return sel
    }

    /// Attend le clic qu'un guetteur de calibration espère, trois minutes au
    /// plus.
    ///
    /// C'est la seule attente du pont qui doit être longue — une main humaine
    /// lit la consigne, cherche le bouton, hésite — et elle n'en est pas moins
    /// bornée : une consigne oubliée derrière une autre fenêtre laissait la
    /// promesse attendre pour toujours, et le parcours avec elle. À
    /// l'échéance, le guetteur est retiré de la page, sans quoi il retiendrait
    /// comme repère le prochain clic de l'utilisateur, n'importe où dans
    /// ChatGPT.
    private func guetter(_ corps: String, _ args: [String: Any],
                         _ cible: RelaisCible) async throws -> [String: Any] {
        do {
            return try await appeler(corps, args, delai: Self.delaiClic)
        } catch Erreur.pontMuet {
            _ = try? await appeler("return window.__relais.abandonnerCalibration();")
            throw Erreur.calibrationSansClic(cible)
        }
    }
}
