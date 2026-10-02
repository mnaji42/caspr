import AVFoundation
import Foundation
import Speech

/// Aperçu en direct par le moteur de la Dictée de macOS.
///
/// La seconde implémentation de `SpeechPreviewing`, à côté de `LivePreview` qui
/// s'appuie sur `SpeechTranscriber`. Les deux rendent le même service — du
/// texte qui s'affine pendant qu'on parle — par deux chemins différents, et
/// c'est `SpeechPreview.make` qui tranche selon ce que la machine sait faire.
///
/// Elle existe parce que l'aperçu s'annonçait indisponible sur des machines où
/// la Dictée de macOS affiche pourtant chaque mot en direct. C'était vrai du
/// moteur de macOS 26 et faux du système : `SFSpeechRecognizer` produit des
/// résultats partiels depuis toujours, et c'est exactement ce que la Dictée
/// utilise.
///
/// Comme pour la transcription complète, `requiresOnDeviceRecognition` est
/// forcé : un aperçu qui enverrait la voix chez Apple trahirait la promesse de
/// l'application aussi sûrement qu'une transcription.
final class LegacyLivePreview: SpeechPreviewing, @unchecked Sendable {
    private let onText: @MainActor @Sendable (String) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void
    private let onNotice: @MainActor @Sendable (String) -> Void

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// Vrai dès `stop()`, et pour toujours, comme `LivePreview.stopped`.
    ///
    /// Arrêté pendant que `start` attendait le dialogue d'autorisation,
    /// l'aperçu n'avait rien à arrêter ; `start` reprenait ensuite, ouvrait
    /// une reconnaissance que plus personne n'arrêterait, et affichait « en
    /// écoute… » sur la barre d'après.
    private var stopped = false
    private var isStopped: Bool { lock.withLock { stopped } }

    init(onText: @escaping @MainActor @Sendable (String) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void,
         onNotice: @escaping @MainActor @Sendable (String) -> Void) {
        self.onText = onText
        self.onFailure = onFailure
        self.onNotice = onNotice
    }

    func start(language: String) async {
        guard !isStopped else { return }
        // Avant l'autorisation, et pour la même raison qu'à la transcription :
        // avec la Dictée de macOS éteinte, tout ce qui suit répond « oui », la
        // tâche démarre, la barre affiche « en écoute… » et pas un mot
        // n'arrive jamais. Un aperçu muet ne se distingue pas d'un micro qui
        // n'entend rien, et c'est ce qu'on a cherché en premier.
        guard !SystemDictation.isDisabled else {
            await report("aperçu : la Dictée de macOS est désactivée")
            return
        }
        guard await LegacySpeechEngine.requestAuthorisation() else {
            await report("aperçu : reconnaissance vocale non autorisée")
            return
        }
        guard let recognizer = LegacySpeechEngine.recognizer(for: language),
              recognizer.supportsOnDeviceRecognition else {
            await report("aperçu indisponible pour cette langue")
            return
        }

        let audio = SFSpeechAudioBufferRecognitionRequest()
        audio.requiresOnDeviceRecognition = true
        // Toute la raison d'être de cette classe : sans ça, rien ne sort avant
        // la fin, et l'aperçu n'aperçoit rien.
        audio.shouldReportPartialResults = true

        // Le rappel tient `onText` et non l'aperçu : celui-ci est libéré dès
        // l'arrêt, et le résultat final — la fin de la dictée — arrive après.
        let onText = self.onText
        let tache = recognizer.recognitionTask(with: audio) { result, error in
            if error != nil {
                // Silencieux : une reconnaissance interrompue en fin de dictée
                // est le cas normal, et l'annoncer ferait clignoter un
                // avertissement à chaque phrase. L'échec qui compte — celui du
                // démarrage — est signalé plus haut.
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in onText(text) }
        }

        // Prise hors du contexte asynchrone : un verrou bloquant tenu à
        // travers une suspension immobiliserait un fil du pool coopératif.
        guard store(request: audio) else {
            tache.cancel()
            return
        }

        await report("en écoute…", echec: false)
    }

    /// Garde la requête, sauf si l'aperçu a été arrêté entre-temps.
    private func store(request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            self.request = request
            return true
        }
    }

    /// Appelé depuis le fil audio, ou le fil principal pour l'écho : on ne
    /// touche qu'à une référence protégée. La requête accepte le format de
    /// chaque source tel quel, elle convertit elle-même.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }

    func stop() {
        lock.lock()
        let request = self.request
        self.request = nil
        stopped = true
        lock.unlock()

        // Fin de l'audio, sans annuler la tâche : elle rend encore son
        // résultat final, puis se termine seule. L'annuler aussitôt jetait la fin de la dictée, que garde le recours
        // « Insérer l'aperçu ».
        request?.endAudio()
    }

    private func report(_ message: String, echec: Bool = true) async {
        guard !isStopped else { return }
        await MainActor.run { (echec ? onFailure : onNotice)(message) }
    }
}
