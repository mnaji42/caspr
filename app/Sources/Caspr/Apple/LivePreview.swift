import AVFoundation
import Foundation
import Speech
import CasprCore

/// Ce que la barre affiche pendant qu'on parle.
///
/// Volontairement derrière un protocole : la reconnaissance en flux n'existe
/// qu'à partir de macOS 26, et l'application vise macOS 14. Le contrôleur
/// manipule donc un `SpeechPreviewing?` qui reste simplement `nil` ailleurs,
/// plutôt que de disséminer des `#available` dans la logique de dictée.
protocol SpeechPreviewing: AnyObject, Sendable {
    /// Prépare la reconnaissance. Peut être long au premier appel : le modèle
    /// de dictée du système se télécharge à la demande.
    func start(language: String) async

    /// Tampon brut, au format de sa source — le matériel, ou le contexte
    /// audio de la page ChatGPT. Appelé depuis le fil audio (le micro de
    /// Caspr) ou depuis le fil principal (l'écho de la page, cf.
    /// `RelaisEcho`) ; jamais des deux pour un même aperçu, chaque voie a le
    /// sien. Le verrou de l'implémentation protège ce que `start` et `stop`
    /// partagent avec lui, quel que soit ce fil.
    func append(_ buffer: AVAudioPCMBuffer)

    func stop()
}

/// Aperçu en direct de la dictée, par le moteur de reconnaissance de macOS.
///
/// **Ce n'est pas une préversion du texte qui sera inséré.** L'aperçu écoute
/// en flux, et la passe finale — ou ChatGPT — relit l'enregistrement entier à
/// la fin, avec tout le contexte de la phrase : les deux ne rendent pas le
/// même texte. L'aperçu répond à « est-ce qu'on m'entend, où j'en suis dans
/// ma phrase », pas à « la transcription finale sera-t-elle juste ».
/// L'interface doit le dire, sans quoi l'utilisateur corrigera des erreurs
/// qui n'existent pas dans le texte réellement inséré.
@available(macOS 26.0, *)
final class LivePreview: SpeechPreviewing, @unchecked Sendable {
    /// Texte reconnu jusqu'ici, publié sur le main actor.
    private let onText: @MainActor @Sendable (String) -> Void
    /// Raison d'un aperçu indisponible, à afficher telle quelle.
    private let onFailure: @MainActor @Sendable (String) -> Void
    /// Ce que l'aperçu dit de lui sans avoir échoué — un modèle qui se
    /// télécharge. Distinct de l'échec, qui va au journal comme une erreur.
    private let onNotice: @MainActor @Sendable (String) -> Void

    /// Tout ce qui suit est partagé entre trois fils : le démarrage, qui
    /// tourne hors du main actor, le fil audio qui appelle `append`, et le
    /// main actor qui appelle `stop`. Rien ne le protégeait — `converter`
    /// était écrit par deux d'entre eux à la fois —, là où `LegacyLivePreview`
    /// avait déjà son verrou. Jamais tenu à travers une suspension : un verrou
    /// bloquant immobiliserait un fil du pool coopératif.
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    /// Créé au premier tampon : le format matériel n'est connu qu'à ce
    /// moment-là, et il change si l'utilisateur change de micro.
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    /// Vrai dès `stop()`, et pour toujours : un aperçu arrêté ne repart pas.
    ///
    /// `stop()` ne l'empêchait pas. Appelé pendant que `start` attendait
    /// encore — la réservation de la locale, le téléchargement du modèle —, il
    /// n'avait rien à arrêter ; `start` reprenait ensuite, branchait
    /// l'analyseur, et l'aperçu ressuscité écrivait sur une barre et dans un
    /// contrôleur passés à la dictée suivante. C'est le jeton que chaque
    /// étape du démarrage vérifie avant d'agir.
    ///
    /// Sauf la publication du texte : ce que l'analyseur finalise après
    /// l'arrêt — le dernier volatil promu en définitif, la dernière seconde
    /// de parole — est la fin de la dictée, et c'est ce texte que garde le
    /// recours « Insérer l'aperçu ». C'est `ApercuEnDirect` qui écarte les
    /// textes d'un aperçu remplacé ou annulé.
    private var stopped = false

    private var isStopped: Bool { lock.withLock { stopped } }

