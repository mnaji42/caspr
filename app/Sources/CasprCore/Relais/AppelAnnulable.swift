import Foundation

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
/// n'est pas au temps de décider qu'on renonce (cf. RELAIS.md, sixième règle).
///
/// Une continuation ne se reprend qu'une fois ; l'issue arrivée avant qu'on
/// l'attende — une tâche déjà annulée — est gardée, et rendue à l'attache.
@MainActor
public final class AppelAnnulable<Valeur> {
    private var suite: CheckedContinuation<Valeur, Error>?
    private var issue: Result<Valeur, Error>?

    public init() {}

    /// L'issue est-elle déjà connue ?
    public var estRendu: Bool { issue != nil }

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
}
