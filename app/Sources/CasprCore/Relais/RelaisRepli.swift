import Foundation

/// Ce que devient une dictée ChatGPT quand on renonce à lui — la touche de
/// dictée pendant l'attente — ou que la page prouve un échec (cf.
/// `RelaisCycle.replie`) : livrer le meilleur texte qu'on ait, sans attendre
/// ChatGPT davantage.
///
/// « Si c'est l'utilisateur qui décide de quitter, si c'était possible de
/// récupérer quand même le texte via Apple Intelligence » : renoncer ne
/// jetait pas seulement la réponse, mais tout ce qui avait été dit, tant que
/// ChatGPT n'avait pas rendu sa transcription. Le son que la page captait en
/// existe pourtant une copie (cf. `RelaisScripts.echo`), et la voie macOS
/// sait l'écrire.
public enum RelaisRepli: Equatable, Sendable {
    /// La transcription de ChatGPT est déjà lue : c'est elle qui s'insère, à
    /// la destination figée à l'arrêt.
    case inserer(String)
    /// Rien de ChatGPT, mais le son de la page : macOS le transcrit.
    case transcrireParMacOS
    /// Ni brut ni son utilisable — un contexte de la page qui n'a pas tourné
    /// à 16 kHz —, mais l'aperçu de macOS en a écrit, depuis ce même son :
    /// c'est lui qui s'insère, le seul texte de la dictée qui reste.
    case insererLApercu(String)
    /// Le module n'écrit nulle part : rien ne s'insère, et ce qu'on a va au
    /// menu de Caspr.
    case garder
    /// Rien à livrer : le chemin d'échec, ou d'abandon, d'avant le repli.
    case rien

    /// Le seuil de la voie macOS : en deçà, un appui-relâché, rien
    /// d'exploitable — et le moteur réveillé pour rien.
    public static let secondesMinimales = 0.3

    /// La crête au-delà de laquelle le son de la page passe pour une voix.
    /// Basse, délibérément : un bruit pris pour une voix ne coûte qu'un
    /// passage de macOS sur ce bruit, une voix prise pour un bruit coûtait
    /// la dictée. À éprouver sur la ligne de l'écho, qui donne la crête de
    /// chaque dictée (cf. `RelaisEcho.desarmer`).
    public static let creteDeParole: Float = 0.03

    /// ChatGPT a rendu une zone vide : l'entendait-on pourtant parler ? Le
    /// son l'a montré, ou l'aperçu en a écrit. Vrai, ce n'est pas un silence
    /// mais une dictée que ChatGPT a perdue, et le repli la reprend (34).
    public static func parole(crete: Float, apercu: String) -> Bool {
        crete >= creteDeParole || !apercu.allSatisfy(\.isWhitespace)
    }

    /// macOS, sur le son d'une zone que ChatGPT a rendue vide, n'y entend
    /// rien non plus : deux moteurs, le même son, aucun mot. C'était un
    /// silence que la crête a pris pour une voix — le clic de la touche, un
    /// souffle —, et la dictée finit comme un appui sans parole : « Rien n'a
    /// été entendu », rien au menu (34, 57). Le seuil de `parole` peut ainsi
    /// rester bas sans qu'un appui muet laisse un son à « Réessayer ». Un
    /// aperçu écrit prouve une voix, lui : il reste au menu, avec le son.
    public static func silence(apres cause: RelaisErreur?, apercu: String) -> Bool {
        cause == .rienTranscrit && apercu.allSatisfy(\.isWhitespace)
    }

    /// Le brut d'abord, puis le son entier, puis l'aperçu : la transcription
    /// de macOS relit toute la phrase, l'aperçu l'a écrite en l'entendant.
    ///
    /// `macOSPret` : macOS sait écrire la langue sans rien télécharger ni
    /// rien demander. Sinon, le son n'est pas transcrit — un modèle à
    /// télécharger tenait « Transcription… » des minutes, et un droit jamais
    /// demandé ouvrait son dialogue au milieu d'une dictée : il reste au
    /// menu, où « Réessayer » le transcrira quand on l'aura choisi.
    public static func choisir(brutLu brut: String?, secondesAudio: Double, ecrit: Bool,
                               apercu: String = "", macOSPret: Bool = true) -> RelaisRepli {
        // Un brut vide a déjà fini la dictée sur « Rien n'a été entendu » :
        // ce n'est pas un texte à livrer.
        let brut = brut.flatMap { $0.isEmpty ? nil : $0 }
        let son = secondesAudio >= secondesMinimales
        let apercu = apercu.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ecrit else { return brut != nil || son || !apercu.isEmpty ? .garder : .rien }
        if let brut { return .inserer(brut) }
        if son, macOSPret { return .transcrireParMacOS }
        if !apercu.isEmpty { return .insererLApercu(apercu) }
        return son ? .garder : .rien
    }