    init(onText: @escaping @MainActor @Sendable (String) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void,
         onNotice: @escaping @MainActor @Sendable (String) -> Void) {
        self.onText = onText
        self.onFailure = onFailure
        self.onNotice = onNotice
    }

    /// Réserve la locale auprès du système, une fois pour toutes.
    ///
    /// Le framework l'exige, et le dit dans son journal quand on l'omet :
    /// « Cannot use modules with unallocated locales […] This will be an error
    /// in a future release ».
    ///
    /// Elle reste nécessaire parce que le framework la réclame, pas parce
    /// qu'on lui a mesuré un effet : des textes d'aperçu très courts lui
    /// avaient été imputés, et c'était en fait une course sur le texte de
    /// l'aperçu, corrigée ailleurs.
    ///
    /// Le nombre de réservations est plafonné par le système
    /// (`maximumReservedLocales`) : on libère les autres avant de prendre
    /// celle qu'on veut.
    static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier == locale.identifier }) else { return }
        for previous in reserved {
            _ = await AssetInventory.release(reservedLocale: previous)
        }
        let granted = try await AssetInventory.reserve(locale: locale)
        Log.info("aperçu : locale \(locale.identifier) réservée : \(granted ? "oui" : "non")")
    }

    /// Branche l'analyseur, sauf si l'aperçu a été arrêté entre-temps.
    private func adopt(format: AVAudioFormat,
                       continuation: AsyncStream<AnalyzerInput>.Continuation,
                       analyzer: SpeechAnalyzer,
                       results: Task<Void, Never>) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            analyzerFormat = format
            self.continuation = continuation
            self.analyzer = analyzer
            self.results = results
            return true
        }
    }

    func start(language: String) async {
        guard !isStopped else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language)) else {
            await report("aperçu indisponible en \(language)")
            return
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Les deux options sont nécessaires, et c'est mesuré. Sans
            // `volatileResults`, rien ne sort avant la fin d'une phrase
            // entière. Sans `fastResults`, le moteur attend d'avoir accumulé
            // beaucoup d'audio : sur une dictée de 17 s, premier texte à
            // 12,2 s puis tout d'un coup, contre 1,1 s et 17 mises à jour
            // étalées avec. `fastResults` échange un peu d'exactitude contre
            // la réactivité — exactement le bon compromis pour un affichage
            // qui ne sert qu'à se relire en parlant.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])

        do {
            // Réserver d'abord, interroger ensuite. L'inventaire refuse de
            // répondre sur une langue à laquelle l'application n'a pas
            // souscrit — « is not subscribed to transcription.fr » — et la
            // séquence inverse produisait cette erreur avant même d'avoir pu
            // constater ce qui manquait.
            try await Self.reserve(locale)

            // On se fie à `installedLocales`, pas à l'existence d'une requête
            // d'installation : mesuré ici, `assetInstallationRequest` renvoie
            // une requête pour `fr_FR` alors que le modèle est déjà installé
            // et que l'analyseur démarre très bien sans. Télécharger sur ce
            // seul signal ferait payer un aller-retour réseau à chaque
            // première dictée.
            let installed = await SpeechTranscriber.installedLocales
            if !installed.contains(where: { $0.identifier == locale.identifier }) {
                await report("aperçu : téléchargement du modèle \(locale.identifier)…", echec: false)
                Log.info("aperçu : téléchargement du modèle (\(locale.identifier))…")
                try await AppleSpeechEngine.installAssets(for: transcriber)
            }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]) else {
                await report("aperçu : format audio incompatible")
                return
            }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let results = Task { [weak self] in
                guard let self else { return }
                await consume(transcriber.results)
            }
            // Arrêté pendant qu'on préparait : on ne branche rien.
            guard adopt(format: format, continuation: continuation,
                        analyzer: analyzer, results: results) else {
                continuation.finish()
                results.cancel()
                return
            }
            try await analyzer.start(inputSequence: stream)
        } catch {
            await report("aperçu indisponible — \(error.localizedDescription)")
            Log.error("aperçu en direct impossible — \(String(describing: error))")
            stop()
        }
    }

    /// Assemble les résultats en un texte courant.
    ///
    /// Le moteur émet deux sortes de résultats : des volatils, qu'il remplace
    /// au fur et à mesure qu'il entend la suite, et des définitifs, qui ne
    /// bougeront plus. On accumule les seconds et on ne réaffiche que le
    /// dernier volatil, sinon la fin de phrase se dédouble à l'écran.
    private func consume<Results: AsyncSequence & Sendable>(_ stream: Results) async
    where Results.Element == SpeechTranscriber.Result {
        var settled = ""
        do {
            for try await result in stream {
                let fragment = String(result.text.characters)
                if result.isFinal {
                    settled += fragment
                    await publish(settled)
                } else {
                    await publish(settled + fragment)
                }
            }
        } catch {
            Log.error("aperçu : flux interrompu — \(String(describing: error))")
        }
    }

    @MainActor
    private func publish(_ text: String) {
        onText(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor
    private func report(_ message: String, echec: Bool = true) {
        guard !isStopped else { return }
        (echec ? onFailure : onNotice)(message)
    }

    /// Appelé depuis le fil audio, ou le fil principal pour l'écho. Le
    /// convertisseur suit le format du tampon : 16 kHz en flottants pour
    /// l'écho, le format du matériel pour le micro.
    func append(_ buffer: AVAudioPCMBuffer) {
        let prepared: (AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat,
                       AVAudioConverter)? = lock.withLock {
            guard let continuation = self.continuation,
                  let analyzerFormat = self.analyzerFormat else { return nil }
            if self.converter?.inputFormat != buffer.format {
                self.converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            }
            guard let converter = self.converter else { return nil }
            return (continuation, analyzerFormat, converter)
        }
        guard let prepared else { return }
        let (continuation, analyzerFormat, converter) = prepared

        // Le ré-échantillonnage change le nombre de trames : on dimensionne la
        // sortie au ratio des fréquences, avec une trame de marge.
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat,
                                         frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: out))
    }

    func stop() {
        let (continuation, analyzer, results) = lock.withLock {
            stopped = true
            let taken = (self.continuation, self.analyzer, self.results)
            self.continuation = nil
            self.converter = nil
            self.analyzerFormat = nil
            self.analyzer = nil
            self.results = nil
            return taken
        }
        continuation?.finish()
        // Laisser l'analyseur finaliser, et la boucle de résultats le suivre
        // jusqu'au bout : le flux se termine avec l'analyse. L'annuler
        // aussitôt après jetait les derniers résultats — la fin de la
        // dictée. Elle ne s'annule que si la finalisation échoue.
        Task {
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                results?.cancel()
            }
        }
    }
}

