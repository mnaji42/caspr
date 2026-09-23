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
            _ = await sonder { try await self.ecrire(Self.essai, sel: "") }
            try? await Task.sleep(for: .milliseconds(500))
            if await sonder({ try await self.lire(sel: "") })?.isEmpty == false {
                if essai > 0 { Log.info("relais : message d'essai écrit au \(essai + 1)e essai") }
                return true
            }
            essai += 1
        }
        return false
    }

    /// Calibre « Lire à haute voix », menu compris s'il y en a un.
    func calibrerLecture() async throws {
        let r = try await guetter(.lecture) { try await self.calibrerAvecMenu() }
        selecteurs.lecture = r.selecteur
        selecteurs.lectureParent = r.parent
        selecteurs.lectureMenu = r.menu
        selecteurs.lectureMenuParent = r.menuParent
        selecteurs.enregistrer()
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
            let sel = selecteur ?? selecteurs.composeur
            if await sonder({ try await self.lire(sel: sel) }) != nil { return true }
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
        let r = try await guetter(cible) { try await self.calibrer(genre: cible.genre) }
        selecteurs[cible] = r.selecteur
        // Le bloc qui porte l'élément, retenu avec lui pour les boutons des
        // barres d'actions : la page en pose une sous chaque message, et seul
        // le couple dit de laquelle il s'agit.
        switch cible {
        case .copier: selecteurs.copierParent = r.parent
        case .lecture: selecteurs.lectureParent = r.parent
        default: break
        }
        selecteurs.enregistrer()
        return r.selecteur
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
    ///
    /// La calibration n'est pas une dictée : ce délai-là attend une main, pas
    /// ChatGPT, et il reste. Une erreur de la page — elle a changé sous le
    /// guetteur — passe telle quelle : ce n'est pas trois minutes sans clic.
    ///
    /// Un guetteur abandonné rend `nil` : la calibration s'arrête. Un repère
    /// vide dit qu'aucun sélecteur ne désigne l'élément cliqué.
    private func guetter(_ cible: RelaisCible,
                         _ guetteur: @escaping @MainActor () async throws -> Repere?) async throws -> Repere {
        guard let issue = try await auPlus(.seconds(180), guetteur) else {
            await abandonnerCalibration()
            throw RelaisErreur.calibrationSansClic(cible)
        }
        guard let r = issue else { throw CancellationError() }
        guard !r.selecteur.isEmpty else { throw RelaisErreur.introuvable(cible) }
        return r
    }
}
