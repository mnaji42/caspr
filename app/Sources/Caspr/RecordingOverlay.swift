import AppKit
import AVFoundation
import QuartzCore

/// Panneau flottant affiché pendant la dictée.
///
/// Il ne se contente pas d'indiquer que l'enregistrement tourne : il permet de
/// corriger le tir **en parlant**. On se rend compte au milieu d'une phrase
/// qu'on est en mot-à-mot au lieu de texte nettoyé, ou que la destination
/// n'est pas la bonne — il faut pouvoir changer sans arrêter, sinon la dictée
/// est à refaire.
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
///   qui concerne le *texte* en dessous — mode et destination.
@MainActor
final class RecordingOverlay {
    /// Tout ce que la barre affiche, en un seul objet.
    ///
    /// Regroupé parce que ces valeurs bougent ensemble : changer de mode
    /// pendant une dictée doit repeindre la barre entière, et une signature à
    /// six paramètres se serait désynchronisée au premier oubli.
    struct Status {
        var mode: TranscriptionMode
        var target: DictationTarget
        /// Nom du fichier de notes mémorisé, `nil` si aucun.
        var noteName: String?
        /// Faux quand basculer sur les notes exigerait un sélecteur qu'on ne
        /// peut pas ouvrir maintenant.
        var canPickNote: Bool = true
        var previewEnabled: Bool
        /// Faux quand le moteur **retenu** n'a qu'un rendu : la pastille de
        /// mode **disparaît** plutôt que d'être grisée. Un contrôle inerte
        /// occupe la place et l'attention sans rien offrir.
        ///
        /// Retenu, et non celui qui écrit à cet instant. La nuance compte
        /// pendant un repli : CrisperWhisper coché mais son service arrêté,
        /// c'est macOS qui écrit, et macOS ignore le mode. La pastille reste
        /// pourtant, et c'est délibéré — la barre montre l'intention et la
        /// configuration, pas l'état interne du filet de sécurité. La faire
        /// disparaître ferait clignoter la rangée à chaque repli temporaire,
        /// pour un réglage qui redeviendra effectif dès que le service
        /// remontera. Le repli est un filet, pas un mode nominal ; c'est le
        /// bandeau des Réglages qui l'annonce, pas la barre.
        var modesAvailable: Bool = true
        // RELAIS — libellés de rechange pour la pastille des modes.
        //
        // Le relais n'a ni « Texte nettoyé » ni « Mot à mot » : ces deux-là
        // appartiennent à CrisperWhisper. Il a ses propres modes, et la
        // pastille est l'endroit où on les choisit — au moment de parler, pas
        // dans un écran de réglages qu'on n'ouvrira pas pour une phrase.
        var modeLabels: [String]? = nil
        var modeIndex: Int = 0
        var corpusEnabled: Bool
        var corpusKeepsAudio: Bool
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
    }

    private var panel: NSPanel?
    private var timer: Timer?
    /// L'effacement différé d'un message d'échec. Annulé si une dictée
    /// reprend entre-temps, sinon il ferait disparaître la barre suivante.
    private var dismissal: DispatchWorkItem?

    /// Le mode micro vu au dernier examen — cf. `refreshMicrophoneMode`.
    private var micMode = AVCaptureDevice.activeMicrophoneMode
    /// Compteur de battements, pour n'examiner que trois fois par seconde là où
    /// le chrono bat trente fois.
    private var micModeTicks = 0

