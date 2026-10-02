import AppKit
import AVFoundation
import QuartzCore

/// Panneau flottant affiché pendant la dictée.
///
/// Il ne se contente pas d'indiquer que l'enregistrement tourne : il permet de
/// corriger le tir **en parlant**. On se rend compte au milieu d'une phrase
/// que la langue, la destination ou le module de ChatGPT ne sont pas les bons
/// — il faut pouvoir changer sans arrêter, sinon la dictée est à refaire.
///
/// Quatre contraintes non négociables :
///
/// * **ne jamais prendre le focus.** Le texte doit atterrir dans l'application
///   que l'utilisateur avait devant lui ; une fenêtre qui devient active
///   déplacerait le curseur. D'où un `NSPanel` `.nonactivatingPanel`, dont les
///   contrôles restent cliquables sans activer Caspr.
/// * **montrer qu'on entend.** Un point fixe dit que l'enregistrement est
///   lancé, pas que le micro capte. Le niveau en direct, si.
/// * **montrer l'état, pas seulement l'action.** Des boutons qui font défiler
///   les valeurs obligent à lire le libellé pour savoir où on en est. Des
///   segments montrent la valeur active d'un coup d'œil.
/// * **rester étroite.** Elle vit en bas de l'écran pendant qu'on travaille
///   ailleurs. D'où deux lignes courtes plutôt qu'une longue : ce qui
///   concerne la *captation* en haut — chrono, niveau, micro, aperçu — et ce
///   qui concerne le *texte* en dessous — langue et destination. Les modules
///   de ChatGPT, quand il y en a, passent au-dessus.
@MainActor
final class RecordingOverlay {
    /// Tout ce que la barre affiche, en un seul objet.
    ///
    /// Regroupé parce que ces valeurs bougent ensemble : changer de module
    /// pendant une dictée doit repeindre la barre entière, et une signature à
    /// six paramètres se serait désynchronisée au premier oubli.
    struct Status {
        var target: DictationTarget
        /// Nom du fichier de notes mémorisé, `nil` si aucun.
        var noteName: String?
        /// Faux quand basculer sur les notes exigerait un sélecteur qu'on ne
        /// peut pas ouvrir maintenant.
        var canPickNote: Bool = true
        var previewEnabled: Bool
        /// Les modules de ChatGPT entre lesquels choisir, au-dessus de la
        /// carte.
        ///
        /// La pastille est l'endroit où on les choisit — au moment de parler,
        /// pas dans un écran de réglages qu'on n'ouvrira pas pour une phrase.
        /// Vide, elle **disparaît** plutôt que d'être grisée : un contrôle
        /// inerte occupe la place et l'attention sans rien offrir. C'est le
        /// cas sous macOS, et sous ChatGPT tant qu'un seul module est
        /// possible.
        var moduleLabels: [String] = []
        /// Le module en cours, parmi `moduleLabels`.
        var moduleIndex: Int = 0
        // La destination qu'un module du relais impose, quand il en impose une.
        //
        // « Discuter » n'écrit ni au curseur ni dans les notes : proposer les
        // deux laisserait choisir entre deux options sans effet. Une seule
        // pastille inerte dit ce qui va se passer.
        var destinationImposee: String? = nil
        /// La langue en cours, « 🇫🇷 FR ».
        var languageBadge: String = ""

        /// Les langues entre lesquelles basculer, « 🇫🇷 FR », « 🇬🇧 EN ».
        ///
        /// **Un sélecteur, et non un simple indicateur.** J'avais tranché
        /// l'inverse en croyant que basculer en pleine dictée obligeait à
        /// redémarrer le recognizer pendant qu'il consomme l'audio. C'est faux
        /// ici : l'audio est enregistré et transcrit **à la fin**, et la langue
        /// est lue à ce moment-là. Changer de langue en parlant s'applique donc
        /// au texte réellement inséré, sans rien risquer. Seul l'aperçu en
        /// direct redémarre, et son échec est déjà sans effet sur la dictée.
        ///
        /// Trois au plus, comme le prototype : au-delà, les pastilles mangent
        /// la barre, et une barre d'écoute n'est pas un écran de réglages.
        var switchableLanguages: [(code: String, badge: String)] = []

