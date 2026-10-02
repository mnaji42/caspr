import Foundation

// Ce qui mesure le temps sur le chemin d'une dictée : l'horloge, les seuls
// délais qui restent, et l'appel dont on peut cesser d'attendre la réponse.
//
// LA RÈGLE (RELAIS.md, sixième règle). Une attente de ChatGPT ne finit que
// par un geste de l'utilisateur ou par un échec que la page PROUVE — jamais
// par le temps. Le propriétaire, le 24 septembre 2026 : « Des fois ça prend
// dix, vingt, trente secondes… Donc non, il n'y a pas de limite. »

/// Le temps du scénario : le vrai dans l'application, une horloge qu'on
/// avance à la main dans les tests — cinq minutes de ChatGPT s'y rejouent en
/// un instant.
@MainActor
public protocol RelaisHorloge: AnyObject {
    var maintenant: ContinuousClock.Instant { get }
    /// Cède à l'annulation, comme `Task.sleep`.
    func dormir(_ duree: Duration) async throws
}

@MainActor
public final class RelaisHorlogeReelle: RelaisHorloge {
    nonisolated public init() {}
    public var maintenant: ContinuousClock.Instant { .now }
    public func dormir(_ duree: Duration) async throws { try await Task.sleep(for: duree) }
}

/// LA liste des délais qui restent sur le chemin d'une dictée. Il n'en existe
/// aucun autre.
///
/// Chacun prouve l'**effet d'un geste** de Caspr — un bouton qui doit exister,
/// un clic qui doit prendre —, et rattrape un geste raté, jamais une réponse
/// lente. Dans le doute, pas de délai. Chaque appel qui en passe un dit
/// pourquoi. Dépassé, il lève son erreur : le geste n'a pas pris.
///
/// Deux durées restent hors de la liste, parce qu'elles ne mettent fin à
/// aucune attente : la pause qui laisse s'ouvrir le menu de la lecture à
/// haute voix, et la seconde qu'un abandon accorde à une copie déjà partie
/// pour la défaire — l'utilisateur est alors déjà sorti.
public struct RelaisDelai {
    public let nom: String
    public let duree: Duration
    public let erreur: RelaisErreur
    private init(_ nom: String, _ secondes: Int, _ erreur: RelaisErreur) {
        (self.nom, duree, self.erreur) = (nom, .seconds(secondes), erreur)
    }

    /// Le bouton micro existe dès que la page s'est dite connectée.
    public static let micro = RelaisDelai("micro", 8, .introuvable(.micro))
    /// Après le clic du micro, la page capte : micro tenu, ou enregistrement.
    public static let ecoute = RelaisDelai("ecoute", 5, .ecouteNonOuverte)
    /// Le bouton d'arrêt existe pendant l'écoute.
    public static let arret = RelaisDelai("arret", 15, .introuvable(.stop))
    /// Ce qu'on vient d'écrire se relit aussitôt, ou n'a pas pris ; six
    /// secondes laissent large à une machine qui rame.
    public static let consigne = RelaisDelai("consigne", 6, .consigneNonPosee)
    /// Le bouton d'envoi existe dès que la zone est remplie.
    public static let envoi = RelaisDelai("envoi", 10, .introuvable(.envoi))
    /// ChatGPT vide la zone à l'instant du clic, sans attendre le réseau :
    /// après le clic, le message a quitté la zone, ou une réponse commence.
    public static let depart = RelaisDelai("depart", 10, .envoiSansEffet)
    /// La réponse est finie et le clic parti : la copie atterrit dans
    /// l'instant.
    public static let copie = RelaisDelai("copie", 10, .pasDeReponse)
    /// La barre d'actions d'une réponse finie s'affiche juste après la fin
    /// de la génération, pas au même instant.
    public static let lecture = RelaisDelai("lecture", 5, .introuvable(.lecture))
    /// Après un appui abandonné juste après le clic du micro, la page se met
    /// à écouter en trois secondes au plus…
    public static let ecouteApresAbandon = RelaisDelai("ecouteApresAbandon", 3, .ecouteNonOuverte)
    /// … et son bouton d'arrêt paraît en cinq.
    public static let arretApresAbandon = RelaisDelai("arretApresAbandon", 5, .introuvable(.stop))
}

/// Un appel dont on peut cesser d'attendre la réponse, à tout instant.
///
/// Deux concurrents se disputent l'issue : la réponse, et l'annulation de la
/// tâche qui attend. Le premier arrivé gagne, l'autre est ignoré. C'est ce qui
/// rend la main à la touche de dictée sur-le-champ, même quand l'appel ne
/// revient jamais : `callAsyncJavaScript` ne s'annule pas, et une page au fil
/// JavaScript bloqué ne répond plus du tout. On ne l'arrête pas dans la page,
/// on cesse seulement de l'attendre ici.
///
/// Aucun minuteur : une réponse lente n'est pas une réponse absente, et ce
/// n'est pas au temps de décider qu'on renonce.
///
/// Une continuation ne se reprend qu'une fois ; l'issue arrivée avant qu'on
/// l'attende — une tâche déjà annulée — est gardée, et rendue à l'attache.
@MainActor
public final class AppelAnnulable<Valeur> {
    private var suite: CheckedContinuation<Valeur, Error>?
    private var issue: Result<Valeur, Error>?

    public init() {}

    public func attacher(_ suite: CheckedContinuation<Valeur, Error>) {
        if let issue { suite.resume(with: issue) } else { self.suite = suite }
    }

    /// Propose une issue ; ignorée si une autre l'a devancée.
    public func rendre(_ resultat: Result<Valeur, Error>) {
        guard issue == nil else { return }
        issue = resultat
        suite?.resume(with: resultat)
        suite = nil
    }

    /// Attend l'issue. L'annulation de la tâche appelante la tranche en
    /// `CancellationError`, sans attendre la réponse.
    public func attendre() async throws -> Valeur {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { attacher($0) }
        } onCancel: {
            Task { @MainActor in self.rendre(.failure(CancellationError())) }
        }
    }

    /// Fait `operation` en cessant de l'attendre dès que la tâche appelante
    /// est annulée, qu'elle cède ou non à l'annulation.
    public static func appeler(_ operation: @escaping @MainActor () async throws -> Valeur) async throws -> Valeur {
        let appel = AppelAnnulable()
        let tache = Task { @MainActor in
            do { appel.rendre(.success(try await operation())) } catch { appel.rendre(.failure(error)) }
        }
        return try await withTaskCancellationHandler {
            try await appel.attendre()
        } onCancel: { tache.cancel() }
    }
}