    private let dot = NSView()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let statusLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let meter = LevelMeter()
    private let modeControl = PillSelector(
        labels: TranscriptionMode.allCases.map(\.label), accent: accent)
    private let targetControl = PillSelector(
        labels: ["Curseur", "Notes…"], accent: accent)
    private let micButton = FirstMouseButton()
    private let languageBadge = NSTextField(labelWithString: "")
    /// Les pastilles de bascule, sous macOS multilingue.
    private let languageControl = PillSelector(labels: [], accent: accent)
    /// Les codes derrière les pastilles, dans le même ordre.
    private var languageCodes: [String] = []
    /// Au-delà de trois langues déclarées : un menu, pas des pastilles.
    ///
    /// Trois pastilles tiennent dans la barre ; cinq la remplissent, et la
    /// destination n'a plus de place. Le menu dit la langue en cours et donne
    /// accès à toutes les autres sans rien élargir.
    private let languageMenu = FirstMouseMenuButton()
    private var menuCodes: [String] = []
    private let corpusBadge = BadgeButton()
    private var container: NSStackView?
    private var recordingRow: NSStackView?
    private var textRow: NSStackView?
    private var previewHeight: NSLayoutConstraint?
    private var card: NSVisualEffectView?
    private var cardSheen: CAGradientLayer?
    private var processingGlow: CALayer?
    private var tabsBelowCard: NSLayoutConstraint?
    private var cardAlone: NSLayoutConstraint?
    /// La carte sous la rangée du mode, ou collée en haut quand elle n'y est pas.
    private var cardBelowMode: NSLayoutConstraint?
    private var cardAtTop: NSLayoutConstraint?
    private var previewLineCount = 1
    /// Composition courante de la rangée d'onglets.
    private var tabsLayout: Layout?

    var levelProvider: (() -> Float)?
    var onSelectMode: ((TranscriptionMode) -> Void)?
    /// RELAIS — appelé à la place du précédent quand `modeLabels` est posé.
    var onSelectModeIndex: ((Int) -> Void)?
    /// RELAIS — vrai quand la pastille porte les modes du relais.
    private var modeLabelsActifs: Bool { status.modeLabels != nil }
    var onSelectTarget: ((Bool) -> Void)?
    var onSelectLanguage: ((String) -> Void)?

    var onToggleCorpus: (() -> Void)?
    var onCancel: (() -> Void)?

    private var startedAt: Date?
    private var pulsePhase: CGFloat = 0
    private var status = Status(mode: .intended, target: .caret, noteName: nil,
                                previewEnabled: false,
                                corpusEnabled: false, corpusKeepsAudio: false)

    // MARK: - Mesures et couleurs

    /// Teinte des états actifs. Une seule dans toute la barre : deux accents
    /// concurrents et plus rien ne ressort.
    ///
    /// La valeur exacte du reste de l'application, et non `systemTeal` : la
    /// teinte système varie d'une version de macOS à l'autre, si bien que la
    /// barre et les Réglages avaient fini par ne plus tout à fait s'accorder.
    /// Cf. `Style.accent`.
    static let accent = NSColor.casprAccent
    /// La collecte a sa propre couleur, et c'est délibéré : c'est le seul
    /// réglage qui écrit sur le disque à l'insu de l'utilisateur. Il doit se
    /// distinguer d'un simple choix de mode.
    private static let collecting = NSColor(srgbRed: 0xFB / 255.0, green: 0x92 / 255.0,
                                            blue: 0x3C / 255.0, alpha: 1)

    private static let rowHeight: CGFloat = 26
    /// La hauteur d'un groupe de pastilles — `PillSelector` fait 28 pt.
    private static let controlRowHeight: CGFloat = 28
    private static let padding: CGFloat = 13
    private static let rowSpacing: CGFloat = 9
    /// Vide entre les onglets flottants et la carte. C'est lui qui les fait
    /// lire comme deux plans distincts.
    private static let tabGap: CGFloat = 9
    private static let previewLines = 3
    private static let previewFontSize: CGFloat = 13
    private static let previewLineHeight: CGFloat = 18
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
    private static let cardWidth: CGFloat = 520
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