    /// Ce que dit la barre une fois le repli fait : d'où vient le texte, et
    /// pourquoi ce n'est pas de ChatGPT. `nil` pour `rien`, qui a son chemin.
    ///
    /// Sans quoi un texte de macOS passe pour celui de ChatGPT, et un quota
    /// atteint pour une transcription médiocre.
    ///
    /// `son`, `parle` : les secondes que l'écho a reçues, et celles qu'on a
    /// parlé. Un contexte audio parti tard, des morceaux perdus, et macOS ne
    /// transcrit qu'une partie de la dictée : le texte s'insère quand même —
    /// une partie vaut mieux que rien —, mais pas pour le tout.
    public static func annonce(_ repli: RelaisRepli, apres cause: RelaisErreur?,
                               son: Double = 0, parle: Double = 0) -> String? {
        guard var issue = repli.issue else { return nil }
        if repli == .transcrireParMacOS, !couvre(son: son, parle: parle) {
            issue += " (\(Int(son.rounded())) s de son sur \(Int(parle.rounded())) s)"
        }
        guard let cause else {
            return issue.prefix(1).uppercased() + issue.dropFirst()
                + (repli == .garder ? "" : " — \(motif(apres: nil))")
        }
        return "\(motif(apres: cause)) — \(issue)"
    }

    /// Ce que devient la dictée, sans d'où vient le repli ni le texte qu'il
    /// porte ; `nil` pour `rien`.
    public var issue: String? {
        switch self {
        case .inserer: "transcription brute insérée"
        case .transcrireParMacOS: "transcrit par macOS"
        case .insererLApercu: "aperçu de macOS inséré"
        case .garder: "gardé dans le menu de Caspr"
        case .rien: nil
        }
    }

    /// Ce que le journal dit d'un repli : sa cause et son issue, sans le
    /// texte d'un refus. L'annonce, elle, le porte — la barre et le menu
    /// doivent dire d'emblée si c'est un quota —, et un relevé qui se trompe
    /// y a mis les mots dictés (cf. `RelaisErreur.pourLeJournal`).
    public static func pourLeJournal(_ repli: RelaisRepli, apres cause: RelaisErreur?) -> String {
        "repli après \(cause.map(RelaisErreur.pourLeJournal) ?? "la touche") — "
            + (repli.issue ?? "rien à livrer")
    }

    /// Pourquoi on s'est passé de ChatGPT : ce que la barre montre pendant
    /// que macOS transcrit, et ce que le menu garde si macOS échoue à son
    /// tour — sans quoi un quota atteint ne se lirait nulle part.
    public static func motif(apres cause: RelaisErreur?) -> String {
        guard let cause else { return "ChatGPT abandonné" }
        // « Dictée perdue », que la barre dit d'une page morte, serait faux ici.
        return cause == .pageInterrompue ? "La page ChatGPT s'est fermée"
            : cause.raisonCourte ?? "ChatGPT a échoué"
    }

    /// Le son reçu couvre-t-il ce qu'on a dit ? Une seconde de jeu, ou un
    /// dixième d'une longue dictée : l'écho s'arme avant le clic du micro,
    /// la durée parlée se compte depuis la preuve d'écoute, et le contexte
    /// audio de la page met un instant à tourner. Un seuil à éprouver sur la
    /// ligne de l'écho, qui compare les deux à chaque dictée (cf.
    /// `RelaisEcho.desarmer`). `parle` nul : rien à comparer.
    public static func couvre(son: Double, parle: Double) -> Bool {
        parle - son <= max(1, parle / 10)
    }
}
