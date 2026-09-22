import Foundation
import Testing
@testable import CasprCore

/// Ce qu'un module exige de la page, et la relecture de `relais.modules`.
///
/// `capacitesRequises` décide des pastilles que la barre propose : une
/// exigence de trop retire un module qu'on pouvait utiliser, et c'est arrivé à
/// « Brut », qui réclamait un bouton copier dont il ne se sert jamais. La
/// relecture, elle, décide si les réglages de l'utilisateur survivent à une
/// mise à jour.
@Suite("Modules du relais")
struct RelaisModuleTests {

    // MARK: - Ce que les modules livrés exigent

    /// « Brut » n'envoie rien : il ne peut exiger ni l'envoi ni la
    /// récupération de la réponse, quelle que soit la sortie choisie.
    @Test("Brut n'exige que le socle")
    func rawNeedsOnlyTheBase() {
        #expect(RelaisCatalogue.brut.capacitesRequises == [.dicter])
        #expect(!RelaisCatalogue.brut.capacitesRequises.contains(.recuperer))
    }

    @Test("Réorganiser exige d'envoyer et de récupérer la réponse")
    func reorganiseNeedsTheRoundTrip() {
        #expect(RelaisCatalogue.reorganiser.capacitesRequises
                == [.dicter, .envoyer, .recuperer])
    }

    /// « Discuter » n'écrit nulle part : la réponse reste à l'écran, il n'y a
    /// rien à rapatrier.
    @Test("Discuter exige d'envoyer, pas de récupérer")
    func discussNeedsToSendOnly() {
        #expect(RelaisCatalogue.discuter.capacitesRequises == [.dicter, .envoyer])
    }

    /// La lecture à haute voix est un réglage de l'utilisateur, et c'est lui
    /// qui ajoute l'exigence — pas la définition du module.
    @Test("Faire lire la réponse ajoute son exigence")
    func readingAloudAddsItsRequirement() {
        var d = RelaisCatalogue.discuter
        d.ditLaReponse = true
        #expect(d.capacitesRequises == [.dicter, .envoyer, .direAHauteVoix])
    }

    /// Qui n'a calibré que le micro et l'arrêt doit garder « Brut » sur la
    /// barre : c'est la seule pastille qui lui permette de dicter.
    @Test("Un calibrage minimal garde Brut, et lui seul")
    func minimalCalibrationKeepsRaw() {
        var s = RelaisSelecteurs()
        s.micro = ".m"
        s.stop = ".s"
        #expect(RelaisCatalogue.brut.estUtilisable(s))
        #expect(!RelaisCatalogue.reorganiser.estUtilisable(s))
        #expect(!RelaisCatalogue.discuter.estUtilisable(s))
        #expect(RelaisCatalogue.reorganiser.capacitesManquantes(s) == [.envoyer, .recuperer])

        s.envoi = ".e"
        s.copier = ".k"
        #expect(RelaisCatalogue.reorganiser.estUtilisable(s))
        #expect(RelaisCatalogue.discuter.estUtilisable(s))
    }

    // MARK: - Nature et réglages

    /// Un module livré prend sa nature de la version installée, et ses
    /// réglages de l'enregistrement : ni l'un ni l'autre n'écrase le reste.
    @Test("La fusion garde la définition livrée et les réglages enregistrés")
    func mergeKeepsNatureAndSettings() {
        var enregistre = RelaisCatalogue.reorganiser
        enregistre.nom = "Ancien nom"
        enregistre.actions = []
        enregistre.avant = "ma consigne"
        enregistre.apres = "ma fin"
        enregistre.affichage = .rien
        enregistre.ditLaReponse = true
        enregistre.sortieParDefaut = .note

        let fusion = RelaisCatalogue.reorganiser.avecLesReglagesDe(enregistre)
        #expect(fusion.nom == "Réorganiser")
        #expect(fusion.actions == [.demanderUneReponse])
        #expect(fusion.avant == "ma consigne")
        #expect(fusion.apres == "ma fin")
        #expect(fusion.affichage == .rien)
        #expect(fusion.ditLaReponse)
        #expect(fusion.sortieParDefaut == .note)
    }

    /// Une réponse qui ne vit qu'à l'écran impose la page — sauf si on
    /// l'écoute.
    @Test("Discuter impose la page, sauf s'il fait lire la réponse")
    func discussForcesThePage() {
        var d = RelaisCatalogue.discuter
        d.affichage = .rien
        #expect(d.affichageEffectif == .page)
        d.ditLaReponse = true
        #expect(d.affichageImpose == nil)
        #expect(d.affichageEffectif == .rien)
        #expect(RelaisCatalogue.brut.affichageImpose == nil)
    }

    // MARK: - Relecture

    private func relire(_ json: String) throws -> RelaisModule {
        try JSONDecoder().decode(RelaisModule.self, from: Data(json.utf8))
    }

    /// Seul l'identifiant est obligatoire : c'est lui qu'on enregistre, et
    /// sans lui on ne saurait pas à quel module rendre ses réglages.
    @Test("Un module réduit à son identifiant prend les valeurs par défaut")
    func identifierAloneGivesDefaults() throws {
        let m = try relire(#"{"identifiant":"perso"}"#)
        #expect(m.nom == "perso")
        #expect(!m.integre)
        #expect(m.avant.isEmpty && m.apres.isEmpty)
        #expect(m.consigne == .facultative)
        #expect(m.lectureProposee)
        #expect(!m.ditLaReponse)
        #expect(m.actions.isEmpty)
        #expect(m.sorties == [.curseur, .note])
        #expect(m.sortieParDefaut == .curseur)
        #expect(!m.ecranParDefaut)
        #expect(m.affichage == .barre)
        #expect(throws: DecodingError.self) { try relire("{}") }
    }

    /// Le format d'avant `consigne` : un booléen, traduit plutôt qu'ignoré.
    @Test("L'ancien booléen de consigne est traduit")
    func oldEssentialFlagIsTranslated() throws {
        let ancien = try relire(#"""
            {"identifiant":"reorganiser","nom":"Réorganiser","integre":true,
             "avant":"a","apres":"b","consigneEssentielle":true,
             "actions":["demanderUneReponse"],"sorties":["curseur","note"],
             "sortieParDefaut":"note","ecranParDefaut":false,"affichage":"page"}
            """#)
        #expect(ancien.consigne == .essentielle)
        #expect(ancien.avant == "a")
        #expect(ancien.sortieParDefaut == .note)
        #expect(ancien.affichage == .page)

        let facultatif = try relire(#"{"identifiant":"x","consigneEssentielle":false}"#)
        #expect(facultatif.consigne == .facultative)
    }

    private var tousLesModules: [RelaisModule] {
        let perso = RelaisModule(
            identifiant: "perso", nom: "Traduire",
            avant: "Traduis en anglais :\n", apres: "",
            consigne: .facultative, lectureProposee: true, ditLaReponse: true,
            actions: [.joindreEcran, .demanderUneReponse],
            sorties: [.curseur, .note, .aucune], sortieParDefaut: .note,
            ecranParDefaut: true, affichage: .rien)
        return [RelaisCatalogue.brut, RelaisCatalogue.reorganiser,
                RelaisCatalogue.discuter, perso]
    }

    @Test("Les modules survivent à l'aller-retour")
    func modulesRoundTrip() throws {
        let data = try JSONEncoder().encode(tousLesModules)
        #expect(try JSONDecoder().decode([RelaisModule].self, from: data) == tousLesModules)
        #expect(RelaisModule.liste(depuis: data) == tousLesModules)
    }

    /// Les clés que l'application a déjà écrites chez ses utilisateurs.
    @Test("Les clés enregistrées ne changent pas de nom")
    func keysAreStable() throws {
        let data = try JSONEncoder().encode(RelaisCatalogue.discuter)
        let objet = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(objet.keys) == [
            "identifiant", "nom", "integre", "avant", "apres", "consigne",
            "lectureProposee", "ditLaReponse", "actions", "sorties",
            "sortieParDefaut", "ecranParDefaut", "affichage",
        ])
    }

    /// Une liste où **un seul** module est illisible : une action à son
    /// ancien nom (`envoyer`, avant `demanderUneReponse`), un affichage d'une
    /// version plus récente, un module sans identifiant. Décodée d'un bloc,
    /// la liste entière était perdue ; seuls les fautifs doivent l'être.
    @Test("Un module illisible ne fait pas perdre les autres")
    func oneUnreadableModuleKeepsTheOthers() throws {
        let json = #"""
            [
              {"identifiant":"brut","nom":"Brut","integre":true,"affichage":"rien"},
              {"identifiant":"ancien","actions":["envoyer"]},
              {"identifiant":"perso","nom":"Traduire","avant":"Traduis :",
               "actions":["demanderUneReponse"]},
              {"identifiant":"futur","affichage":"flottant"},
              {"nom":"sans identifiant"},
              {"identifiant":"discuter","sortieParDefaut":"aucune","sorties":["aucune"]}
            ]
            """#
        let data = Data(json.utf8)

        // Ce que faisait le catalogue : tout ou rien.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([RelaisModule].self, from: data)
        }

        let lus = RelaisModule.liste(depuis: data)
        #expect(lus.map(\.identifiant) == ["brut", "perso", "discuter"])
        #expect(lus[0].affichage == .rien)
        #expect(lus[1].avant == "Traduis :")
        #expect(lus[1].actions == [.demanderUneReponse])
    }

    /// Ce qui n'est pas une liste ne se relit pas en modules : le catalogue
    /// retombe alors sur les modules livrés.
    @Test("Une donnée qui n'est pas une liste rend une liste vide")
    func nonListGivesNothing() {
        #expect(RelaisModule.liste(depuis: Data("{}".utf8)).isEmpty)
        #expect(RelaisModule.liste(depuis: Data("pas du json".utf8)).isEmpty)
        #expect(RelaisModule.liste(depuis: Data("[]".utf8)).isEmpty)
    }
}
