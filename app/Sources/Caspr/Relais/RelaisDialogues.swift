import AppKit
import CasprCore

/// Ce que le relais dit dans une alerte : les consignes de la calibration, son
/// rapport, le diagnostic, et leurs textes.
///
/// À part du parcours qui les montre, pour qu'on lise la calibration comme ce
/// qu'elle fait, et ce qu'elle dit comme un texte.
@MainActor
enum RelaisDialogues {

    // MARK: - Les alertes

    /// Une consigne, avec une porte de sortie.
    ///
    /// Un dialogue à un seul bouton force à aller au bout de ce qu'on a
    /// commencé. Pour un parcours de six étapes qui pilote une page web, c'est
    /// la garantie qu'un imprévu — une page qui ne réagit pas, un bouton
    /// introuvable — laisse quelqu'un coincé.
    @discardableResult
    static func demander(_ titre: String, _ texte: String) -> Bool {
        choisir(titre, texte, ["Continuer", "Abandonner"]) == 0
    }

    /// Une question à plusieurs issues ; rend le rang du bouton choisi.
    static func choisir(_ titre: String, _ texte: String, _ boutons: [String]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = titre
        a.informativeText = texte
        for bouton in boutons { a.addButton(withTitle: bouton) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func alerter(_ titre: String, _ texte: String) {
        _ = choisir(titre, texte, [])
    }

    // MARK: - La calibration automatique

    static let annonce = """
        Caspr va apprendre seul les boutons de la page, en les essayant sous vos \
        yeux, dans une conversation neuve :

        • le micro de la page s'ouvre une seconde, puis s'arrête — ce qu'il \
        entend est effacé ;
        • un message d'essai part réellement, un seul : « \(RelaisCalibration.essai) » ;
        • le bouton « copier » de la réponse est essayé, et votre presse-papiers \
        vous est rendu tel quel.

        Rien n'est enregistré tant que tout n'a pas marché : votre calibrage \
        actuel ne peut pas être abîmé. Comptez une demi-minute ; fermer la \
        fenêtre arrête tout.
        """

    static let lectureApresAutomatique = """
        Cliquez « Lire à haute voix » sous la réponse — le petit haut-parleur.

        S'il n'apparaît pas directement, ouvrez d'abord le menu « … » : Caspr \
        retient le chemin complet et le refera pour vous.
        """

    /// Ce que le parcours a trouvé et ce qui lui manque, repère par repère.
    static func rapport(_ issue: RelaisCalibrationAuto.Issue,
                        ancien: RelaisSelecteurs, enregistre: Bool) -> String {
        var lignes = RelaisPreuves.parcours.map { cible -> String in
            if issue.preuves.selecteurs[cible] != nil { return "✓ \(cible.libelle)" }
            let raison = issue.preuves.raisons[cible]
                ?? "pas essayé : une étape précédente a échoué"
            return "✗ \(cible.libelle) — \(raison)"
        }
        lignes.append(ancien.saitLire
            ? "✓ « Lire à haute voix » — gardé tel que vous l'aviez montré"
            : "– « Lire à haute voix » — facultatif, à montrer à la main")
        lignes.append("")
        lignes.append(issue.messageEnvoye
            ? "Un message d'essai est parti dans une conversation neuve."
            : "Aucun message n'a été envoyé.")
        if !enregistre {
            lignes.append(ancien.estCalibre
                ? "Rien n'a été enregistré : votre calibrage précédent est intact."
                : "Rien n'a été enregistré.")
            lignes.append("")
            lignes.append("Vous pouvez montrer les boutons à la main : c'est le même "
                          + "apprentissage, clic par clic.")
        }
        return lignes.joined(separator: "\n")
    }

    // MARK: - Le parcours manuel

    /// Un « copier » refusé par la page (cf. `guetter` du pont).
    /// Ce que la page a constaté, et le geste qui en découle.
    ///
    /// Le texte était fixe et n'énonçait qu'une des quatre causes possibles —
    /// « ce n'est pas le bouton de la réponse ». Opposé à un clic juste, il
    /// envoyait chercher une erreur là où il n'y en avait pas. La raison vient
    /// maintenant de `copierDesigne`, qui sait laquelle s'est produite.
    static func copierAilleurs(_ raison: String) -> String {
        let constat = raison.isEmpty
            ? "Ce bouton « copier » n'est pas celui de la réponse de ChatGPT."
            : "Caspr n'a pas pu retenir ce bouton : \(raison)."
        return constat + """


            La page pose un « copier » sous chaque message, le vôtre compris. \
            Désignez celui de la **dernière** réponse de la conversation — deux \
            carrés superposés, sous le dernier message de ChatGPT. Une réponse \
            plus ancienne ne convient pas.
            """
    }

    /// Un clic que la page a laissé passer, mais qui n'a rien copié.
    static let copierRien = """
        Ce clic n'a rien copié : ce n'est pas le bouton « copier ». Sous la \
        réponse de ChatGPT, désignez les deux carrés superposés.
        """

    static func finManuelle(saitLire: Bool) -> String {
        saitLire
            ? "Caspr sait dicter, envoyer, récupérer une réponse et la faire "
              + "lire à haute voix. Les modules qui en ont besoin sont "
              + "désormais utilisables."
            : "Caspr sait dicter, envoyer et récupérer une réponse. « Lire à "
              + "haute voix » n'a pas été appris : il est facultatif, et se "
              + "montre en relançant la calibration."
    }

    // MARK: - La session

    static func pageMuette(relance: String) -> String {
        """
        Elle ne s'est pas chargée en trente secondes : Caspr ne peut pas savoir \
        si vous êtes connecté. Elle vient d'être rechargée.

        Vérifiez votre connexion à Internet, puis relancez \(relance) \(ouRelancer) : \
        la fenêtre ChatGPT se rouvrira.
        """
    }

    static let seConnecter = """
        La fenêtre ChatGPT est ouverte derrière ce message. Créez un compte ou \
        connectez-vous : c'est votre compte, et Caspr ne se connecte jamais à \
        votre place.

        À savoir : « Continuer avec Google » ne fonctionne pas ici. Google refuse \
        volontairement ses connexions dans une fenêtre embarquée. Une adresse \
        e-mail et un mot de passe fonctionnent.

        La calibration reprendra d'elle-même si la conversation s'affiche \
        dans les dix minutes. Fermer la fenêtre l'arrête.
        """

    static func toujoursPasConnecte(relance: String) -> String {
        """
        Caspr a attendu dix minutes sans voir de conversation ChatGPT, et a \
        arrêté d'attendre. Une fois connecté, relancez \(relance) \(ouRelancer).
        """
    }

    /// Où relancer une calibration. Pendant l'accueil, les Réglages ne
    /// s'ouvrent pas — la garde ramène l'accueil à leur place (cf.
    /// `SetupRecoveryGuard`) — : renvoyer vers eux envoyait chercher un bouton
    /// derrière une porte fermée. La même carte les porte dans l'accueil.
    static var ouRelancer: String {
        SetupRecoveryGuard.shouldIntercept
            ? "à l'étape du premier essai de l'accueil, sous « Votre compte ChatGPT »"
            : "dans Réglages › Voie"
    }

    // MARK: - Le diagnostic

    /// Ce que le relais voit de la page, en clair.
    ///
    /// Quand un clic ne prend pas, la seule question utile est « sur quoi
    /// as-tu cliqué ? ». Sans cet écran, il n'y a aucun moyen de distinguer un
    /// sélecteur devenu caduc d'un bouton qui refuse de répondre, et le seul
    /// recours est de tout recalibrer en espérant.
    static func diagnostic(_ page: RelaisPage) async {
        let sel = page.selecteurs
        let connexion = await page.connexion(secondes: 1)
        let ecoute = await page.auRepos()?.enregistrement == true
        func ligne(_ nom: String, _ valeur: String) -> String {
            valeur.isEmpty ? "\(nom) : (non calibré — heuristique)" : "\(nom) : \(valeur)"
        }
        alerter("Diagnostic du relais", """
            Session : \(connexion == .connecte ? "connectée"
                        : connexion == .inconnu ? "la page ne le dit pas" : "pas connectée")
            Page : \(ecoute ? "en train d'écouter" : "au repos")
            Micro tenu par la page : \(page.microOuvert ? "oui" : "non")

            \(ligne("Micro", sel.micro))
            \(ligne("Arrêt", sel.stop))
            \(ligne("Zone de texte", sel.composeur))
            \(ligne("Réponse", sel.reponse))
            \(ligne("Copier", sel.copier))
            \(ligne("Bloc de copier", sel.copierParent))

            CE QUE LA PAGE OFFRE
            \(await page.structure())
            """)
    }
}
