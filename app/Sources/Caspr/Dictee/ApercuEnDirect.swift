import AVFoundation
import os
import CasprCore

/// L'aperçu en direct d'une dictée : ce que macOS entend, dans la barre,
/// pendant qu'on parle — et son texte, gardé comme recours.
///
/// Sorti de `VoieApple` pour ne pas dépendre de la source du son : le micro de
/// Caspr sous macOS, la copie du flux de la page sous ChatGPT (cf.
/// `RelaisEcho`). La voie le démarre et le nourrit ; lui ne sait que
/// reconnaître.
///
/// Rien de ceci ne touche à la transcription : l'aperçu lit les mêmes
/// tampons, en parallèle, et son échec n'a aucun effet sur la dictée.
@MainActor
final class ApercuEnDirect {
    private let overlay: RecordingOverlay

    /// L'aperçu qui écoute, `nil` le reste du temps. Lu depuis le fil audio
    /// par `nourrir` : sous verrou. La source n'a donc pas à être rebranchée
    /// quand l'aperçu change — un changement de langue le remplace en pleine
    /// écoute.
    private nonisolated let enCours = OSAllocatedUnfairLock<(any SpeechPreviewing)?>(initialState: nil)

    /// Dernier texte rendu par l'aperçu pour la dictée en cours : le recours
    /// qui reste quand la passe finale échoue (cf. `Livraison`).
    private(set) var texte = ""

    /// Le numéro de l'aperçu dont on accepte encore le texte.
    ///
    /// Pas seulement celui qui écoute : un aperçu arrêté finit son analyse,
    /// et ce qu'il rend alors est la fin de la dictée, celle que le recours
    /// « Insérer l'aperçu » doit contenir. Il cesse de compter quand un autre
    /// le remplace — dictée suivante, changement de langue — ou qu'on annule :
    /// le numéro change.
    private var retenu = 0

    init(overlay: RecordingOverlay) {
        self.overlay = overlay
    }

    private var ecoute: Bool { enCours.withLock { $0 } != nil }

    /// Une dictée commence : le texte de la précédente ne compte plus.
    func oublier() {
        retenu &+= 1
        texte = ""
    }

    /// Démarre l'aperçu, si le système et l'utilisateur le permettent.
    func demarrer(langue: String) {
        guard Preferences.shared.livePreviewEnabled, !ecoute else { return }
        retenu &+= 1
        let jeton = retenu
        // La version qui écrira, et nulle autre : cf. `SpeechPreview.engine`.
        guard let made = SpeechPreview.make(
            for: langue,
            onText: { [weak self] text in
                guard let self, retenu == jeton else { return }
                if texte.isEmpty, !text.isEmpty {
                    Log.info("aperçu : premier texte reçu")
                }
                // Retenu pour le recours : si la passe finale échoue, c'est
                // un texte de macOS sur exactement le même audio.
                texte = text
                // Arrêté, l'aperçu n'a plus de barre où s'afficher : elle est
                // passée au traitement.
                if ecoute { overlay.setPreviewText(text) }
            },
            onFailure: { [weak self] reason in
                Log.error("aperçu indisponible : \(reason)")
                self?.overlay.setPreviewNotice(reason)
            })
        else {
            overlay.setPreviewNotice("aperçu indisponible sur cette machine")
            return
        }
        enCours.withLock { $0 = made }
        // Détaché : le premier lancement peut télécharger le modèle système,
        // et la dictée ne doit pas attendre.
        Task { await made.start(language: langue) }
    }

    /// Un tampon du micro, depuis le fil audio ; perdu quand aucun aperçu
    /// n'écoute.
    nonisolated func nourrir(_ buffer: AVAudioPCMBuffer) {
        enCours.withLock { $0 }?.append(buffer)
    }

    /// Un morceau de l'écho de la page ChatGPT (cf. `RelaisEcho`), des
    /// flottants mono à la fréquence de son contexte audio. Aucun tampon
    /// n'est construit quand aucun aperçu n'écoute.
    func nourrir(_ morceau: ArraySlice<Float>, taux: Double) {
        guard ecoute, !morceau.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: taux, channels: 1),
              let tampon = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(morceau.count)),
              let canal = tampon.floatChannelData?[0] else { return }
        morceau.withUnsafeBufferPointer { canal.update(from: $0.baseAddress!, count: $0.count) }
        tampon.frameLength = tampon.frameCapacity
        nourrir(tampon)
    }

    /// Cesse d'écouter ; le texte qu'il finit encore d'analyser compte.
    func arreter() {
        enCours.withLock { apercu in
            defer { apercu = nil }
            return apercu
        }?.stop()
    }

    /// Cesse d'écouter, et plus rien de lui ne compte.
    func annuler() {
        arreter()
        retenu &+= 1
    }

    /// Repart sur une autre langue, en pleine écoute.
    func relancer(langue: String) {
        arreter()
        demarrer(langue: langue)
    }
}
