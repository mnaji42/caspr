import Foundation

/// L'attente d'une dictée ChatGPT, de l'arrêt de l'écoute à la livraison.
///
/// **Une échéance, une seule, fixée à l'arrêt.** Chaque phase avait son propre
/// budget, et ils s'additionnaient : la transcription suivait la durée
/// parlée, la stabilisation ajoutait une minute, la réponse repartait de trois
/// minutes au moins, la lecture de trois encore. Dix minutes de parole
/// pouvaient ainsi laisser la barre sur « Transcription… » trois quarts
/// d'heure, sans chrono ni issue affichée — le « ça charge en boucle » qu'on
/// prenait pour un gel.
///
/// Le plafond est celui de la transcription d'avant, désormais partagé entre
/// toutes les phases : trois minutes au moins, quatre fois la durée parlée
/// au-delà. On borne, on ne raccourcit pas. Une attente trop courte a déjà
/// détruit dix minutes de dictée qui aboutissait (cf. `arreterEtLire` dans
/// `RelaisPage`) ; celle-ci ne décide jamais qu'une étape est trop lente, elle
/// dit seulement quand il n'est plus raisonnable d'attendre la suivante.
///
/// Les attentes restent des **observations** — le retour de la zone de
/// saisie, l'apparition du bouton « copier ». L'échéance ne remplace aucune
/// d'elles par un chronomètre : elle leur fixe une fin commune, et un nom pour
/// l'échec.
@MainActor
final class RelaisAttente: ObservableObject {
    /// Ce qu'on attend de ChatGPT à cet instant.
    ///
    /// Publiée pour que la barre le dise : « Transcription… » pendant que
    /// ChatGPT répond, c'était annoncer une étape déjà franchie, et le temps
    /// passé ne se lisait nulle part.
    enum Phase: String {
        case transcription
        case envoi
        case reponse
        case lecture

        /// Le libellé de la barre, en quelques mots.
        var libelle: String {
            switch self {
            case .transcription: "ChatGPT transcrit…"
            case .envoi: "Envoi à ChatGPT…"
            case .reponse: "ChatGPT répond…"
            case .lecture: "Lecture à haute voix…"
            }
        }
    }

    /// Pourquoi l'attente a pris fin sans résultat : l'échéance est passée,
    /// et voici où l'on en était.
    ///
    /// La phase est ce qui rend l'échec lisible. « Pas de réponse » ne dit pas
    /// si ChatGPT n'a jamais rendu la transcription — le texte est peut-être
    /// encore dans la page — ou s'il l'a rendue et n'a pas répondu ensuite, ce
    /// qui laisse le brut déjà lu, donc inséré.
    struct Abandon: Equatable {
        let phase: Phase
        let budget: TimeInterval

        var raisonCourte: String {
            let duree = RelaisAttente.duree(budget)
            return switch phase {
            case .transcription: "ChatGPT n'a pas transcrit en \(duree)"
            case .envoi: "ChatGPT n'a pas pris le message en \(duree)"
            case .reponse, .lecture: "ChatGPT n'a pas répondu en \(duree)"
            }
        }

        /// Le message complet, pour le menu. Ce qui reste récupérable, le
        /// contrôleur l'ajoute lui-même : il sait mieux que l'attente si la
        /// page a survécu.
        var explication: String {
            switch phase {
            case .transcription:
                "\(raisonCourte) : l'attente est abandonnée, la page n'a pas été rechargée"
            case .envoi, .reponse, .lecture:
                "\(raisonCourte) : la transcription brute a été gardée"
            }
        }
    }

    let debut: Date
    let echeance: Date
    let budget: TimeInterval
    @Published private(set) var phase: Phase = .transcription

    /// - Parameter secondesDictees: la durée parlée, à l'horloge. Une
    ///   transcription s'allonge avec elle : quelques secondes pour trente
    ///   secondes de parole, bien plus pour dix minutes.
    init(secondesDictees: Double, maintenant: Date = .now) {
        budget = Self.budget(secondesDictees: secondesDictees)
        debut = maintenant
        echeance = maintenant.addingTimeInterval(budget)
    }

    nonisolated static func budget(secondesDictees: Double) -> TimeInterval {
        max(180, secondesDictees * 4)
    }

    var ecoule: TimeInterval { Date.now.timeIntervalSince(debut) }
    var expiree: Bool { Date.now >= echeance }
    var abandon: Abandon { Abandon(phase: phase, budget: budget) }

    func entrer(_ nouvelle: Phase) {
        guard nouvelle != phase else { return }
        Log.info("relais : \(phase.rawValue) → \(nouvelle.rawValue) "
                 + "après \(String(format: "%.1f", ecoule)) s")
        phase = nouvelle
    }

    /// La fin d'une attente locale, jamais au-delà de l'échéance.
    ///
    /// Pour les observations courtes qui gardent leur propre borne — un bouton
    /// qui doit exister dans les dix secondes, sans quoi il est absent. Ces
    /// bornes disent « absent », pas « trop lent » : elles restent, mais
    /// aucune ne peut repousser la fin de la dictée.
    ///
    /// Ce qui suit une observation réussie n'y passe pas : voir immobile la
    /// transcription revenue, ramasser la copie d'une réponse finie, cliquer
    /// « lire à haute voix » sous elle. Ces gestes n'attendent plus ChatGPT,
    /// et les couper à l'échéance jetterait un résultat déjà obtenu.
    func limite(dans secondes: TimeInterval) -> Date {
        min(Date.now.addingTimeInterval(secondes), echeance)
    }

    /// Lève l'abandon si l'échéance est passée.
    ///
    /// Appelée là où une attente vient d'échouer : c'est elle qui départage
    /// « l'élément n'est pas venu » de « le temps de la dictée est écoulé »,
    /// deux échecs qui ne se réparent pas au même endroit.
    func verifier() throws {
        if expiree { throw epuisee() }
    }

    /// L'erreur de l'échéance passée, pour les attentes qui ne s'arrêtent
    /// qu'à elle. Journalisée ici, pour que chaque abandon dise sa phase.
    func epuisee() -> RelaisPage.Erreur {
        Log.error("relais : échéance de \(Self.duree(budget)) dépassée, "
                  + "phase \(phase.rawValue)")
        return .attenteEpuisee(abandon)
    }

    /// Une durée en minutes rondes : l'échéance vaut trois minutes au moins,
    /// et les secondes n'ajouteraient que du bruit à un message d'échec.
    nonisolated static func duree(_ secondes: TimeInterval) -> String {
        "\(max(1, Int((secondes / 60).rounded()))) min"
    }
}
