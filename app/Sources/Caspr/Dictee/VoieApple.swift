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

    /// Le numéro de l'aperçu dont on accepte encore le texte.
    ///
    /// Pas seulement celui qui écoute : un aperçu arrêté finit son analyse,
    /// et ce qu'il rend alors est la fin de la dictée, celle que le recours
    /// « Insérer l'aperçu » doit contenir. Il cesse de compter quand un autre
    /// le remplace — dictée suivante, changement de langue — ou qu'on annule :
    /// le numéro change.
    private var apercuRetenu = 0

    private let overlay: RecordingOverlay
    private let livraison: Livraison

    init(overlay: RecordingOverlay, livraison: Livraison) {
        self.overlay = overlay
        self.livraison = livraison
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
        apercuRetenu &+= 1
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
        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        // Le niveau crête, et pas seulement la durée. Un compte
        // d'échantillons ne dit pas si l'on a enregistré du son ou du silence,
        // et les deux pannes ne se réparent pas au même endroit : un micro
        // muet se voit ici, une transcription vide se voit plus loin.
        let crete = samples.reduce(Float(0)) { max($0, abs($1)) }
        Log.info("fin d'enregistrement : \(String(format: "%.1f", seconds)) s capturées, "
                 + "crête \(String(format: "%.3f", crete)), "
                 + "moteur \(version.rawValue)")
        return samples
    }

    func annuler() {
        recorder.cancel()
        arreterApercu()
        apercuRetenu &+= 1
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
    /// Rien ne peut interrompre une transcription macOS — elle dure une
    /// seconde : ce chemin n'a pas à vérifier que le cycle est encore le sien.
    ///
    /// `apercuConserve` : ce que l'aperçu en direct avait écrit du même audio,
    /// gardé avec lui comme second recours — celui d'un « Réessayer ». `nil`
    /// pour une dictée qui vient de finir : l'aperçu est alors lu au moment de
    /// l'échec, et non à l'arrêt, parce qu'il finit son analyse après l'arrêt
    /// et peut encore s'allonger pendant la transcription.
    func transcrireEtLivrer(_ samples: [Float], _ dictee: DicteeEnCours,
                            langue: String, apercuConserve: String?) async -> String? {
        let debut = ContinuousClock.now
        do {
            let text = try await transcrire(samples, langue: langue)
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
                                    apercu: apercuConserve ?? previewText,
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
            Log.info("transcrit en \(Log.ms(depuis: debut)) ms, \(text.count) caractères")
            return nil
        } catch {
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
            Log.error("échec de transcription : \(error.localizedDescription) — "
                      + "\(String(format: "%.1f", minutes)) min conservées")
            livraison.conserver(audio: samples,
                                apercu: apercuConserve ?? previewText)
            return "\(error.localizedDescription) — audio conservé, "
                + "« Réessayer » dans le menu."
        }
    }

    /// Transcrit un enregistrement avec la version retenue à l'instant.
    ///
    /// La Dictée en dernier recours : elle existe partout, et c'est elle qui
    /// dira pourquoi elle ne peut pas écrire, plutôt qu'une version absente.
    private func transcrire(_ samples: [Float], langue: String) async throws -> String {
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
    func demarrerApercu(langue: String) {
        guard Preferences.shared.livePreviewEnabled, preview == nil else { return }
        apercuRetenu &+= 1
        let jeton = apercuRetenu
        // La version qui écrira, et nulle autre : cf. `SpeechPreview.engine`.
        guard let made = SpeechPreview.make(
            for: langue,
            onText: { [weak self] text in
                guard let self, apercuRetenu == jeton else { return }
                if previewText.isEmpty, !text.isEmpty {
                    Log.info("aperçu : premier texte reçu")
                }
                // Retenu pour le recours : si la passe finale échoue, c'est
                // un texte de macOS sur exactement le même audio.
                previewText = text
                // Arrêté, l'aperçu n'a plus de barre où s'afficher : elle est
                // passée au traitement.
                if preview != nil { overlay.setPreviewText(text) }
            },
            onFailure: { [weak self] reason in
                Log.error("aperçu indisponible : \(reason)")
                self?.overlay.setPreviewNotice(reason)
            })
        else {
            overlay.setPreviewNotice("aperçu indisponible sur cette machine")
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