/// Fabrique l'aperçu si le système sait le faire.
///
/// Un seul endroit teste la version : le reste du code ne voit qu'un
/// `SpeechPreviewing?`.
enum SpeechPreview {
    /// Choisit l'implémentation de la version donnée, si elle sait écouter
    /// cette langue ici ; `nil` sinon.
    ///
    /// La version est **celle qui écrit**, choisie une fois par la dictée et
    /// passée ici (cf. `DictationController.versionDuCycle`) : la rechoisir
    /// relisait la disponibilité des deux versions une fois de plus par
    /// dictée, et pouvait en retenir une autre que la transcription. Ce n'est
    /// pas qu'une question de cohérence d'affichage : chaque version de macOS
    /// a son autorisation — la reconnaissance vocale, que macOS compte
    /// séparément du micro — et ses actifs, un modèle par locale à
    /// télécharger. Faire tourner l'autre pour le seul aperçu réclamerait donc
    /// un droit ou un téléchargement dont l'utilisateur n'a aucun usage.
    ///
    /// L'aperçu n'était branché que sur `SpeechTranscriber`, donc il
    /// s'annonçait indisponible là où la Dictée de macOS affiche pourtant
    /// chaque mot en direct. Deux implémentations du même protocole règlent
    /// ça sans que le contrôleur de dictée en sache quoi que ce soit : il
    /// demande un aperçu, il en reçoit un.
    @MainActor
    static func make(_ version: EngineChoice, for language: String,
                     onText: @escaping @MainActor @Sendable (String) -> Void,
                     onFailure: @escaping @MainActor @Sendable (String) -> Void,
                     onNotice: @escaping @MainActor @Sendable (String) -> Void)
    -> (any SpeechPreviewing)? {
        guard version.isAvailable(for: language) else { return nil }
        switch version {
        case .apple:
            guard #available(macOS 26.0, *) else { return nil }
            return LivePreview(onText: onText, onFailure: onFailure, onNotice: onNotice)
        case .appleLegacy:
            return LegacyLivePreview(onText: onText, onFailure: onFailure, onNotice: onNotice)
        }
    }
}
