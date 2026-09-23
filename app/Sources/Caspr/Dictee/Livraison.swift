import AppKit
import CasprCore

/// Ce qui arrive à un texte une fois dicté, quelle que soit la voie qui l'a
/// écrit : rendre le clavier, l'insérer là où il doit aller, le ranger dans
/// l'historique, et, quand la dictée échoue, garder ce qui permet de la
/// reprendre.
///
/// Les deux voies partagent cette queue, et c'est ici qu'elles la partagent —
/// pas en amont. Le partage se faisait par un protocole de moteur que la voie
/// ChatGPT ne remplissait qu'en recevant un enregistrement vide et en
/// inventant ses latences : ce qui est commun, c'est ce qu'on fait du texte,
/// pas la façon de l'obtenir.
///
/// Ne décide pas de l'état de la dictée : c'est le contrôleur qui sait si le
/// cycle qu'une livraison sert est encore le sien.
@MainActor
final class Livraison {
    let history = TranscriptionHistory()
    private let injector: TextInjector
    private let overlay: RecordingOverlay

    init(injector: TextInjector, overlay: RecordingOverlay) {
        self.injector = injector
        self.overlay = overlay
    }

    // MARK: - Insérer

    /// Écrit le texte d'une dictée à sa destination, là où l'on parlait, puis
    /// l'archive et oublie le recours (cf. `ecrire`).
    ///
    /// `brut` : la transcription de ChatGPT, quand un module l'a reprise —
    /// l'historique la garde à côté du texte inséré (cf.
    /// `TranscriptionHistory.Entry.brut`).
    func livrer(_ text: String, _ dictee: DicteeEnCours, brut: String? = nil) async throws {
        // Rendre le clavier avant d'écrire. Après une discussion, ou si l'on
        // bascule vers un module qui écrit en pleine dictée, la fenêtre du
        // relais est au premier plan : le texte y partirait.
        //
        // Pour une dictée ChatGPT seulement : c'est elle qui a mis cette
        // fenêtre devant. Sous une dictée macOS, une fenêtre du relais à
        // l'écran n'est pas de son fait — la calibration qu'ouvre un passage
        // à ChatGPT en pleine phrase, par exemple — et la cacher la ferait
        // disparaître sans explication.
        switch dictee.voie {
        case .chatgpt: await Relais.partage.rendreLeClavier()
        case .apple: break
        }
        try await ecrire(text, vers: dictee.destination, depuis: dictee.applicationVisee,
                         brut: brut)
    }

    /// L'insertion a échoué sur un texte qui, lui, existe : l'accessibilité
    /// retirée, le fichier de notes devenu illisible.
    ///
    /// Distincte des échecs de transcription, parce qu'elle ne se reprend pas
    /// pareil. Confondue avec eux, elle faisait dire « Transcription
    /// impossible » à la barre ; sous ChatGPT, elle ouvrait la fenêtre du
    /// relais comme si la page avait échoué, et le texte remanié n'était
    /// plus nulle part — ni dans l'historique, ni dans le menu, qui ne gardait
    /// que le brut.
    struct EchecDInsertion: LocalizedError {
        let cause: Error
        /// Faux quand l'historique est désactivé : ne pas promettre qu'on
        /// l'y retrouvera.
        let enHistorique: Bool

        var errorDescription: String? {
            cause.localizedDescription
                + (enHistorique ? " Le texte est dans l'historique." : "")
        }
    }

    /// `visee` est l'application capturée à l'appui : l'insertion par
    /// accessibilité vise l'élément focalisé **au moment d'écrire**, et l'on a
    /// pu changer d'application pendant la transcription.
    private func ecrire(_ text: String, vers target: DictationTarget,
                        depuis visee: NSRunningApplication?,
                        brut: String? = nil) async throws {
        switch target {
        case .caret: await ramener(visee)
        case .file: break
        }
        // La touche de dictée abandonne jusqu'ici, et l'insertion ne vérifie
        // rien : un texte arrivé au moment de l'abandon s'écrivait quand même.
        try Task.checkCancellation()
        // L'application au premier plan au moment d'insérer. L'insertion par
        // accessibilité vise l'élément focalisé de cette application-là : si
        // c'est Caspr, le texte part dans une de nos propres fenêtres et
        // disparaît sans qu'aucune erreur ne soit levée. C'était
        // indiagnosticable de l'extérieur.
        let devant = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        Log.info("insertion vers \(devant)")
        // Archivé avant d'écrire, et donc même quand l'écriture échoue :
        // l'historique est le filet d'un texte qu'une insertion aurait perdu,
        // et c'est exactement ce cas-là.
        history.add(text, brut: brut)
        do {
            try await deliver(text, to: target)
        } catch {
            throw EchecDInsertion(cause: error, enHistorique: history.isEnabled)
        }
        // Le texte est écrit : l'audio, l'aperçu ou le brut gardés pour le
        // reprendre n'ont plus d'objet. Oublié ici, et non par chaque
        // appelant après coup : la voie ChatGPT le faisait après avoir vérifié
        // que son cycle était encore en cours, et un appui pendant l'insertion
        // — l'attente du collage avale l'abandon — laissait au menu le brut
        // d'un texte déjà écrit, qu'un clic insérait une seconde fois. Le
        // cycle d'après ne peut pas avoir gardé le sien entre-temps : il lui
        // faut écouter, puis être transcrit.
        oublierLeRecours()
    }

