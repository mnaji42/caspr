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

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(onText: @escaping @MainActor @Sendable (String) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        self.onText = onText
        self.onFailure = onFailure
    }

    func start(language: String) async {
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

        let task = recognizer.recognitionTask(with: audio) { [weak self] result, error in
            guard let self else { return }
            if error != nil {
                // Silencieux : une reconnaissance interrompue en fin de dictée
                // est le cas normal, et l'annoncer ferait clignoter un
                // avertissement à chaque phrase. L'échec qui compte — celui du
                // démarrage — est signalé plus haut.
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in self.onText(text) }
        }

        // Prise hors du contexte asynchrone : un verrou bloquant tenu à
        // travers une suspension immobiliserait un fil du pool coopératif.
        store(request: audio, task: task)

        await report("en écoute…")
    }

    private func store(request: SFSpeechAudioBufferRecognitionRequest,
                       task: SFSpeechRecognitionTask) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
        self.task = task
    }

    /// Appelé depuis le fil audio : on ne touche qu'à une référence protégée.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }

    func stop() {
        lock.lock()
        let request = self.request
        let task = self.task
        self.request = nil
        self.task = nil
        lock.unlock()

        request?.endAudio()
        task?.cancel()
    }

    private func report(_ message: String) async {
        await MainActor.run { onFailure(message) }
    }
}