        /// Le code de la langue en cours, pour savoir quelle pastille éclairer.
        var languageCode: String = ""

        /// Le badge reste à côté des langues, qui passent alors en menu.
        ///
        /// Sous ChatGPT, le badge nomme la voie — sans lui, la barre ne se
        /// distingue pas d'une dictée macOS —, et les langues ne règlent que
        /// l'aperçu en direct : ChatGPT détecte la sienne. Un menu, et non des
        /// pastilles : le badge en prend la place, et ce réglage-là est
        /// secondaire.
        var badgeAvecLesLangues = false
    }

    /// Une attente qui se raconte : ce qu'on attend, depuis quand, et
    /// comment en sortir.
    ///
    /// Relue deux fois par seconde plutôt que poussée : c'est l'attente qui
    /// sait où elle en est, et la barre n'a qu'à regarder.
    struct ProcessingProgress {
        var label: String
        var elapsed: TimeInterval
        var exitHint: String?
    }

    /// Ce que la barre montre, retenu par chaque `show…` et oublié par
    /// `hide` : de quoi la remonter à l'identique après un changement
    /// d'écrans (cf. `rebuildForNewScreens`).
    ///
    /// On le devinait au chrono de l'écoute, que l'attente et l'échec
    /// arrêtaient sans l'oublier : un écran branché pendant l'attente de
    /// ChatGPT remontait une barre « en écoute… », et la touche, pressée
    /// « pour arrêter », renonçait à ChatGPT. Après un échec, cette fausse
    /// écoute annulait l'effacement et restait jusqu'à la dictée suivante.
    enum Mode {
        case ecoute
        case attente(label: String, progress: (() -> ProcessingProgress?)?)
        case echec(message: String, hint: String?)
    }

    private(set) var mode: Mode?

    var panel: NSPanel?
    private var timer: Timer?
    /// Le battement de l'attente, distinct du chrono de l'écoute.
    private var processingTimer: Timer?
    private var processingProgress: (() -> ProcessingProgress?)?
    /// L'effacement différé d'un message d'échec. Annulé si une dictée
    /// reprend entre-temps, sinon il ferait disparaître la barre suivante.
    private var dismissal: DispatchWorkItem?

    /// Le mode micro vu au dernier examen — cf. `refreshMicrophoneMode`.
    private var micMode = AVCaptureDevice.activeMicrophoneMode
    /// Compteur de battements, pour n'examiner que trois fois par seconde là où
    /// le chrono bat trente fois.
    private var micModeTicks = 0

    let dot = NSView()
    let timeLabel = NSTextField(labelWithString: "0:00")
    let statusLabel = NSTextField(labelWithString: "")
    let previewLabel = NSTextField(labelWithString: "")
    let meter = LevelMeter()
    let moduleControl = PillSelector(labels: [], accent: accent)
    let targetControl = PillSelector(
        labels: ["Curseur", "Notes…"], accent: accent)
    let micButton = FirstMouseButton()
    /// La croix : tout annuler, sans rien insérer. Pendant l'écoute, dans sa
    /// rangée ; pendant une attente de ChatGPT, qui peut durer des minutes,
    /// dans la carte, où la rangée de l'écoute est cachée. Le texte déjà en
    /// main reste au menu de Caspr.
    let cancelButton = FirstMouseButton()
    let waitCancelButton = FirstMouseButton()
    let languageBadge = NSTextField(labelWithString: "")
    /// Les pastilles de bascule, sous macOS multilingue.
    let languageControl = PillSelector(labels: [], accent: accent)
    /// Les codes derrière les pastilles, dans le même ordre.
    var languageCodes: [String] = []
    /// Au-delà de trois langues déclarées : un menu, pas des pastilles.
    ///
    /// Trois pastilles tiennent dans la barre ; cinq la remplissent, et la
    /// destination n'a plus de place. Le menu dit la langue en cours et donne
    /// accès à toutes les autres sans rien élargir.
    let languageMenu = FirstMouseMenuButton()
    var menuCodes: [String] = []
    var container: NSStackView?
    var recordingRow: NSStackView?
    var textRow: NSStackView?
    var previewHeight: NSLayoutConstraint?
    var card: NSVisualEffectView?
    var cardSheen: CAGradientLayer?
    private var processingGlow: CALayer?
    var tabsBelowCard: NSLayoutConstraint?
    var cardAlone: NSLayoutConstraint?
    /// La carte sous la rangée des modules, ou collée en haut quand elle n'y
    /// est pas.
    var cardBelowModules: NSLayoutConstraint?
    var cardAtTop: NSLayoutConstraint?
    private var previewLineCount = 1
    /// Composition courante de la rangée d'onglets.
    var tabsLayout: Layout?

