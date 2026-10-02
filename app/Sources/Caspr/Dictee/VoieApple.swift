import CasprCore
import Foundation

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

    /// L'aperçu en direct, nourri par le micro de Caspr.
    let apercu: ApercuEnDirect

    private let overlay: RecordingOverlay
    private let livraison: Livraison

    init(overlay: RecordingOverlay, livraison: Livraison) {
        self.overlay = overlay
        self.livraison = livraison
        apercu = ApercuEnDirect(overlay: overlay)
        // Branché une fois pour toutes : sans aperçu qui écoute, les tampons
        // sont simplement perdus.
        recorder.onBuffer = { [apercu] in apercu.nourrir($0) }
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

    /// Ce que la barre montre sous cette voie.
    func statutDeLaBarre(peutChoisirLaNote: Bool) -> RecordingOverlay.Status {
        RecordingOverlay.Status(
            target: Preferences.shared.effectiveTarget,
            noteName: Preferences.shared.noteFile?.lastPathComponent,
            // Sans fichier mémorisé, basculer sur les notes suppose un
            // sélecteur — impossible pendant qu'on parle.
            canPickNote: peutChoisirLaNote,
            previewEnabled: Preferences.shared.livePreviewEnabled,
            // La langue **effectivement** écoutée. Elle n'était nulle part sur
            // la barre : depuis le multi-langues, dicter en français avec
            // l'anglais actif produit un texte incompréhensible qu'on met
            // longtemps à imputer à la bonne cause.
            languageBadge: Preferences.shared.primary.shortBadge,
            switchableLanguages: Preferences.shared.activeLanguages
                .map { ($0.code, $0.shortBadge) },
            languageCode: Preferences.shared.primaryLanguage)
    }

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

    func demarrer() async throws {
        // Une page ChatGPT gardée pour qu'on y récupère un texte tient le
        // micro : elle part avant que le magnétophone n'écoute.
        await Relais.partage.libererLaPageGardee()
        try recorder.start()
        apercu.oublier()
    }

    /// Arrête d'écouter et rend ce qui a été enregistré.
    ///
    /// Passé à ChatGPT pendant la dictée, c'est ici que la page se charge :
    /// après la dernière seconde enregistrée, jamais pendant.
    func arreter() -> [Float] {
        let samples = recorder.stop()
        apercu.arreter()
        rendreLeMicro()
        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        // Le niveau crête, et pas seulement la durée. Un compte
        // d'échantillons ne dit pas si l'on a enregistré du son ou du silence,
        // et les deux pannes ne se réparent pas au même endroit : un micro
        // muet se voit ici, une transcription vide se voit plus loin.
        let crete = samples.reduce(Float(0)) { max($0, abs($1)) }
        Log.info("fin d'enregistrement : \(String(format: "%.1f", seconds)) s capturées, "
                 + "crête \(String(format: "%.3f", crete))")
        return samples
    }

    /// Où la capture s'est arrêtée quand un changement de micro n'a pas pu
    /// être suivi (cf. `AudioRecorder.coupure`) ; lu après `arreter`.
    var coupure: TimeInterval? { recorder.coupure }

    func annuler() {
        recorder.cancel()
        apercu.annuler()
        rendreLeMicro()
    }

    // MARK: - Transcrire

    /// Transcrit puis livre, en gardant l'audio tant que ce n'est pas réussi ;
    /// rend le message d'échec, `nil` quand le texte est livré.
    ///
    /// Une dictée peut durer dix minutes. Perdre cet audio parce que la
    /// transcription a échoué obligerait à tout redire — c'est le pire échec
    /// possible pour cette application. L'audio n'est donc libéré qu'après une
    /// insertion réussie, et « Réessayer » permet de relancer sans reparler.
    ///
    /// Elle dure une seconde d'ordinaire, des minutes quand Apple
    /// Intelligence télécharge d'abord son modèle : la tâche qui l'appelle
    /// peut être annulée (cf. `DictationController.interrompreLaTranscription`).
    /// Annulée, rien n'est inséré ni affiché, et l'audio est gardé comme
    /// après un échec — avec le texte, s'il était déjà là.
    ///
    /// `apercuConserve` : ce que l'aperçu en direct avait écrit du même audio,
    /// gardé avec lui comme second recours — celui d'un « Réessayer ». `nil`
    /// pour une dictée qui vient de finir : l'aperçu est alors lu au moment de
    /// l'échec, et non à l'arrêt, parce qu'il finit son analyse après l'arrêt
    /// et peut encore s'allonger pendant la transcription. Lu à l'échec aussi
    /// quand il est donné : celui d'une page ChatGPT à laquelle on vient de
    /// renoncer s'allonge de même.
    func transcrireEtLivrer(_ samples: [Float], _ dictee: DicteeEnCours,
                            langue: String, apercuConserve: @autoclosure () -> String?) async -> String? {
        let debut = ContinuousClock.now
        // Choisie une fois, à l'instant et pour la langue de la
        // transcription (cf. `EngineSafetyManager`) : chaque relecture
        // recrée des reconnaisseurs. Un « Réessayer » la rechoisit.
        let version = EngineSafetyManager.engine(for: langue)
        do {
            let text = try await transcrire(samples, langue: langue, par: version)
            guard !Task.isCancelled else {
                livraison.conserver(audio: samples, apercu: text.isEmpty ? apercuConserve() ?? apercu.texte : text,
                                    apresLeRelais: dictee.voie == .chatgpt, echec: nil)
                return nil
            }
            guard !text.isEmpty else {
                // Le dernier chemin réellement muet de l'application : le
                // moteur répond, sans erreur, avec une chaîne vide. Rien n'est
                // inséré, la barre disparaît, et il ne reste **aucun** indice —
                // ni message, ni entrée d'historique. Vu de l'utilisateur,
                // c'est indiscernable d'un raccourci qui n'aurait rien
                // déclenché, et c'est ce qui a fait chercher une panne de
                // dictée là où le moteur disait simplement n'avoir rien
                // entendu.
                Log.error("le moteur a rendu un texte vide "
                          + "(\(version.rawValue), \(Log.ms(depuis: debut)) ms)")
                // L'audio est conservé : une version mal configurée rend le
                // vide aussi sûrement qu'un micro coupé, et dans ce cas jeter
                // la dictée oblige à tout redire.
                livraison.conserver(audio: samples,
                                    apercu: apercuConserve() ?? apercu.texte,
                                    apresLeRelais: dictee.voie == .chatgpt,
                                    echec: "Rien n'a été entendu")
                // Un échec et non un retour au repos : la barre renvoie au
                // menu, et le menu affichait « Prêt ». Envoyer quelqu'un
                // chercher une explication à un endroit qui n'en porte aucune
                // est pire que de se taire.
                return "Le moteur a répondu sans rien transcrire "
                    + "(\(version.fullLabel)) — "
                    + "audio conservé, « Réessayer » ci-dessous."
            }
            overlay.hide()
            try await livraison.livrer(text, dictee)
            Log.info("transcrit en \(Log.ms(depuis: debut)) ms par \(version.rawValue), \(text.count) caractères")
            return nil
        } catch {
            if error is CancellationError || Task.isCancelled {
                Log.info("transcription interrompue — audio conservé")
                livraison.conserver(audio: samples, apercu: apercuConserve() ?? apercu.texte,
                                    apresLeRelais: dictee.voie == .chatgpt, echec: nil)
                return nil
            }
            // Transcrite mais pas insérée, la dictée est dans l'historique :
            // c'est là qu'on la reprend, et non par « Réessayer » ou l'aperçu,
            // qui échoueraient pareil tant que la cause demeure. L'audio n'est
            // gardé que sans historique, où il reste le seul recours.
            if let insertion = error as? Livraison.EchecDInsertion, insertion.enHistorique {
                Log.error("échec d'insertion : \(insertion.localizedDescription)")
                overlay.showFailure("Insertion impossible",
                                    hint: "Le texte est dans l'historique, menu de Caspr.")
                return insertion.localizedDescription
            }
            let minutes = Double(samples.count) / AudioRecorder.targetSampleRate / 60
            Log.error("échec de transcription (\(version.rawValue)) : \(error.localizedDescription) — "
                      + "\(String(format: "%.1f", minutes)) min conservées")
            livraison.conserver(audio: samples,
                                apercu: apercuConserve() ?? apercu.texte,
                                apresLeRelais: dictee.voie == .chatgpt)
            return "\(error.localizedDescription) — audio conservé, "
                + "« Réessayer » dans le menu."
        }
    }

    /// Transcrit un enregistrement avec la version retenue.
    ///
    /// La Dictée en dernier recours : elle existe partout, et c'est elle qui
    /// dira pourquoi elle ne peut pas écrire, plutôt qu'une version absente.
    private func transcrire(_ samples: [Float], langue: String,
                            par version: EngineChoice) async throws -> String {
        let transcripteur: any TranscripteurMacOS = switch version {
        case .apple: intelligence ?? dicteeSysteme
        case .appleLegacy: dicteeSysteme
        }
        return try await transcripteur.transcribe(samples, language: langue)
    }
}
