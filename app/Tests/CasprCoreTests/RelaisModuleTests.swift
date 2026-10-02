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
        enregistre.envoi = .aucun
        enregistre.consigne = .facultative
        enregistre.avant = "ma consigne"
        enregistre.apres = "ma fin"
        enregistre.affichage = .rien
        enregistre.ditLaReponse = true

        let fusion = RelaisCatalogue.reorganiser.avecLesReglagesDe(enregistre)
        #expect(fusion.nom == "Réorganiser")
        #expect(fusion.envoi == .remplacer)
        #expect(fusion.consigne == .essentielle)
        #expect(fusion.avant == "ma consigne")
        #expect(fusion.apres == "ma fin")
        #expect(fusion.affichage == .rien)
        #expect(fusion.ditLaReponse)
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
        #expect(m.envoi == .aucun)
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
        #expect(ancien.envoi == .remplacer)
        #expect(ancien.affichage == .page)

        let facultatif = try relire(#"{"identifiant":"x","consigneEssentielle":false}"#)
        #expect(facultatif.consigne == .facultative)
    }

    private var tousLesModules: [RelaisModule] {
        let perso = RelaisModule(
            identifiant: "perso", nom: "Traduire",
            avant: "Traduis en anglais :\n", apres: "",
            consigne: .facultative, lectureProposee: true, ditLaReponse: true,
            envoi: .remplacer, affichage: .rien)
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
            "lectureProposee", "ditLaReponse", "envoi", "affichage",
            "actions", "sorties", "sortieParDefaut",
        ])
    }

    /// `ecranParDefaut` a été écrit dans chaque module enregistré tant que
    /// « Joindre l'écran », jamais construite, existait. La clé y reste : elle
    /// doit être ignorée, et non faire perdre le module et sa consigne.
    @Test("Un module enregistré avec l'ancienne clé de capture se relit")
    func oldScreenCaptureKeyIsIgnored() throws {
        let data = Data(#"""
            [{"identifiant":"reorganiser","nom":"Réorganiser","integre":true,
              "avant":"Ma consigne","apres":"","consigne":"essentielle",
              "actions":["demanderUneReponse"],"sorties":["curseur","note"],
              "sortieParDefaut":"note","ecranParDefaut":true,"affichage":"page"}]
            """#.utf8)
        let lus = RelaisModule.liste(depuis: data)
        #expect(lus.count == 1)
        #expect(lus.first?.avant == "Ma consigne")
        #expect(lus.first?.envoi == .remplacer)
    }

    /// Une liste où des modules sont illisibles : un affichage d'une
    /// version plus récente, un module sans identifiant. Décodée d'un bloc,
    /// la liste entière était perdue ; seuls les fautifs doivent l'être. Une
    /// action que cette version ne connaît plus (`joindreEcran`, rangée par
    /// `main`) ne rend pas le module illisible : elle est ignorée.
    @Test("Un module illisible ne fait pas perdre les autres")
    func oneUnreadableModuleKeepsTheOthers() throws {
        let json = #"""
            [
              {"identifiant":"brut","nom":"Brut","integre":true,"affichage":"rien"},
              {"identifiant":"ecran","actions":["joindreEcran","demanderUneReponse"]},
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
        #expect(lus.map(\.identifiant) == ["brut", "ecran", "perso", "discuter"])
        #expect(lus[0].affichage == .rien)
        #expect(lus[1].envoi == .remplacer)
        #expect(lus[2].avant == "Traduis :")
        #expect(lus[2].envoi == .remplacer)
    }

    /// Ce qui n'est pas une liste ne se relit pas en modules : le catalogue
    /// retombe alors sur les modules livrés.
    @Test("Une donnée qui n'est pas une liste rend une liste vide")
    func nonListGivesNothing() {
        #expect(RelaisModule.liste(depuis: Data("{}".utf8)).isEmpty)
        #expect(RelaisModule.liste(depuis: Data("pas du json".utf8)).isEmpty)
        #expect(RelaisModule.liste(depuis: Data("[]".utf8)).isEmpty)
    }

    // MARK: - L'envoi, et ce qu'il exige

    /// Ce que chaque envoi exige, pour un module écrit par l'utilisateur
    /// comme pour un livré (87, 156).
    @Test("Les capacités se déduisent de l'envoi")
    func capabilitiesFollowTheSending() {
        var m = RelaisModule(identifiant: "x", nom: "X")
        #expect(m.capacitesRequises == [.dicter])
        m.envoi = .remplacer
        #expect(m.capacitesRequises == [.dicter, .envoyer, .recuperer])
        m.envoi = .discuter
        #expect(m.capacitesRequises == [.dicter, .envoyer])
        m.ditLaReponse = true
        #expect(m.capacitesRequises == [.dicter, .envoyer, .direAHauteVoix])
    }

    /// `ecrit` est le seul prédicat de destination, et c'est lui qui impose
    /// la page à un module de l'utilisateur qui discute (160).
    @Test("Un module qui discute n'écrit pas, et impose la page")
    func discussingModuleWritesNowhere() {
        var m = RelaisModule(identifiant: "x", nom: "X", envoi: .discuter, affichage: .barre)
        #expect(!m.ecrit)
        #expect(m.affichageEffectif == .page)
        m.envoi = .remplacer
        #expect(m.ecrit)
        #expect(m.affichageImpose == nil)
    }

    // MARK: - Les formes d'avant l'envoi

    /// Chaque forme que les versions antérieures ont écrite : l'envoi s'en
    /// déduit, et rien d'autre ne se perd.
    @Test("Les actions et la sortie d'avant se traduisent en envoi")
    func oldActionsAndOutputBecomeSending() throws {
        let discuter = try relire(#"""
            {"identifiant":"discuter","actions":["demanderUneReponse"],
             "sorties":["aucune"],"sortieParDefaut":"aucune","ditLaReponse":true}
            """#)
        #expect(discuter.envoi == .discuter)
        #expect(discuter.ditLaReponse)
        let remplacer = try relire(#"""
            {"identifiant":"t","actions":["demanderUneReponse"],"sortieParDefaut":"note"}
            """#)
        #expect(remplacer.envoi == .remplacer)
        let aucun = try relire(#"{"identifiant":"b","actions":[],"sortieParDefaut":"curseur"}"#)
        #expect(aucun.envoi == .aucun)
        // L'envoi, quand il est là, l'emporte sur ce qu'une version antérieure
        // aurait laissé à côté.
        let neuf = try relire(#"{"identifiant":"n","envoi":"discuter","actions":[]}"#)
        #expect(neuf.envoi == .discuter)
    }

    /// Le module tel que le décodent les versions d'avant l'envoi — `main`
    /// (90f00e4) et la refonte jusqu'à l'étape 9 : chaque clé facultative,
    /// mais des actions, des sorties, une consigne et un affichage qui doivent
    /// exister chez elles, dans une liste décodée d'un bloc — une seule
    /// valeur inconnue leur ferait tout perdre.
    private struct ModuleDAvant: Decodable, Equatable {
        enum Action: String, Decodable { case joindreEcran, demanderUneReponse, direLaReponse }
        enum Sortie: String, Decodable { case curseur, note, aucune }
        enum Consigne: String, Decodable { case aucune, facultative, essentielle }
        enum Affichage: String, Decodable { case rien, barre, page }
        let identifiant: String, nom: String, integre: Bool, avant: String, apres: String
        let consigne: Consigne?, lectureProposee: Bool, ditLaReponse: Bool, ecranParDefaut: Bool
        let actions: [Action], sorties: [Sortie], sortieParDefaut: Sortie, affichage: Affichage

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            identifiant = try c.decode(String.self, forKey: .identifiant)
            nom = try c.decodeIfPresent(String.self, forKey: .nom) ?? identifiant
            integre = try c.decodeIfPresent(Bool.self, forKey: .integre) ?? false
            avant = try c.decodeIfPresent(String.self, forKey: .avant) ?? ""
            apres = try c.decodeIfPresent(String.self, forKey: .apres) ?? ""
            consigne = try c.decodeIfPresent(Consigne.self, forKey: .consigne)
            lectureProposee = try c.decodeIfPresent(Bool.self, forKey: .lectureProposee) ?? true
            ditLaReponse = try c.decodeIfPresent(Bool.self, forKey: .ditLaReponse) ?? false
            ecranParDefaut = try c.decodeIfPresent(Bool.self, forKey: .ecranParDefaut) ?? false
            actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
            sorties = try c.decodeIfPresent([Sortie].self, forKey: .sorties) ?? [.curseur, .note]
            sortieParDefaut = try c.decodeIfPresent(Sortie.self, forKey: .sortieParDefaut) ?? .curseur
            affichage = try c.decodeIfPresent(Affichage.self, forKey: .affichage) ?? .barre
        }

        private enum CodingKeys: String, CodingKey {
            case identifiant, nom, integre, avant, apres, consigne, lectureProposee,
                 ditLaReponse, ecranParDefaut, actions, sorties, sortieParDefaut, affichage
        }
    }

    /// Le propriétaire peut réinstaller un build antérieur : « Discuter »
    /// doit y rester Discuter, et un module à consigne y envoyer encore (le
    /// souci de 323b6e5 avec l'historique d'une 0.14).
    @Test("Les modules écrits aujourd'hui se relisent dans une version d'avant")
    func olderVersionReadsTodaysModules() throws {
        let data = try JSONEncoder().encode(tousLesModules)
        let lus = try JSONDecoder().decode([ModuleDAvant].self, from: data)
        #expect(lus.map(\.identifiant) == ["brut", "reorganiser", "discuter", "perso"])
        #expect(lus[0].actions == [] && lus[0].sortieParDefaut == .curseur)
        #expect(lus[1].actions == [.demanderUneReponse] && lus[1].sortieParDefaut == .curseur)
        #expect(lus[2].actions == [.demanderUneReponse] && lus[2].sortieParDefaut == .aucune)
        #expect(lus[2].sorties == [.aucune])
        #expect(lus[3].actions == [.demanderUneReponse] && lus[3].avant == "Traduis en anglais :\n")
        #expect(lus[3].affichage == .rien && lus[3].ditLaReponse)
    }

    /// Réécrits par une version d'avant, qui laisse tomber `envoi`, les
    /// modules reviennent tels quels.
    @Test("Un module réécrit sans son envoi revient tel quel")
    func moduleRewrittenWithoutSendingComesBack() throws {
        let data = try JSONEncoder().encode(tousLesModules)
        var objets = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for i in objets.indices { objets[i]["envoi"] = nil }
        let relus = RelaisModule.liste(depuis: try JSONSerialization.data(withJSONObject: objets))
        #expect(relus == tousLesModules)
    }

    // MARK: - Le catalogue

    private func calibre(envoi: Bool = false, copier: Bool = false) -> RelaisSelecteurs {
        var s = RelaisSelecteurs()
        (s.micro, s.stop) = (".m", ".s")
        if envoi { s.envoi = ".e" }
        if copier { s.copier = ".k" }
        return s
    }

    /// Un livré garde sa nature et reprend les réglages (157) ; un livré
    /// absent est ajouté, un module de l'utilisateur gardé (158).
    @Test("La fusion ajoute les livrés absents et garde les modules de l'utilisateur")
    func mergeAddsMissingBuiltInsAndKeepsUserModules() {
        var brut = RelaisCatalogue.brut
        brut.affichage = .rien
        brut.nom = "Vieux nom"
        let perso = RelaisModule(identifiant: "perso", nom: "Traduire", envoi: .remplacer)
        let tous = RelaisCatalogue.fusion([perso, brut])
        #expect(tous.map(\.identifiant) == ["perso", "brut", "reorganiser", "discuter"])
        #expect(tous[1].nom == "Brut" && tous[1].affichage == .rien)
        #expect(tous[0] == perso)
        #expect(RelaisCatalogue.fusion([]) == RelaisCatalogue.livres)
    }

    /// La barre et la dictée lisent le même : le choisi s'il est
    /// utilisable, sinon Brut — tel que l'utilisateur l'a réglé.
    @Test("Le module retenu est le choisi s'il est utilisable, sinon Brut")
    func retainedIsChosenOrRaw() {
        var brut = RelaisCatalogue.brut
        brut.affichage = .page
        let modules = RelaisCatalogue.fusion([brut])
        let minimal = calibre()
        #expect(RelaisCatalogue.retenu("discuter", parmi: modules, selecteurs: minimal) == brut)
        #expect(RelaisCatalogue.retenu("inconnu", parmi: modules, selecteurs: minimal) == brut)
        let complet = calibre(envoi: true, copier: true)
        #expect(RelaisCatalogue.retenu("discuter", parmi: modules, selecteurs: complet).identifiant == "discuter")
        #expect(RelaisCatalogue.retenu("x", parmi: [], selecteurs: complet) == RelaisCatalogue.brut)
    }

    @Test("Un module créé n'est pas intégré, et seul lui se supprime")
    func createdModuleIsTheOnlyOneDeleted() {
        var modules = RelaisCatalogue.livres
        let un = RelaisCatalogue.ajouter(nom: "Traduire en anglais", a: &modules)
        let deux = RelaisCatalogue.ajouter(nom: "Traduire en anglais", a: &modules)
        #expect(!un.integre && un.envoi == .remplacer && un.consigne == .facultative)
        #expect(un.identifiant != deux.identifiant)
        #expect(modules.count == 5)
        RelaisCatalogue.supprimer(un.identifiant, de: &modules)
        RelaisCatalogue.supprimer("brut", de: &modules)
        #expect(modules.map(\.identifiant) == ["brut", "reorganiser", "discuter", deux.identifiant])
    }

    // MARK: - Ce que `main` a rangé

    /// Le calibrage tel que le rangeait `main` (90f00e4), la version dont le
    /// propriétaire se sert : l'encodage synthétisé, toutes les clés.
    private let selecteursDeMain = #"""
        {"micro":"button[aria-label=\"Bouton de dictée\"]","stop":"button[aria-label=\"Arrêter\"]",
         "composeur":"#prompt-textarea","envoi":"#composer-submit-button","reponse":"",
         "copier":"button[data-testid=\"copy-turn-action-button\"]","copierParent":"article",
         "lecture":"button[aria-label=\"Lire à haute voix\"]","lectureParent":"article",
         "lectureMenu":"","lectureMenuParent":""}
        """#

    /// Ses trois modules, réglés : un affichage changé partout, une consigne
    /// réécrite, « Discuter » qui fait lire sa réponse sans rien montrer.
    private let modulesDeMain = #"""
        [{"identifiant":"brut","nom":"Brut","integre":true,"avant":"","apres":"",
          "consigne":"aucune","lectureProposee":false,"ditLaReponse":false,"actions":[],
          "sorties":["curseur","note"],"sortieParDefaut":"curseur","ecranParDefaut":false,
          "affichage":"page"},
         {"identifiant":"reorganiser","nom":"Réorganiser","integre":true,
          "avant":"Ma consigne\n","apres":"\nFin","consigne":"essentielle",
          "lectureProposee":false,"ditLaReponse":false,"actions":["demanderUneReponse"],
          "sorties":["curseur","note"],"sortieParDefaut":"curseur","ecranParDefaut":false,
          "affichage":"rien"},
         {"identifiant":"discuter","nom":"Discuter","integre":true,"avant":"","apres":"",
          "consigne":"aucune","lectureProposee":true,"ditLaReponse":true,
          "actions":["demanderUneReponse"],"sorties":["aucune"],"sortieParDefaut":"aucune",
          "ecranParDefaut":false,"affichage":"rien"}]
        """#

    /// Ce que `main` a rangé se relit à l'identique, puis, rangé de nouveau
    /// par cette version, se relit à l'identique dans `main` : la mise à
    /// jour ne coûte ni le calibrage ni les réglages des modules, et revenir
    /// en arrière non plus (85, 114, 139, 157).
    @Test("Le calibrage et les modules rangés par main se relisent, dans les deux sens")
    func mainSettingsSurviveBothWays() throws {
        let d = ReglagesEnMemoire()
        d.set(Data(selecteursDeMain.utf8), forKey: "relais.selecteurs")
        d.set(Data(modulesDeMain.utf8), forKey: "relais.modules")
        d.set("discuter", forKey: "relais.mode")
        d.set("barre", forKey: "relais.affichage")
        #expect(RelaisCatalogue.migrer(d).isEmpty)

        let s = RelaisCatalogue.selecteurs(dans: d)
        #expect(s.estCalibre && s.saitLire && s.copierParent == "article")
        let modules = RelaisCatalogue.modules(dans: d)
        #expect(modules.map(\.identifiant) == ["brut", "reorganiser", "discuter"])
        #expect(modules.map(\.envoi) == [.aucun, .remplacer, .discuter])
        #expect(modules.map(\.affichage) == [.page, .rien, .rien])
        #expect(modules[1].avant == "Ma consigne\n" && modules[1].apres == "\nFin")
        #expect(modules[2].ditLaReponse && modules[2].affichageEffectif == .rien)
        #expect(RelaisCatalogue.retenu("discuter", parmi: modules, selecteurs: s) == modules[2])

        RelaisCatalogue.ranger(s, sous: RelaisCatalogue.cleSelecteurs, dans: d)
        RelaisCatalogue.ranger(modules, sous: RelaisCatalogue.cleModules, dans: d)
        func objet(_ data: Data?) throws -> NSDictionary? {
            try JSONSerialization.jsonObject(with: try #require(data)) as? NSDictionary
        }
        #expect(try objet(d.data(forKey: "relais.selecteurs")) == objet(Data(selecteursDeMain.utf8)))
        let avant = try JSONDecoder().decode([ModuleDAvant].self, from: Data(modulesDeMain.utf8))
        let apres = try JSONDecoder().decode([ModuleDAvant].self,
                                             from: try #require(d.data(forKey: "relais.modules")))
        #expect(apres == avant)
    }

    // MARK: - Migration

    @Test("Les clés de rangement ne changent pas de nom")
    func storageKeysAreStable() {
        #expect(RelaisCatalogue.cleModules == "relais.modules")
        #expect(RelaisCatalogue.cleMode == "relais.mode")
        #expect(RelaisCatalogue.cleSelecteurs == "relais.selecteurs")
        #expect(RelaisCatalogue.cleAffichage == "relais.affichage")
        #expect(RelaisCatalogue.cleDepart == "relais.pointDeDepart")
    }

    /// L'ancien affichage global va aux livrés qui écrivent et n'étaient pas
    /// encore enregistrés ; un réglage fait depuis n'est pas écrasé (161).
    @Test("L'ancien affichage et les anciens noms de mode se traduisent, une fois")
    func oldDisplayAndModeAreMigratedOnce() throws {
        let d = ReglagesEnMemoire()
        var brut = RelaisCatalogue.brut
        brut.affichage = .rien
        d.set(try JSONEncoder().encode([brut]), forKey: "relais.modules")
        d.set("page", forKey: "relais.affichage")
        d.set("auPropre", forKey: "relais.mode")

        #expect(RelaisCatalogue.migrer(d).count == 2)
        let modules = RelaisModule.liste(depuis: try #require(d.data(forKey: "relais.modules")))
        #expect(modules.map(\.identifiant) == ["brut", "reorganiser", "discuter"])
        #expect(modules.map(\.affichage) == [.rien, .page, .page])
        #expect(d.string(forKey: "relais.mode") == "reorganiser")
        // La clé reste, pour une version antérieure relancée ; rien n'est refait.
        #expect(d.string(forKey: "relais.affichage") == "page")
        #expect(RelaisCatalogue.migrer(d).isEmpty)

        let vierge = ReglagesEnMemoire()
        vierge.set("rien", forKey: "relais.affichage")
        vierge.set("rediger", forKey: "relais.mode")
        _ = RelaisCatalogue.migrer(vierge)
        let livres = RelaisModule.liste(depuis: try #require(vierge.data(forKey: "relais.modules")))
        #expect(livres.map(\.affichage) == [.rien, .rien, .page])
        #expect(vierge.string(forKey: "relais.mode") == "brut")
        #expect(RelaisCatalogue.migrer(ReglagesEnMemoire()).isEmpty)
    }
}