        startedAt = Date()
        stopProcessingGlow()
        card?.layer?.borderColor = Self.accent.withAlphaComponent(0.35).cgColor
        statusLabel.isHidden = true
        container?.isHidden = false
        textRow?.isHidden = false
        cardAlone?.isActive = false
        tabsBelowCard?.isActive = true
        // `layoutTabs` remettra la rangée du mode si le moteur la demande ;
        // d'ici là, la carte reprend le haut.
        cardBelowMode?.isActive = false
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
    func showProcessing() {
        guard let panel else { return }
        timer?.invalidate()
        container?.isHidden = true
        textRow?.isHidden = true
        tabsBelowCard?.isActive = false
        cardAlone?.isActive = true
        // La rangée du mode disparaît avec le reste. Laissée en place, elle
        // gardait « Texte nettoyé | Mot à mot » flottant au-dessus d'un message
        // qui ne les concerne pas — et surtout elle continuait de pousser la
        // carte vers le bas pendant que `cardAlone` la retenait par le bas :
        // coincée entre les deux, elle se réduisait à un liseré.
        modeControl.isHidden = true
        cardBelowMode?.isActive = false
        cardAtTop?.isActive = true
        statusLabel.isHidden = false
        // Une ligne, et remise à une ligne : un échec précédent a pu en laisser
        // deux, et la carte se retrouverait haute de deux lignes pour un
        // message qui n'en occupe qu'une.
        statusLabel.maximumNumberOfLines = 1
        statusLabel.stringValue = "Transcription…"
        panel.setContentSize(NSSize(width: Self.cardWidth,
                                    height: 2 * Self.padding + 20))
        cardSheen?.frame = card?.bounds ?? .zero
        position(panel)
        card?.layer?.borderColor = Self.accent.withAlphaComponent(0.40).cgColor
        startProcessingGlow()
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
        stopProcessingGlow()
        container?.isHidden = true
        textRow?.isHidden = true
        tabsBelowCard?.isActive = false
        cardAlone?.isActive = true
        // La rangée du mode disparaît avec le reste. Laissée en place, elle
        // gardait « Texte nettoyé | Mot à mot » flottant au-dessus d'un message
        // qui ne les concerne pas — et surtout elle continuait de pousser la
        // carte vers le bas pendant que `cardAlone` la retenait par le bas :
        // coincée entre les deux, elle se réduisait à un liseré.
        modeControl.isHidden = true
        cardBelowMode?.isActive = false
        cardAtTop?.isActive = true
        statusLabel.isHidden = false
        statusLabel.maximumNumberOfLines = hint == nil ? 1 : 2
        statusLabel.attributedStringValue = Self.failureText(message, hint: hint)

        panel.setContentSize(NSSize(width: Self.cardWidth,
                                    height: 2 * Self.padding
                                        + (hint == nil ? 20 : 38)))
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
        startedAt = nil
        stopProcessingGlow()
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

    private func stopProcessingGlow() {
        processingGlow?.removeFromSuperlayer()
        processingGlow = nil
    }

    var isRecording: Bool { timer != nil }

    func update(_ status: Status) {
        self.status = status

        // RELAIS — les libellés de rechange l'emportent sur les modes de
        // transcription, et pilotent aussi l'index sélectionné.
        if let libelles = status.modeLabels {
            modeControl.setLabels(libelles)
            modeControl.select(min(status.modeIndex, max(libelles.count - 1, 0)))
        } else {
            modeControl.setLabels(TranscriptionMode.allCases.map(\.label))
            modeControl.select(TranscriptionMode.allCases.firstIndex(of: status.mode) ?? 0)
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
        // Sous CrisperWhisper aussi : la requête lui transmet la langue, il n'y
        // a donc aucune raison de retirer la bascule quand il écrit.
        let all = status.switchableLanguages
        let usesMenu = all.count > 3
        let canSwitch = usesMenu || switchable.count > 1

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
        layoutTabs(showMode: status.modesAvailable, switchable: canSwitch,
                   usesMenu: usesMenu)
        layoutMode(showMode: status.modesAvailable)

        targetControl.setLabel(Self.noteLabel(for: status), at: 1)
        targetControl.select(status.target.isLocked ? 1 : 0)
        targetControl.setEnabled(status.noteName != nil || status.canPickNote, at: 1)
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

        corpusBadge.setActive(status.corpusEnabled, color: Self.collecting)
        corpusBadge.toolTip = status.corpusEnabled
            ? (status.corpusKeepsAudio
                ? "Chaque dictée est archivée, audio compris\nCliquer pour arrêter"
                : "Chaque dictée est archivée (texte seul)\nCliquer pour arrêter")
            : "Collecte arrêtée\nCliquer pour archiver les dictées"

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
        + "Sans le lexique : le texte inséré différera\n"
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

    // MARK: - Construction

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
        if status.modesAvailable {
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

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Visible au-dessus du plein écran et sur tous les bureaux : dicter en
        // travaillant ailleurs est précisément l'usage.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // La fenêtre elle-même ne dessine rien : les onglets doivent flotter
        // *à côté* de la carte, séparés par du vide, et non dans un même bloc.
        let root = NSView()
        panel.contentView = root

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Self.accent.withAlphaComponent(0.35).cgColor
        // L'ombre portée du prototype (`0 16px 36px rgba(0, 0, 0, 0.6)`) est
        // déjà rendue par `panel.hasShadow` : macOS la dérive de l'alpha du
        // contenu. La reposer sur le calque obligerait à lever
        // `masksToBounds`, donc à laisser le flou déborder des coins.
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)

        // Le fond de fenêtre de l'application, et rien d'autre.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.casprWindow.cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            tint.topAnchor.constraint(equalTo: card.topAnchor),
            tint.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        // Le reflet du verre : une lumière rasante en haut, qui s'éteint vers
        // le bas. C'est ce dégradé, plus que la transparence, qui donne
        // l'impression d'une surface et non d'un rectangle gris.
        let sheen = CAGradientLayer()
        sheen.colors = [NSColor.white.withAlphaComponent(0.10).cgColor,
                        NSColor.white.withAlphaComponent(0.02).cgColor,
                        NSColor.clear.cgColor]
        sheen.locations = [0, 0.35, 1]
        tint.layer?.addSublayer(sheen)
        cardSheen = sheen
        self.card = card

        buildIndicators()
        buildControls()

        let recording = makeRow([dot, timeLabel, meter, NSView(),
                                 micButton, corpusBadge])
        let tabs = makeSpacedRow([modeControl, targetControl])
        recordingRow = recording
        textRow = tabs

        let inner = NSStackView(views: [recording, previewLabel])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = Self.rowSpacing
        inner.translatesAutoresizingMaskIntoConstraints = false
        container = inner

        card.addSubview(inner)
        root.addSubview(tabs)
        root.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let height = previewLabel.heightAnchor.constraint(
            equalToConstant: Self.previewLineHeight)
        height.isActive = true
        previewHeight = height

        // Deux ancrages hauts pour la carte, un seul actif à la fois : masquer
        // les onglets ne suffit pas, une contrainte reste en vigueur même
        // quand la vue qu'elle vise est cachée. Sans ça, l'état
        // « Transcription… » gardait la place des onglets et la carte se
        // retrouvait écrasée sur quelques pixels.
        // Les onglets sont l'**étage 2, sous la carte** — c'est la géométrie du
        // prototype, et elle se tient : la carte porte ce qu'on écoute, les
        // onglets ce qu'on en fait. Posés au-dessus, ils s'interposaient entre
        // le regard et le texte reconnu, qui est la seule chose qu'on lit
        // vraiment pendant qu'on parle.
        // Le mode de rendu passe **au-dessus**, à droite. Il n'appartient qu'à
        // CrisperWhisper : le laisser en bas obligeait la rangée du bas à se
        // réorganiser selon le moteur, et la destination changeait de place
        // d'une dictée à l'autre. En haut, il apparaît et disparaît sans rien
        // déplacer de ce qui reste.
        root.addSubview(modeControl)
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: root.topAnchor),
            modeControl.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                  constant: -6),
        ])
        cardBelowMode = card.topAnchor.constraint(equalTo: modeControl.bottomAnchor,
                                                  constant: Self.tabGap)
        cardAtTop = card.topAnchor.constraint(equalTo: root.topAnchor)

        tabsBelowCard = tabs.topAnchor.constraint(equalTo: card.bottomAnchor,
                                                  constant: Self.tabGap)
        cardAlone = card.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        tabsBelowCard?.isActive = true

        NSLayoutConstraint.activate([
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // `padding: 0 6px` : les groupes affleurent la carte sans la
            // dépasser, leur ombre portée comprise.
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            tabs.heightAnchor.constraint(equalToConstant: Self.controlRowHeight),

            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                           constant: Self.padding + 4),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                            constant: -(Self.padding + 4)),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.padding),

            recording.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            recording.widthAnchor.constraint(equalTo: inner.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: inner.widthAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            // La carte ne s'élargit plus pour accueillir le message : il faut
            // donc qu'il tienne dedans. Les messages d'échec sont déjà écrits
            // pour ça (cf. `DictationController.shortReason`), et la troncature
            // est le filet pour ceux qui viendraient du système.
            statusLabel.widthAnchor.constraint(
                lessThanOrEqualTo: card.widthAnchor,
                constant: -2 * Self.padding),
        ])
        return panel
    }

    /// La rangée du bas : les langues à gauche, la destination à droite.
    ///
    /// Trois compositions à gauche, selon ce qu'il y a à choisir :
    ///
    /// - **Plusieurs langues, jusqu'à trois** : les pastilles de bascule.
    /// - **Au-delà de trois** : un menu, qui dit la langue en cours sans
    ///   élargir la barre.
    /// - **Une seule** : un simple indicateur, qui dit dans quelle langue on
    ///   parle.
    ///
    /// **Quel que soit le moteur**, y compris CrisperWhisper : la requête lui
    /// transmet la langue, il n'y avait donc aucune raison de lui retirer la
    /// bascule. Elle lui était refusée, et la langue apparaissait au centre en
    /// simple indicateur.
    ///
    /// Le mode de rendu n'est pas ici : il est passé **au-dessus de la carte, à
    /// droite** (cf. `makePanel`). Il n'appartient qu'à CrisperWhisper, et le
    /// laisser en bas obligeait cette rangée à se réorganiser selon le moteur —
    /// la destination changeait alors de place d'une dictée à l'autre.
    ///
    /// Appelée à chaque mise à jour, mais ne fait rien tant que la composition
    /// ne change pas : reconstruire des contraintes vingt fois par seconde
    /// pendant une dictée serait absurde.
    private func layoutTabs(showMode: Bool, switchable: Bool, usesMenu: Bool) {
        let wanted = Layout(showMode: showMode, switchable: switchable,
                            usesMenu: usesMenu)
        guard wanted != tabsLayout || textRow == nil else { return }
        tabsLayout = wanted
        guard let row = textRow else { return }
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // Les langues à gauche, la destination à droite. Toujours, quel que
        // soit le moteur : CrisperWhisper reçoit lui aussi la langue de la
        // requête, il n'y avait donc aucune raison de lui retirer la bascule.
        let left: NSView = !switchable ? languageBadge
            : (usesMenu ? languageMenu : languageControl)
        fill(row, with: [left, targetControl])

    }

    /// La rangée du mode, montrée ou cachée à **chaque** mise à jour.
    ///
    /// Hors de `layoutTabs`, qui sort tôt quand la composition de la rangée du
    /// bas n'a pas bougé : la rangée du haut ne serait alors jamais rétablie
    /// après une transcription ou un échec, qui la cachent tous deux.
    private func layoutMode(showMode: Bool) {
        modeControl.isHidden = !showMode
        cardBelowMode?.isActive = showMode
        cardAtTop?.isActive = !showMode
    }

    private struct Layout: Equatable {
        var showMode: Bool
        var switchable: Bool
        var usesMenu: Bool
    }

    /// Rangée `space-between` : les groupes sont plaqués aux bords.
    ///
    /// C'était `space-evenly`, entretoises de bord comprises, ce qui ramenait
    /// les deux groupes vers le centre — ils flottaient au milieu de la barre
    /// au lieu d'en tenir les extrémités, et l'ensemble ne ressemblait plus à
    /// la maquette. Le prototype pose `justify-content: space-between` : rien
    /// aux bords, tout l'espace entre les groupes.
    private func makeSpacedRow(_ views: [NSView]) -> NSStackView {
        let row = makeRow([])
        row.spacing = 0
        fill(row, with: views)
        return row
    }

    /// Pose les contrôles, et une entretoise **entre** chacun — aucune au bord.
    private func fill(_ row: NSStackView, with views: [NSView]) {
        guard !views.isEmpty else { return }
        var spacers: [NSView] = []
        for (index, view) in views.enumerated() {
            if index > 0 {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
                spacers.append(spacer)
                row.addArrangedSubview(spacer)
            }
            row.addArrangedSubview(view)
        }
        // Trois contrôles sous CrisperWhisper : les deux intervalles doivent
        // rester égaux, sinon la pastille de langue n'est pas au centre.
        for spacer in spacers.dropFirst() {
            spacer.widthAnchor.constraint(equalTo: spacers[0].widthAnchor).isActive = true
        }
    }

    private func makeRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        // La vue vide sert d'entretoise : elle seule doit s'étirer.
        for view in views where type(of: view) == NSView.self {
            view.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        }
        return row
    }

    private func buildIndicators() {
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        timeLabel.textColor = .labelColor
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .center
        // Deux lignes possibles depuis que l'échec porte sa phrase de secours.
        // Sans lever le mode ligne unique, le `\n` qui les sépare s'afficherait
        // comme une espace et la seconde ligne serait tronquée avec la
        // première.
        statusLabel.usesSingleLineMode = false
        statusLabel.cell?.wraps = true
        statusLabel.maximumNumberOfLines = 1
        languageBadge.font = .systemFont(ofSize: 11, weight: .medium)
        languageBadge.textColor = .tertiaryLabelColor
        languageBadge.alignment = .center

        // Italique et discret : l'aperçu ne doit jamais être pris pour le
        // texte qui sera inséré.
        previewLabel.font = NSFontManager.shared.convert(
            .systemFont(ofSize: Self.previewFontSize), toHaveTrait: .italicFontMask)
        previewLabel.textColor = .secondaryLabelColor
        // Repli simple : la coupe est faite en amont, sur la chaîne, donc
        // AppKit n'a plus qu'à mettre à la ligne.
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.maximumNumberOfLines = Self.previewLines
        previewLabel.usesSingleLineMode = false
        previewLabel.cell?.wraps = true
        // Sans ça, le champ impose sa largeur naturelle au panneau : mesuré,
        // une fenêtre de 1164 px pour un écran de 1728, le texte sortant par
        // la droite. Un libellé doit céder, c'est le panneau qui commande.
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            meter.widthAnchor.constraint(equalToConstant: 46),
            meter.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func buildControls() {
        for (button, action) in [(micButton, #selector(openMicrophoneModes))] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.target = self
            button.action = action
            // Réagit sans que Caspr passe au premier plan.
            button.setButtonType(.momentaryChange)
        }
        corpusBadge.title = "COLLECTE"
        corpusBadge.target = self
        corpusBadge.action = #selector(toggleCorpus)

        modeControl.onSelect = { [weak self] index in
            guard let self else { return }
            // RELAIS — des libellés de rechange veulent dire d'autres modes :
            // traduire l'index en `TranscriptionMode` désignerait alors un
            // réglage qui n'a rien à voir avec ce qui est écrit sur la pastille.
            if modeLabelsActifs {
                onSelectModeIndex?(index)
                return
            }
            let modes = TranscriptionMode.allCases
            guard modes.indices.contains(index) else { return }
            onSelectMode?(modes[index])
        }
        targetControl.onSelect = { [weak self] index in
            self?.onSelectTarget?(index == 1)
        }
        languageMenu.target = self
        languageMenu.action = #selector(pickLanguageFromMenu)
        languageControl.onSelect = { [weak self] index in
            guard let codes = self?.languageCodes, codes.indices.contains(index)
            else { return }
            self?.onSelectLanguage?(codes[index])
        }
    }

    @objc private func pickLanguageFromMenu(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard menuCodes.indices.contains(index) else { return }
        onSelectLanguage?(menuCodes[index])
    }

    /// Jette le panneau après un changement d'écrans, et le remonte aussitôt
    /// si une dictée est en cours — sinon la barre disparaîtrait en plein
    /// milieu d'une phrase.
    private func rebuildForNewScreens() {
        guard panel != nil else { return }
        let wasRecording = isRecording
        let elapsed = startedAt

        stopProcessingGlow()
        panel?.orderOut(nil)
        panel = nil
        tabsBelowCard = nil
        cardAlone = nil
        cardBelowMode = nil
        cardAtTop = nil
        container = nil
        recordingRow = nil
        textRow = nil
        card = nil
        cardSheen = nil
        tabsLayout = nil
        NSLog("caspr: écrans modifiés — panneau reconstruit")

        guard wasRecording else { return }
        showRecording(status)
        startedAt = elapsed          // le chrono ne repart pas de zéro
    }

    /// Bas de l'écran, centré — hors du regard et du texte en cours de saisie,
    /// mais visible du coin de l'œil.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + 90))
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

    @objc private func toggleCorpus() { onToggleCorpus?() }

    @objc private func openMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}

/// Pastille d'état, allumée ou éteinte.
///
/// Elle sert de rappel autant que d'interrupteur : la collecte écrit sur le
/// disque, et un réglage qu'on oublie d'avoir activé finit par accumuler des
/// gigaoctets d'audio sans qu'on s'en aperçoive.
private final class BadgeButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 17).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setActive(_ active: Bool, color: NSColor) {
        layer?.backgroundColor = active
            ? color.withAlphaComponent(0.9).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = active ? 0 : 1
        layer?.borderColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.5).cgColor

        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            // L'espacement des lettres fait lire la pastille comme une
            // étiquette d'état plutôt que comme un mot de plus dans la barre.
            .kern: 0.8,
            .foregroundColor: active ? NSColor.white : NSColor.tertiaryLabelColor,
        ])
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 12
        return size
    }
}

