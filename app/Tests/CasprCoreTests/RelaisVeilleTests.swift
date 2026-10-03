import Foundation
import Testing
@testable import CasprCore

/// Ce qu'un relevé de la page prouve, et ce qu'il ne prouve pas.
///
/// Les attentes d'une dictée n'ont pas de fin : une preuve trop large jette
/// une dictée qui aboutissait, une preuve trop étroite laisse attendre
/// toujours. Chaque cas ici a coûté l'un ou l'autre.
@Suite("Veille du relais")
struct RelaisVeilleTests {

    private static func alerte(_ texte: String, reconnue: Bool = false,
                               reponse: RelaisInstantane.Reponse? = nil) -> RelaisInstantane {
        RelaisInstantane(reponse: reponse, echec: .init(texte: texte, reconnue: reconnue))
    }

    /// Les jugements d'une même veille sur une suite de relevés.
    private static func refus(apresEnvoi: Bool, _ vus: [RelaisInstantane]) -> [String?] {
        var veille = RelaisVeille(apresEnvoi: apresEnvoi)
        return vus.map { veille.refus($0) }
    }

    @Test("Un échec reconnu interrompt sur-le-champ, avant comme après l'envoi")
    func reconnuInterrompt() {
        for apresEnvoi in [false, true] {
            #expect(Self.refus(apresEnvoi: apresEnvoi, [Self.alerte("Je n'ai pas compris", reconnue: true)])
                    == ["Je n'ai pas compris"])
        }
    }

    /// Le texte d'un refus est lu dans la page : un relevé qui se trompe y
    /// prend les mots dictés. Le journal n'en garde que la longueur.
    @Test("Le journal tait le texte d'un refus, et dit les autres erreurs")
    func refusHorsDuJournal() {
        let dictee = "Il faut réessayer demain"
        #expect(!RelaisErreur.pourLeJournal(RelaisErreur.refusParChatGPT(dictee)).contains(dictee))
        #expect(RelaisErreur.pourLeJournal(RelaisErreur.pasConnecte)
                == RelaisErreur.pasConnecte.localizedDescription)
    }

    @Test("Avant l'envoi, une alerte inconnue ne compte jamais")
    func inconnueAvantLEnvoi() {
        let vus = Array(repeating: Self.alerte("Limite bientôt atteinte"), count: 10)
        #expect(Self.refus(apresEnvoi: false, vus) == Array(repeating: nil, count: 10))
    }

    /// Juste après l'envoi, la réponse met un instant à paraître : une
    /// bannière tombée dans ce creux ne doit pas passer pour un refus.
    @Test("Après l'envoi, une alerte inconnue compte au troisième relevé sans réponse")
    func inconnueApresLEnvoi() {
        let vu = Self.alerte("Quota atteint", reponse: .init())
        #expect(Self.refus(apresEnvoi: true, [vu, vu, vu]) == [nil, nil, "Quota atteint"])
    }

    /// Une bannière « limite bientôt atteinte » apparue pendant que la
    /// réponse s'écrit ne dit rien de cette réponse.
    @Test("Tant que ChatGPT répond, une alerte inconnue ne compte pas, et le compte repart")
    func inconnuePendantLaReponse() {
        let rien = Self.alerte("Bannière", reponse: .init())
        let vus = [rien, rien, Self.alerte("Bannière", reponse: .init(enCours: true)),
                   rien, rien, Self.alerte("Bannière", reponse: .init(nouvelles: 1)),
                   rien, rien, RelaisInstantane(reponse: .init()), rien, rien]
        #expect(Self.refus(apresEnvoi: true, vus).allSatisfy { $0 == nil })
    }

    @Test("La session : l'écran de connexion l'emporte ; rien de dit n'est pas « déconnecté »")
    func session() {
        #expect(RelaisVeille.session(RelaisInstantane(authentification: true, composeur: true, micro: true))
                == false)
        #expect(RelaisVeille.session(RelaisInstantane(composeur: true)) == true)
        // Pendant la dictée, la zone disparaît : l'arrêt suffit.
        #expect(RelaisVeille.session(RelaisInstantane(stop: true, enregistrement: true)) == true)
        #expect(RelaisVeille.session(RelaisInstantane()) == nil)
    }

    @Test("L'empreinte est la dernière ligne non vide de la consigne")
    func empreinte() {
        #expect(RelaisVeille.empreinte("Remets en ordre :\n\n---\n") == "---")
        #expect(RelaisVeille.empreinte("une ligne") == "une ligne")
        #expect(RelaisVeille.empreinte("") == "")
        // Des blancs ne se relisent pas tels quels dans la zone : rien à attendre.
        #expect(RelaisVeille.empreinte("\n  \n") == "")
        #expect(RelaisVeille.empreinte("\n=== FIN ===  ") == "=== FIN ===")
    }

    private static func stabilisation(_ zones: [String?]) -> [RelaisVeille.Stabilisation.Issue?] {
        var s = RelaisVeille.Stabilisation()
        return zones.map { s.juger($0) }
    }

    @Test("La transcription attend le retour de la zone, puis une seconde de calme")
    func stabilisation() {
        // La zone n'est pas revenue : rien, si longtemps que ce soit. Puis un
        // texte qui bouge n'est jamais rendu.
        let avant: [String?] = Array(repeating: nil, count: 40) + ["Bon", "Bonjour", "Bonjour à"]
        let issues = Self.stabilisation(avant + Array(repeating: "Bonjour à tous", count: 5))
        #expect(issues.dropLast().allSatisfy { $0 == nil })
        #expect(issues.last == .texte("Bonjour à tous"))
    }

    @Test("Une zone revenue et restée vide quatre secondes : rien n'a été dit")
    func zoneVide() {
        // Revenue, puis quinze relevés vides — dont un introuvable, vide aussi.
        let zones: [String?] = Array(repeating: "", count: 15) + [nil, ""]
        let issues = Self.stabilisation(zones)
        #expect(issues.dropLast().allSatisfy { $0 == nil })
        #expect(issues.last == .vide)
    }

    private static func finie(seuil: Int, _ reponses: [RelaisInstantane.Reponse?]) -> [Bool] {
        var f = RelaisVeille.ReponseFinie(seuil: seuil)
        return reponses.map { f.juger($0) }
    }

    @Test("La réponse est finie : nouvelle, plus en cours, et de même longueur")
    func reponseFinie() {
        // La réponse d'avant, finie et immobile, n'est pas celle qu'on attend ;
        // celle qui s'écrit non plus, ni une réponse vide.
        let pas: [RelaisInstantane.Reponse?] = Array(repeating: .init(nouvelles: 0, longueur: 50), count: 20)
            + [nil] + Array(repeating: .init(nouvelles: 1, enCours: true, longueur: 50), count: 20)
            + [.init(nouvelles: 1, longueur: 0)]
        let issues = Self.finie(seuil: 8, pas + Array(repeating: .init(nouvelles: 1, longueur: 80), count: 9))
        #expect(issues.dropLast().allSatisfy { !$0 })
        #expect(issues.last == true)

        // Le bouton « copier » du tour n'existe qu'une fois la réponse finie.
        #expect(Self.finie(seuil: 8, [.init(nouvelles: 1, longueur: 80, copierPret: true)]) == [true])
        // Déjà copiée : le premier relevé qui la montre finie suffit.
        #expect(Self.finie(seuil: 0, [.init(nouvelles: 1, enCours: true, longueur: 80),
                                      .init(nouvelles: 1, longueur: 80)]) == [false, true])
    }
}