    var levelProvider: (() -> Float)?
    /// Le module choisi sur la pastille, par son rang dans `moduleLabels`.
    var onSelectModule: ((Int) -> Void)?
    var onSelectTarget: ((Bool) -> Void)?
    var onSelectLanguage: ((String) -> Void)?

    /// La croix de la barre — le sens d'Échap pendant l'écoute.
    var onCancel: (() -> Void)?

    var startedAt: Date?
    private var pulsePhase: CGFloat = 0
    var status = Status(target: .caret, noteName: nil, previewEnabled: false)

    // MARK: - Mesures et couleurs

    /// Teinte des états actifs. Une seule dans toute la barre : deux accents
    /// concurrents et plus rien ne ressort.
    ///
    /// La valeur exacte du reste de l'application, et non `systemTeal` : la
    /// teinte système varie d'une version de macOS à l'autre, si bien que la
    /// barre et les Réglages avaient fini par ne plus tout à fait s'accorder.
    /// Cf. `Style.accent`.
    static let accent = NSColor.casprAccent

    static let rowHeight: CGFloat = 26
    /// La hauteur d'un groupe de pastilles — `PillSelector` fait 28 pt.
    static let controlRowHeight: CGFloat = 28
    static let padding: CGFloat = 13
    static let rowSpacing: CGFloat = 9
    /// Vide entre les onglets flottants et la carte. C'est lui qui les fait
    /// lire comme deux plans distincts.
    static let tabGap: CGFloat = 9
    static let previewLines = 3
    static let previewFontSize: CGFloat = 13
    static let previewLineHeight: CGFloat = 18
    /// **Largeur unique, dans les trois états.**
    ///
    /// Elle valait 380 à 460 pt selon ce qui était affiché : 210 pt pendant la
    /// transcription, la largeur du message pendant un échec, et une mesure des
    /// contrôles pendant l'enregistrement. La barre changeait donc de taille à
    /// chaque transition, sous les yeux de quelqu'un qui vient de parler —
    /// un saut d'autant plus visible qu'elle est centrée, donc que ses deux
    /// bords bougent en sens contraires.
    ///
    /// Une seule largeur supprime la question. Seul le contenu intérieur
    /// change, et la hauteur suit le nombre de lignes que l'aperçu occupe
    /// réellement — réserver trois lignes en permanence laissait un vide sous
    /// le texte les trois quarts du temps.
    /// 520 pt, là où le prototype en pose 440.
    ///
    /// Le seul écart de dimension assumé avec la maquette : à 440, l'aperçu du
    /// texte reconnu tient trois ou quatre mots par ligne et se replie sans
    /// arrêt pendant qu'on parle. La barre est le seul endroit où l'on relit ce
    /// qu'on vient de dire ; lui donner une ligne utile compte plus que le
    /// nombre exact.
    static let cardWidth: CGFloat = 520
    /// Borne de sécurité avant mesure : trois lignes n'en contiendront jamais
    /// autant, et mesurer la dictée entière à chaque mot serait inutile.
    private static let previewCharacters = 400