/// Bouton qui répond au premier clic dans une fenêtre inactive.
///
/// Le panneau ne devient jamais clé — c'est ce qui garantit que le curseur ne
/// bouge pas. En contrepartie tout clic y est un « premier clic », que
/// `NSControl` ignore par défaut.
/// Un menu déroulant qui répond au premier clic.
///
/// Le panneau ne prend pas le focus — c'est tout son intérêt : il ne vole pas
/// le curseur à l'application dans laquelle on dicte. Mais un contrôle
/// ordinaire consomme alors le premier clic pour activer la fenêtre, et il
/// faut cliquer deux fois. Pendant une dictée, ce premier clic perdu est
/// exactement celui qu'on croyait avoir donné.
final class FirstMouseMenuButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        font = .systemFont(ofSize: 11, weight: .semibold)
        controlSize = .small
    }

    convenience init() { self.init(frame: .zero, pullsDown: false) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas utilisé") }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Barres de niveau sonore, défilant de droite à gauche.
private final class LevelMeter: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    private let barCount = 9
    private var history: [Float] = []

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        history.append(level)
        if history.count > barCount { history.removeFirst(history.count - barCount) }

        let barWidth: CGFloat = 3
        let gap = (bounds.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)

        for index in 0..<barCount {
            let value = index < history.count ? history[history.count - 1 - index] : 0
            let height = max(3, CGFloat(value) * bounds.height)
            // Les barres récentes sont franches, les anciennes s'effacent :
            // le sens de défilement se lit sans y penser.
            let fade = 1 - CGFloat(index) / CGFloat(barCount) * 0.75
            context.setFillColor(NSColor.casprAccent.withAlphaComponent(fade).cgColor)
            let x = bounds.width - CGFloat(index + 1) * barWidth - CGFloat(index) * gap
            let rect = NSRect(x: x, y: (bounds.height - height) / 2,
                              width: barWidth, height: height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5,
                                   cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
    }
}
