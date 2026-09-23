import AVFoundation
import CasprCore

/// Ce que les deux versions de macOS ont en commun, et rien de plus : un
/// enregistrement entier et une langue en entrée, un texte en sortie.
///
/// Il remplace un protocole de moteur qui promettait davantage : un nom à
/// afficher, une disponibilité, une latence découpée en mel, encodeur et
/// décodeur, héritée d'un moteur local qui n'existe plus. La voie ChatGPT s'y
/// conformait en recevant un enregistrement vide et en inventant ses chiffres.
/// Les deux versions de macOS, elles, reçoivent vraiment du PCM : c'est
/// tout ce qu'elles partagent, et tout ce que ce protocole dit.
protocol TranscripteurMacOS: Sendable {
    /// `samples` : PCM mono 16 kHz, normalisé dans [-1, 1].
    func transcribe(_ samples: [Float], language: String) async throws -> String
}

/// La voie macOS : le micro de Caspr, l'aperçu en direct, et la version de
/// macOS qui écrit.
///
/// C'est la seule des deux voies qui ouvre le micro de Caspr. Elle le déclare
/// au relais, qui ne doit pas faire naître sa page pendant qu'elle écoute :
/// une page ChatGPT vivante réduit l'enregistrement au silence (cf.
/// `Relais.ecouteMacOS`). Le micro est rendu sur chaque chemin qui cesse
/// d'écouter — arrêt, annulation, démarrage manqué.
@MainActor
final class VoieApple {
    private let recorder = AudioRecorder()
    /// Apple Intelligence, absent avant macOS 26.
    private let intelligence: (any TranscripteurMacOS)?
    /// La Dictée. Présente partout où la dictée de macOS fonctionne — Mac
    /// Intel et macOS antérieurs compris.
    private let dicteeSysteme: any TranscripteurMacOS

    /// Aperçu en direct, quand le système sait le faire et que l'utilisateur
    /// le veut. `nil` le reste du temps.
    private var preview: (any SpeechPreviewing)?

    /// Dernier texte rendu par l'aperçu pour la dictée en cours : le recours
    /// qui reste quand la passe finale échoue (cf. `Livraison`).
    private(set) var previewText = ""

    init() {
        if #available(macOS 26.0, *) {
            intelligence = AppleSpeechEngine()
        } else {
            intelligence = nil
        }
        // Toujours instanciée : elle ne coûte rien tant qu'on ne l'appelle
        // pas, et sa disponibilité réelle se demande à
        // `EngineChoice.isAvailable` plutôt qu'à une version de macOS.
        dicteeSysteme = LegacySpeechEngine()
    }

    /// Le niveau du micro, pour la barre.
    var niveau: Float { recorder.level }

    /// La version de macOS qui écrit, choisie à l'instant sur ce que la
    /// machine sait faire dans la langue (cf. `EngineSafetyManager`).
    var version: EngineChoice { EngineSafetyManager.effectiveEngine }

    // MARK: - Écoute

    /// Le micro est à Caspr jusqu'à l'arrêt du magnétophone : passer à
    /// ChatGPT d'ici là ne doit pas faire naître la page, qui le lui prendrait.
    func prendreLeMicro() {
        Relais.partage.macOSPrendLeMicro()
    }

    /// Rend le micro sans avoir écouté — un démarrage manqué.
    func rendreLeMicro() {
        Relais.partage.macOSRendLeMicro()
    }

    func demarrer() throws {
        try recorder.start()
        previewText = ""
    }

    /// Arrête d'écouter et rend ce qui a été enregistré.
    ///
    /// Passé à ChatGPT pendant la dictée, c'est ici que la page se charge :
    /// après la dernière seconde enregistrée, jamais pendant.
    func arreter() -> [Float] {
        let samples = recorder.stop()
        arreterApercu()
        rendreLeMicro()
        return samples
    }

    func annuler() {
        recorder.cancel()
        arreterApercu()
        rendreLeMicro()
    }

    /// Transcrit un enregistrement avec la version retenue à l'instant.
    ///
    /// La Dictée en dernier recours : elle existe partout, et c'est elle qui
    /// dira pourquoi elle ne peut pas écrire, plutôt qu'une version absente.
    func transcrire(_ samples: [Float], langue: String) async throws -> String {
        let transcripteur: any TranscripteurMacOS = switch version {
        case .apple: intelligence ?? dicteeSysteme
        case .appleLegacy: dicteeSysteme
        }
        return try await transcripteur.transcribe(samples, language: langue)
    }

    // MARK: - Aperçu en direct

    /// Branche l'aperçu sur le flux micro, si le système et l'utilisateur le
    /// permettent.
    ///
    /// Rien de ceci ne touche à la transcription : l'aperçu lit les mêmes
    /// tampons, en parallèle, et son texte n'est gardé que comme recours. Un
    /// échec de l'aperçu n'a donc aucun effet sur la dictée.
    func demarrerApercu(langue: String, barre: RecordingOverlay) {
        guard Preferences.shared.livePreviewEnabled, preview == nil else { return }
        // La version qui écrira, et nulle autre : cf. `SpeechPreview.engine`.
        guard let made = SpeechPreview.make(
            for: langue,
            onText: { [weak self, weak barre] text in
                guard let self else { return }
                if previewText.isEmpty, !text.isEmpty {
                    Log.info("aperçu : premier texte reçu")
                }
                // Retenu pour le recours : si la passe finale échoue, c'est
                // un texte de macOS sur exactement le même audio.
                previewText = text
                barre?.setPreviewText(text)
            },
            onFailure: { [weak barre] reason in
                Log.error("aperçu indisponible : \(reason)")
                barre?.setPreviewNotice(reason)
            })
        else {
            barre.setPreviewNotice("aperçu indisponible sur cette machine")
            return
        }
        preview = made
        recorder.onBuffer = { [weak preview = made] buffer in
            preview?.append(buffer)
        }
        // Détaché : le premier lancement peut télécharger le modèle système,
        // et la dictée ne doit pas attendre.
        Task { await made.start(language: langue) }
    }

    func arreterApercu() {
        recorder.onBuffer = nil
        preview?.stop()
        preview = nil
    }
}