    init() {
        // Une fenêtre créée sur un écran qui disparaît reste rattachée à
        // l'espace de cet écran : macOS ne la rapatrie pas. Elle continue
        // d'être ordonnée au premier plan, avec des coordonnées correctes,
        // sans jamais s'afficher — panne observée en débranchant un second
        // écran, et parfaitement muette côté application. On jette donc le
        // panneau à chaque changement d'écrans ; le suivant sera reconstruit
        // dans l'espace courant.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildForNewScreens() }
        }
    }

    // MARK: - Cycle de vie

    func showRecording(_ status: Status) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Appuyer sur la touche de dictée l'emporte sur tout le reste.
        //
        // Un message d'échec programme sa propre fermeture cinq secondes plus
        // tard. Reparler dans cet intervalle laissait ce minuteur courir : il
        // se déclenchait en pleine phrase et faisait disparaître la barre sous
        // les yeux de quelqu'un qui était en train de dicter. Le geste dit
        // « je continue » ; ce qui précédait n'a plus à être lu.
        dismissal?.cancel()
        dismissal = nil

        mode = .ecoute
        startedAt = Date()
        stopProcessingGlow()
        stopProcessingProgress()
        card?.layer?.borderColor = Self.accent.withAlphaComponent(0.35).cgColor
        statusLabel.isHidden = true
        waitCancelButton.isHidden = true
        container?.isHidden = false
        textRow?.isHidden = false
        cardAlone?.isActive = false
        tabsBelowCard?.isActive = true
        // `layoutModules` remettra la rangée des modules s'il y en a ;
        // d'ici là, la carte reprend le haut.
        cardBelowModules?.isActive = false
        cardAtTop?.isActive = true
        // Une ligne vide laisserait croire que l'aperçu est en panne le temps
        // que les premiers mots arrivent.
        setPreviewNotice(status.previewEnabled ? "en écoute…" : "")
        update(status)

        panel.orderFrontRegardless()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Bascule sur « transcription en cours ».
    ///
    /// Sur une longue dictée le traitement prend plusieurs secondes ; sans ce
    /// retour, on croit à un échec et on relance.
    ///
    /// - Parameters:
    ///   - label: ce qu'on attend. Le relais s'en sert aussi avant l'écoute,
    ///     quand la page ChatGPT n'est pas encore prête.
    ///   - progress: l'attente elle-même, relue en continu, quand elle
    ///     peut durer des minutes. Sans elle, « Transcription… » restait
    ///     immobile trois minutes durant, que ChatGPT transcrive ou réponde,
    ///     et rien ne disait qu'on pouvait en sortir.
    func showProcessing(_ label: String = "Transcription…",
                        progress: (() -> ProcessingProgress?)? = nil) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        stopProcessingProgress()
        // Le relais l'affiche aussi avant l'écoute, juste après un échec dont
        // la fermeture programmée l'aurait retirée en pleine attente.
        dismissal?.cancel()
        dismissal = nil
        timer?.invalidate()
        timer = nil
        mode = .attente(label: label, progress: progress)
        container?.isHidden = true
        textRow?.isHidden = true
        tabsBelowCard?.isActive = false
        cardAlone?.isActive = true
        // La rangée des modules disparaît avec le reste. Laissée en place, elle
        // flottait au-dessus d'un message qui ne la concerne pas — et surtout
        // elle continuait de pousser la carte vers le bas pendant que
        // `cardAlone` la retenait par le bas : coincée entre les deux, elle se
        // réduisait à un liseré.
        moduleControl.isHidden = true
        cardBelowModules?.isActive = false
        cardAtTop?.isActive = true
        statusLabel.isHidden = false
        // Une ligne, et remise à une ligne : un échec précédent a pu en laisser
        // deux, et la carte se retrouverait haute de deux lignes pour un
        // message qui n'en occupe qu'une.
        statusLabel.maximumNumberOfLines = 1
        statusLabel.stringValue = label
        // Seulement devant une attente qui peut durer : celle de macOS dure
        // une seconde, et rien ne l'interrompt.
        waitCancelButton.isHidden = progress == nil
        panel.setContentSize(NSSize(width: Self.cardWidth,
                                    height: 2 * Self.padding + 20))
        cardSheen?.frame = card?.bounds ?? .zero
        position(panel)
        card?.layer?.borderColor = Self.accent.withAlphaComponent(0.40).cgColor
        panel.orderFrontRegardless()
        startProcessingGlow()

        guard let progress else { return }
        processingProgress = progress
        refreshProcessingProgress()
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.refreshProcessingProgress() }
        }
    }

    /// Réécrit la ligne d'attente : la phase, puis le temps écoulé et la
    /// sortie dès dix secondes.
    ///
    /// Pas avant : la plupart des dictées aboutissent en quelques secondes,
    /// et un chrono qui s'affiche pour disparaître aussitôt n'est que du
    /// bruit. Passé dix secondes, en revanche, une barre sans chiffre se lit
    /// comme un gel, et l'on relance une dictée déjà en cours.
    ///
    /// Une ligne, jamais deux : la carte a été taillée et son liseré tracé
    /// pour elle, et la redimensionner en pleine attente ferait sauter l'un
    /// et l'autre.
    private func refreshProcessingProgress() {
        guard let progress = processingProgress?() else { return }
        let seconds = Int(progress.elapsed)
        guard seconds >= 10 else {
            statusLabel.stringValue = progress.label
            return
        }
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let text = NSMutableAttributedString(
            string: progress.label + " " + String(format: "%d:%02d", seconds / 60, seconds % 60),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centred,
            ])
        // La sortie en 11 pt : elle nomme la croix, et la ligne doit tenir
        // à côté d'elle — 448 pt mesurés pour la plus longue, sur 520.
        if let hint = progress.exitHint {
            text.append(NSAttributedString(string: " — " + hint, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: centred,
            ]))
        }
        statusLabel.attributedStringValue = text
    }

    private func stopProcessingProgress() {
        processingTimer?.invalidate()
        processingTimer = nil
        processingProgress = nil
    }

    /// Montre un échec, puis s'efface toute seule.
    ///
    /// L'échec ne s'affichait que dans la barre des menus : l'icône devenait
    /// un triangle, et le message n'existait que dans une infobulle et dans un
    /// menu qu'il faut dérouler. Or quelqu'un qui vient de dicter regarde son
    /// curseur et cette barre-ci. Il voyait donc simplement que rien ne
    /// s'écrivait, sans aucune raison de soupçonner qu'une explication
    /// l'attendait ailleurs — au point de croire s'être mal servi de
    /// l'application.
    ///
    /// Le message est court exprès : la barre tient sur une ligne, et le
    /// détail complet reste dans le menu, avec « Réessayer ».
    ///
    /// - Parameter hint: la seconde ligne, plus discrète, qui dit que la dictée
    ///   n'est pas perdue et où la récupérer. Elle existe parce que la barre
    ///   s'efface au bout de cinq secondes — on ne la garde pas ouverte, le cas
    ///   le plus fréquent n'étant même pas un échec mais un déclenchement sans
    ///   parole — alors qu'elle est le seul endroit où l'on regarde à cet
    ///   instant. Disparaître sans rien dire laissait croire que dix minutes de
    ///   parole venaient de partir.
    func showFailure(_ message: String, hint: String? = nil) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        timer?.invalidate()
        timer = nil
        mode = .echec(message: message, hint: hint)
        stopProcessingGlow()
        stopProcessingProgress()
        container?.isHidden = true
        textRow?.isHidden = true
        tabsBelowCard?.isActive = false
        cardAlone?.isActive = true
        // La rangée des modules disparaît avec le reste. Laissée en place, elle
        // flottait au-dessus d'un message qui ne la concerne pas — et surtout
        // elle continuait de pousser la carte vers le bas pendant que
        // `cardAlone` la retenait par le bas : coincée entre les deux, elle se
        // réduisait à un liseré.
        moduleControl.isHidden = true
        cardBelowModules?.isActive = false
        cardAtTop?.isActive = true
        statusLabel.isHidden = false
        waitCancelButton.isHidden = true
        // Un message venu d'ailleurs peut ne pas tenir sur une ligne — le
        // refus de ChatGPT, dont la fin dit quand réessayer. Il prend alors
        // la seconde ligne, plutôt que de perdre justement cette fin.
        let texte = Self.failureText(message, hint: hint)
        let deuxLignes = hint != nil
            || texte.size().width > Self.cardWidth - 2 * Self.padding
        statusLabel.maximumNumberOfLines = deuxLignes ? 2 : 1
        statusLabel.attributedStringValue = texte

        panel.setContentSize(NSSize(width: Self.cardWidth,
                                    height: 2 * Self.padding
                                        + (deuxLignes ? 38 : 20)))
        cardSheen?.frame = card?.bounds ?? .zero
        position(panel)
        card?.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.35).cgColor
        panel.orderFrontRegardless()

        // Assez pour être lu, pas assez pour gêner la dictée suivante.
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        timer?.invalidate()
        timer = nil
        mode = nil
        startedAt = nil
        stopProcessingGlow()
        stopProcessingProgress()
        panel?.orderOut(nil)
    }

    /// Liseré lumineux qui fait le tour de la carte pendant la transcription.
    ///
    /// Sans lui, l'état « Transcription… » est parfaitement immobile : sur une
    /// longue dictée, plusieurs secondes sans le moindre mouvement se lisent
    /// comme un plantage, et on relance une dictée déjà en cours.
    ///
    /// Un dégradé conique tournant plutôt qu'un trait qui parcourt le
    /// contour : `strokeStart`/`strokeEnd` butent sur les bornes 0 et 1, donc
    /// l'arc s'y écrase à chaque tour. La rotation, elle, boucle sans couture.
    /// Le dégradé tourne à l'intérieur d'un calque porteur, et c'est ce
    /// dernier qui porte le masque — masquer le dégradé lui-même ferait
    /// tourner le masque avec, et il n'y aurait plus de contour du tout.
    private func startProcessingGlow() {
        guard let card, let host = card.layer else { return }
        stopProcessingGlow()
        card.layoutSubtreeIfNeeded()
        let bounds = card.bounds
        guard bounds.width > 0 else { return }

        let outline = CAShapeLayer()
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                              cornerWidth: 15, cornerHeight: 15, transform: nil)
        outline.fillColor = nil
        outline.strokeColor = NSColor.black.cgColor      // seul l'alpha compte
        outline.lineWidth = 2

        let carrier = CALayer()
        carrier.frame = bounds
        carrier.mask = outline

        let side = max(bounds.width, bounds.height) * 1.5
        let glow = CAGradientLayer()
        glow.type = .conic
        glow.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side)
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        glow.colors = [Self.accent.withAlphaComponent(0).cgColor,
                       Self.accent.cgColor,
                       Self.accent.withAlphaComponent(0).cgColor,
                       Self.accent.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.06, 0.30, 1]
        carrier.addSublayer(glow)
        host.addSublayer(carrier)

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1.6
        spin.repeatCount = .infinity
        glow.add(spin, forKey: "rotation")
        processingGlow = carrier
    }

    func stopProcessingGlow() {
        processingGlow?.removeFromSuperlayer()
        processingGlow = nil
    }

    func update(_ status: Status) {
        self.status = status

        if !status.moduleLabels.isEmpty {
            moduleControl.setLabels(status.moduleLabels)
            moduleControl.select(min(status.moduleIndex, status.moduleLabels.count - 1))
        }
        languageBadge.stringValue = status.languageBadge

        // Trois pastilles au plus, et la langue en cours toujours parmi
        // elles : au-delà, les pastilles mangent la barre, mais en cacher la
        // langue active reviendrait à ne plus dire dans quelle langue on parle.
        // La liste et l'ordre viennent du statut, donc de l'ordre de
        // déclaration des langues : elles ne se réordonnent pas en pleine
        // dictée sous les doigts de quelqu'un qui vise.
        var switchable = Array(status.switchableLanguages.prefix(3))
        if !switchable.contains(where: { $0.code == status.languageCode }),
           let current = status.switchableLanguages.first(where: {
               $0.code == status.languageCode
           }) {
            switchable = [current] + switchable.dropLast()
        }
        let all = status.switchableLanguages
        let usesMenu = all.count > 3 || (status.badgeAvecLesLangues && all.count > 1)
        let canSwitch = usesMenu || switchable.count > 1
        languageMenu.toolTip = status.badgeAvecLesLangues
            ? "Langue de l'aperçu de macOS\nChatGPT détecte la sienne" : nil

        if usesMenu, all.map(\.code) != menuCodes {
            menuCodes = all.map(\.code)
            languageMenu.removeAllItems()
            languageMenu.addItems(withTitles: all.map(\.badge))
        }
        if usesMenu, let index = menuCodes.firstIndex(of: status.languageCode) {
            languageMenu.selectItem(at: index)
        }
        if canSwitch, switchable.map(\.code) != languageCodes {
            languageCodes = switchable.map(\.code)
            languageControl.setLabels(switchable.map(\.badge))
        }
        if canSwitch,
           let index = languageCodes.firstIndex(of: status.languageCode) {
            languageControl.select(index)
        }

        // Masquer ne suffit pas à recentrer : les entretoises restent en
        // place et le contrôle survivant se retrouve décalé d'une demi-
        // entretoise. On refait la rangée avec les seuls contrôles visibles.
        layoutTabs(switchable: canSwitch, usesMenu: usesMenu,
                   badge: canSwitch && status.badgeAvecLesLangues)
        layoutModules(show: showsModules)

        if let imposee = status.destinationImposee {
            targetControl.setLabels([imposee])
            targetControl.select(0)
            targetControl.setEnabled(false, at: 0)
        } else {
            targetControl.setLabels(["Curseur", Self.noteLabel(for: status)])
            targetControl.select(status.target.isLocked ? 1 : 0)
            targetControl.setEnabled(status.noteName != nil || status.canPickNote, at: 1)
        }
        // Court, et sur deux lignes : macOS ne replie pas les infobulles, une
        // phrase entière produit une bulle plus large que la moitié de l'écran.
        targetControl.toolTip = status.noteName.map {
            "Ajouté à \($0)\nVaut aussi pour la dictée en cours"
        } ?? "Aucun fichier de notes\nEn choisir un dans le menu de Caspr"

        micMode = AVCaptureDevice.activeMicrophoneMode
        micButton.attributedTitle = Self.buttonTitle(Self.microphoneModeLabel)
        micButton.toolTip = "Mode micro du système\nCliquer pour le changer"

        previewLabel.toolTip = Self.previewExplanation
        previewLabel.isHidden = !status.previewEnabled

        resize()
    }

    /// Texte reconnu en direct.
    ///
    /// Ne change ni la largeur ni la position : seule la hauteur suit, et
    /// uniquement quand le nombre de lignes change — deux fois par dictée au
    /// plus, jamais à chaque mot.
    func setPreviewText(_ text: String) {
        guard status.previewEnabled else { return }
        let (visible, lines) = visibleTail(of: text)
        previewLabel.stringValue = visible
        // Plus lisible que le gris des messages d'état : c'est le seul
        // contenu de la barre qu'on lit vraiment, en parlant.
        previewLabel.textColor = .secondaryLabelColor
        setPreviewLines(lines)
    }

    /// Portion affichable du texte : sa **fin**, repliée sur trois lignes au
    /// plus, précédée de points de suspension si on a coupé.
    ///
    /// Calculée ici plutôt que confiée à `.byTruncatingHead`, et c'est une
    /// correction : ce mode de coupe force `NSTextField` en ligne unique, donc
    /// il est incompatible avec le repli. Combinés, on obtenait une seule
    /// ligne tronquée par la fin — exactement l'inverse de ce qu'il faut, où
    /// c'est le dernier mot prononcé qui doit rester visible.
    ///
    /// On cherche donc le plus long suffixe qui tienne dans la boîte, par
    /// dichotomie sur la position de départ.
    private func visibleTail(of text: String) -> (String, Int) {
        guard let font = previewLabel.font, !text.isEmpty else { return (text, 1) }
        let width = previewLabel.bounds.width > 0
            ? previewLabel.bounds.width
            : Self.cardWidth - 2 * (Self.padding + 4)
        guard width > 0 else { return (text, 1) }

        let ceiling = CGFloat(Self.previewLines) * Self.previewLineHeight
        func height(_ candidate: String) -> CGFloat {
            (candidate as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]).height
        }
        func lineCount(_ candidate: String) -> Int {
            max(1, min(Self.previewLines,
                       Int((height(candidate) / Self.previewLineHeight).rounded())))
        }

        // Trois lignes ne contiendront jamais plus de quelques centaines de
        // caractères : mesurer la dictée entière à chaque mot coûterait cher
        // pour rien.
        let bounded = text.count > Self.previewCharacters
            ? String(text.suffix(Self.previewCharacters))
            : text
        if bounded.count == text.count, height(bounded) <= ceiling {
            return (bounded, lineCount(bounded))
        }

        let characters = Array(bounded)
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high) / 2
            if height("… " + String(characters[middle...])) <= ceiling {
                high = middle
            } else {
                low = middle + 1
            }
        }
        let tail = "… " + String(characters[low...])
        return (tail, lineCount(tail))
    }

    private func setPreviewLines(_ lines: Int) {
        guard lines != previewLineCount else { return }
        previewLineCount = lines
        resize()
    }

    /// Message sur l'aperçu lui-même — attente, téléchargement, indisponibilité
    /// — à la place du texte reconnu.
    func setPreviewNotice(_ message: String) {
        previewLabel.stringValue = message
        previewLabel.textColor = .tertiaryLabelColor
        setPreviewLines(1)
    }

    private static let previewExplanation =
        "Aperçu indicatif, par le moteur de macOS\n"
        + "Le texte inséré peut différer\n"
        + "Cliquer pour l'activer ou le couper"

    /// Nom court : la largeur de la barre suit celle des contrôles, donc un
    /// nom de fichier long la ferait grossir d'autant. Le nom entier reste
    /// dans l'infobulle.
    private static func noteLabel(for status: Status) -> String {
        guard let name = status.noteName else { return "Notes…" }
        let short = name.count > 14 ? name.prefix(13) + "…" : name[...]
        return "Notes › \(short)"
    }

    /// Mode micro courant, tel que macOS le rapporte.
    ///
    /// Lecture seule : Apple ne laisse aucune application imposer ce réglage,
    /// c'est un choix de l'utilisateur. On peut en revanche ouvrir le panneau
    /// système, ce qui évite d'aller le chercher dans le Centre de contrôle.
    private static var microphoneModeLabel: String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: "Isolement"
        case .wideSpectrum: "Large"
        default: "Standard"
        }
    }

    /// La raison, puis ce qu'on peut encore en faire.
    ///
    /// Deux graisses et deux gris : la première ligne dit ce qui s'est passé,
    /// la seconde où le rattraper. Composées dans une seule chaîne plutôt que
    /// dans deux libellés — le message est centré dans la carte, et deux vues
    /// empilées demanderaient de recalculer ce centrage à chaque état.
    private static func failureText(_ message: String,
                                    hint: String?) -> NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineSpacing = 2

        let text = NSMutableAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centred,
        ])
        guard let hint else { return text }
        text.append(NSAttributedString(string: "\n" + hint, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: centred,
        ]))
        return text
    }

    private static func buttonTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// Hauteur seule : la largeur ne bouge jamais (cf. `cardWidth`).
    private func resize() {
        guard let panel else { return }
        var height = Self.controlRowHeight + Self.tabGap
            + Self.padding + Self.rowHeight + Self.padding
        if showsModules {
            height += Self.controlRowHeight + Self.tabGap
        }
        if status.previewEnabled {
            height += Self.rowSpacing + CGFloat(previewLineCount) * Self.previewLineHeight
        }
        previewHeight?.constant = CGFloat(previewLineCount) * Self.previewLineHeight
        previewLabel.isHidden = !status.previewEnabled
        panel.setContentSize(NSSize(width: Self.cardWidth, height: height))
        // Les couches Core Animation ne suivent pas Auto Layout.
        cardSheen?.frame = card?.bounds ?? .zero
        position(panel)
    }

    private func tick() {
        if let startedAt {
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            timeLabel.stringValue = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        }
        meter.level = levelProvider?() ?? 0

        pulsePhase += 0.09
        dot.layer?.opacity = Float(0.55 + 0.45 * (sin(pulsePhase) + 1) / 2)

        refreshMicrophoneMode()
    }

    /// Suit le mode micro pendant que la barre est ouverte.
    ///
    /// Il se change dans le Centre de contrôle — ou par le clic sur cette
    /// pastille même, qui ouvre le panneau système — c'est-à-dire précisément
    /// pendant qu'on dicte. Le libellé n'était écrit qu'au montage de la barre,
    /// dans `update(_:)` : il annonçait « Standard » alors qu'on venait de
    /// passer en Isolement, sur le seul contrôle qui existe pour surveiller ce
    /// réglage-là.
    ///
    /// AVFoundation ne notifie rien sur ce changement : il faut regarder. À
    /// trois examens par seconde le retard ne se perçoit pas, et la lecture
    /// d'une propriété de classe ne coûte rien face aux trente battements du
    /// chrono.
    private func refreshMicrophoneMode() {
        micModeTicks += 1
        guard micModeTicks >= 10 else { return }
        micModeTicks = 0

        let mode = AVCaptureDevice.activeMicrophoneMode
        guard mode != micMode else { return }
        micMode = mode
        micButton.attributedTitle = Self.buttonTitle(Self.microphoneModeLabel)
    }
}
