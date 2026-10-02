import Foundation
import Testing
@testable import CasprCore

/// La sortie de la touche de dictée, quand la page ne répond plus.
///
/// Une page au fil JavaScript bloqué ne rend jamais la main, et aucune
/// échéance ne la rattrape plus (cf. RELAIS.md, sixième règle) : si
/// l'annulation ne tranchait pas l'attente, l'appui resterait suspendu pour
/// toujours.
@Suite("Appel annulable")
@MainActor
struct AppelAnnulableTests {

    @Test("Un appel qui ne rend jamais la main, annulé, la rend en moins de 200 ms")
    func annulationImmediate() async throws {
        let appel = AppelAnnulable<Int>()
        let tache = Task { @MainActor in try await appel.attendre() }
        try await Task.sleep(for: .milliseconds(50))
        let debut = ContinuousClock.now
        tache.cancel()
        await #expect(throws: CancellationError.self) { try await tache.value }
        #expect(ContinuousClock.now - debut < .milliseconds(200))
    }

    @Test("Une réponse arrivée après l'annulation est ignorée")
    func reponseTardiveIgnoree() async throws {
        let appel = AppelAnnulable<Int>()
        let tache = Task { @MainActor in try await appel.attendre() }
        try await Task.sleep(for: .milliseconds(20))
        tache.cancel()
        await #expect(throws: CancellationError.self) { try await tache.value }
        // Une seconde reprise de la continuation ferait planter : elle doit
        // être ignorée, sans bruit.
        appel.rendre(.success(42))
        // L'issue gardée reste l'annulation : la réponse n'a rien remplacé.
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { appel.attacher($0) }
        }
    }

    @Test("Une annulation arrivée avant l'attache est rendue à l'attache")
    func annulationAvantAttache() async {
        let appel = AppelAnnulable<Int>()
        appel.rendre(.failure(CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { appel.attacher($0) }
        }
    }

    @Test("La réponse arrivée la première est rendue")
    func reponseRendue() async throws {
        let appel = AppelAnnulable<Int>()
        appel.rendre(.success(7))
        appel.rendre(.failure(CancellationError()))
        #expect(try await appel.attendre() == 7)
    }
}