    /// Achemine le texte vers une destination.
    ///
    /// Sur cible verrouillée, l'insertion au curseur est délibérément évitée :
    /// l'intérêt du verrou est justement de pouvoir continuer à travailler
    /// ailleurs sans que la dictée vienne s'écrire dans le code en cours.
    func deliver(_ text: String, to target: DictationTarget) async throws {
        switch target {
        case .caret:
            try await injector.inject(text)
        case .file(let url):
            try TargetWriter.append(text, to: url)
            NSLog("caspr: ajouté à %@", url.lastPathComponent)
        }
    }

    /// L'application au premier plan, sauf si c'est Caspr.
    static func applicationDevant() -> NSRunningApplication? {
        guard let devant = NSWorkspace.shared.frontmostApplication,
              devant.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return nil }
        return devant
    }

    /// Ramène au premier plan l'application où l'on parlait, si l'on en est
    /// parti et qu'elle tourne encore.
    ///
    /// Le système ne garantit ni que l'activation ait lieu, ni quand : on
    /// **observe** donc qu'elle soit devant, une seconde au plus, avant
    /// d'écrire. Passé ce délai, ou si elle a été quittée, le texte part là où
    /// l'on se trouve — c'était le comportement d'avant, et l'historique le
    /// garde de toute façon.
    ///
    /// ## Deux façons de demander, parce que la première peut être ignorée
    ///
    /// Depuis macOS 14, l'activation est **coopérative** : c'est l'application
    /// au premier plan qui cède sa place, et une demande venue d'une
    /// application qui ne l'a pas peut être ignorée. Or c'est le cas visé :
    /// pendant l'attente de ChatGPT, on est passé dans une autre application,
    /// et Caspr — que `rendreLeClavier` vient de cacher — n'a rien à céder.
    /// La demande polie reste la première, et suffit quand Caspr est devant
    /// (la fenêtre du relais, après une discussion). Sinon, on passe par
    /// l'accessibilité, que l'insertion exige déjà : `kAXFrontmostAttribute`
    /// est l'attribut que le système lui-même expose pour mettre une
    /// application devant, et il ne dépend pas de qui la demande.
    ///
    /// ## Abandonnable
    ///
    /// La touche de dictée abandonne une dictée ChatGPT jusqu'ici (cf.
    /// `DictationController.abandonnerLeCycleRelais`). L'attente ne la voyait
    /// pas : elle tournait à vide jusqu'à la seconde, puis mettait devant, par
    /// l'accessibilité, une application où plus rien ne serait écrit. Elle
    /// rend donc la main dès l'abandon, et `ecrire` le constate aussitôt.
    private func ramener(_ application: NSRunningApplication?) async {
        guard let application, !application.isTerminated, !Task.isCancelled else { return }
        let workspace = NSWorkspace.shared
        func devant() -> Bool {
            workspace.frontmostApplication?.processIdentifier == application.processIdentifier
        }
        guard !devant() else { return }
        let nom = application.bundleIdentifier ?? application.localizedName ?? "?"
        if NSApp.isActive { NSApp.yieldActivation(to: application) }
        application.activate(options: [])

        let echeance = ContinuousClock.now + .seconds(1)
        // Un cinquième de la seconde pour la demande polie : au-delà, elle a
        // été ignorée, et l'on insiste par l'accessibilité — sur la même
        // échéance, pas sur une nouvelle.
        let relance = ContinuousClock.now + .milliseconds(200)
        var parAccessibilite = false
        while ContinuousClock.now < echeance {
            guard !Task.isCancelled else { return }
            if devant() {
                Log.info("insertion : retour à \(nom), où l'on parlait"
                         + (parAccessibilite ? " (par l'accessibilité)" : ""))
                return
            }
            if !parAccessibilite, ContinuousClock.now >= relance {
                parAccessibilite = true
                let resultat = AXUIElementSetAttributeValue(
                    AXUIElementCreateApplication(application.processIdentifier),
                    kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                if resultat != .success {
                    Log.error("insertion : \(nom) refuse le premier plan par "
                              + "l'accessibilité (\(resultat.rawValue))")
                }
            }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
        Log.error("insertion : \(nom) n'a pas repris le premier plan en 1 s — "
                  + "texte inséré devant")
    }

    // MARK: - Destination

    /// Bascule entre curseur et notes, sans jamais rien redétecter.
    ///
    /// Le fichier de notes est mémorisé indépendamment de la destination
    /// courante : revenir au curseur ne l'oublie pas, et y retourner ne coûte
    /// qu'un clic. La version précédente relançait la détection à chaque
    /// bascule, donc pouvait ouvrir un sélecteur au milieu d'une phrase — un
    /// panneau modal qui active Caspr, déplace le curseur et avale les
    /// frappes, c'est-à-dire tout ce que la barre flottante évite par
    /// ailleurs. `selecteurPossible` est donc faux pendant qu'on parle.
    func choisirLesNotes(_ wantsNotes: Bool, selecteurPossible: Bool) {
        guard wantsNotes else {
            Preferences.shared.destination = .caret
            return
        }
        if Preferences.shared.noteFile != nil {
            Preferences.shared.destination = .notes
            return
        }
        guard selecteurPossible else {
            NSLog("caspr: aucun fichier de notes mémorisé — en choisir un depuis le menu")
            return
        }
        choisirLeFichierDeNotes()
    }

    /// Choisit le fichier des notes, et écrit dedans à partir de maintenant.
    ///
    /// On tente d'abord le document ouvert devant : dans ce cas il suffit de
    /// poser le curseur dans le fichier voulu, sans passer par un sélecteur.
    private func choisirLeFichierDeNotes() {
        var chosen = TargetWriter.frontmostDocument()
        if chosen == nil {
            // Détection impossible : plutôt qu'un sélecteur surgissant sans
            // raison apparente, on dit pourquoi avant de le proposer.
            NSLog("caspr: fichier non identifié — sélecteur")
            chosen = TargetWriter.chooseFile()
        }
        guard let chosen else { return }
        Preferences.shared.noteFile = chosen
        Preferences.shared.destination = .notes
        NSLog("caspr: notes dans %@", chosen.path)
    }

    // MARK: - Échec et recours

    /// Audio d'une dictée dont la transcription a échoué. Conservé en mémoire
    /// vive uniquement, et libéré dès qu'une insertion réussit ou que
    /// l'utilisateur y renonce.
    ///
    /// Une dictée peut durer dix minutes. Perdre cet audio parce que la
    /// transcription a échoué obligerait à tout redire — c'est le pire échec
    /// possible pour cette application.
    private(set) var pendingAudio: [Float]?

    /// Ce que l'aperçu en direct avait déjà écrit, quand la passe finale a
    /// échoué — ou, sur la voie ChatGPT, sa transcription brute (cf.
    /// `garderLeBrut`).
    ///
    /// Le moteur de macOS a transcrit pendant qu'on parlait. Si la passe finale
    /// échoue, ce texte existe, il est bon — moins soigné que la passe finale,
    /// qui a toute la phrase sous les yeux — et il était jeté. On proposait
    /// donc de « réessayer » comme seule issue, y compris quand la cause de
    /// l'échec ne s'arrangera pas d'un second essai : un modèle absent
    /// manquera encore.
    ///
    /// Figé ici plutôt que relu dans l'aperçu au moment de l'insertion : ce
    /// dernier est remis à zéro au début de la dictée suivante, et l'on peut
    /// très bien reparler avant de décider quoi faire de la précédente.
    private var pendingPreview: String?

    /// La voie qui a laissé le recours : l'aperçu de macOS, ou la
    /// transcription brute de ChatGPT. Le menu les nomme différemment, et
    /// seule la seconde a pu laisser la fenêtre du relais devant.
    private(set) var voieDuRecours: VoieDeDictee = .apple

    /// Garde de quoi reprendre une dictée ratée, et le dit dans la barre.
    ///
    /// Les deux vont ensemble : la barre promet « Réessayer », et c'est cet
    /// audio qui tient la promesse. Promettre sans garder, c'est ce que faisait
    /// la voie ChatGPT, qui n'a pas d'audio de ce côté-ci.
    ///
    /// Dit là où l'utilisateur regarde. La barre des menus reçoit le détail,
    /// mais on ne consulte pas un menu qu'on n'a pas de raison d'ouvrir : sans
    /// ça, un échec se lit comme « je m'y suis mal pris ». `echec` tient en
    /// une ligne, parce que la barre ne reste que cinq secondes.
    func conserver(audio: [Float], apercu: String,
                   echec: String = "Transcription impossible — « Réessayer » dans le menu") {
        pendingAudio = audio
        pendingPreview = apercu
        voieDuRecours = .apple
        overlay.showFailure(echec, hint: Self.rescueHint(preview: apercu))
    }

    /// Garde la transcription de ChatGPT dès qu'elle est lue, **avant** que
    /// le module ne la reprenne.
    ///
    /// C'est le filet de la voie ChatGPT, qui n'a pas d'audio à rejouer. La
    /// transcription existait et mourait dans une variable : quand la suite
    /// échouait — l'insertion refusée, l'attente d'une réponse abandonnée à
    /// la touche —, il ne restait qu'à aller la chercher dans la page, si
    /// elle y était encore. Gardée ici, elle passe par l'entrée de menu qui
    /// servait déjà à l'aperçu de macOS.
    ///
    /// Elle remplace le recours d'une dictée précédente : le menu ne propose
    /// que celui de la dernière, et un « Réessayer » posé au-dessus du brut
    /// d'une autre dictée ne se lirait pas. Une livraison réussie l'oublie
    /// comme elle oublie l'aperçu.
    func garderLeBrut(_ brut: String) {
        pendingAudio = nil
        pendingPreview = brut
        voieDuRecours = .chatgpt
    }

    /// Insère ce que l'aperçu en direct avait écrit, faute de mieux.
    ///
    /// La seconde issue d'un échec, et souvent la bonne : quand la version de
    /// macOS choisie ne sait pas écrire ici, réessayer échouera pareil, alors
    /// que le texte de l'aperçu est là et se suffit à lui-même. Moins soigné
    /// que la passe finale, mais un texte imparfait vaut mieux que dix minutes
    /// de parole à redire.
    ///
    /// Le menu de Caspr ne prend pas le premier plan : l'application devant
    /// est celle où l'on veut le texte, comme à l'appui. Et la destination du
    /// moment, comme pour « Réessayer » : c'est une nouvelle livraison.
    ///
    /// L'audio est libéré comme après une insertion réussie : on a choisi cette
    /// issue-là, et garder l'autre en réserve laisserait « Réessayer » dans le
    /// menu au-dessus d'un texte déjà écrit. Si l'insertion elle-même échoue —
    /// plus de curseur, fichier devenu illisible —, on garde tout : c'est un
    /// autre problème que celui qu'on essayait de contourner, et il se répare.
    func insererLApercu() async throws {
        guard let text = pendingPreviewText else { return }
        // Un échec de la voie ChatGPT ouvre la fenêtre du relais pour qu'on y
        // récupère le texte, et Caspr passe devant : le brut s'écrirait dans
        // la page. Même geste qu'à la livraison (cf. `livrer`).
        switch voieDuRecours {
        case .chatgpt: await Relais.partage.rendreLeClavier()
        case .apple: break
        }
        try await ecrire(text, vers: Preferences.shared.effectiveTarget,
                         depuis: Self.applicationDevant())
    }

    /// Libère l'audio et l'aperçu conservés : une insertion a réussi, ou
    /// l'utilisateur y renonce.
    func oublierLeRecours() {
        pendingAudio = nil
        pendingPreview = nil
        voieDuRecours = .apple
    }

    var hasPendingAudio: Bool { pendingAudio != nil }

    /// L'aperçu conservé, s'il porte quelque chose d'insérable.
    var pendingPreviewText: String? {
        guard let text = pendingPreview?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }

    var pendingDuration: TimeInterval {
        Double(pendingAudio?.count ?? 0) / AudioRecorder.targetSampleRate
    }

    /// La phrase qui dit que rien n'est perdu, sous le message d'échec.
    ///
    /// La barre s'efface au bout de cinq secondes, et c'est voulu : la laisser
    /// ouverte sur un échec encombrerait l'écran, d'autant que le cas le plus
    /// fréquent n'en est pas un — on a déclenché sans parler. Mais elle est le
    /// seul endroit où l'on regarde à ce moment-là, et disparaître sans rien
    /// dire laisse croire que la dictée est perdue.
    ///
    /// Elle nomme donc les deux issues quand les deux existent, et la seule
    /// quand il n'y en a qu'une : sans aperçu — parce qu'il est coupé, ou
    /// parce qu'on n'a effectivement rien dit — proposer d'insérer un texte
    /// vide serait une fausse promesse de plus.
    private static func rescueHint(preview: String) -> String {
        preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Rien n'est perdu : « Réessayer » dans le menu de Caspr."
            : "Rien n'est perdu : insérer l'aperçu ou réessayer, dans le menu de Caspr."
    }
}
