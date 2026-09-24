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
    /// Le module n'écrit nulle part : rien ne s'insère, et ce qu'on a va au
    /// menu de Caspr.
    case garder
    /// Rien à livrer : le chemin d'échec, ou d'abandon, d'avant le repli.
    case rien

    /// Le seuil de la voie macOS : en deçà, un appui-relâché, rien
    /// d'exploitable — et le moteur réveillé pour rien.
    public static let secondesMinimales = 0.3

    public static func choisir(brutLu brut: String?, secondesAudio: Double, ecrit: Bool) -> RelaisRepli {
        // Un brut vide a déjà fini la dictée sur « Rien n'a été entendu » :
        // ce n'est pas un texte à livrer.
        let brut = brut.flatMap { $0.isEmpty ? nil : $0 }
        let son = secondesAudio >= secondesMinimales
        guard ecrit else { return brut != nil || son ? .garder : .rien }
        if let brut { return .inserer(brut) }
        return son ? .transcrireParMacOS : .rien
    }

    /// Ce que dit la barre une fois le repli fait : d'où vient le texte, et
    /// pourquoi ce n'est pas de ChatGPT. `nil` pour `rien`, qui a son chemin.
    ///
    /// Sans quoi un texte de macOS passe pour celui de ChatGPT, et un quota
    /// atteint pour une transcription médiocre.
    public static func annonce(_ repli: RelaisRepli, apres cause: RelaisErreur?) -> String? {
        let issue: String
        switch repli {
        case .inserer: issue = "transcription brute insérée"
        case .transcrireParMacOS: issue = "transcrit par macOS"
        case .garder: issue = "gardé dans le menu de Caspr"
        case .rien: return nil
        }
        guard let cause else {
            return issue.prefix(1).uppercased() + issue.dropFirst()
                + (repli == .garder ? "" : " — ChatGPT abandonné")
        }
        // « Dictée perdue », que la barre dit d'une page morte, serait faux ici.
        let motif = cause == .pageInterrompue ? "La page ChatGPT s'est fermée"
            : cause.raisonCourte ?? "ChatGPT a échoué"
        return "\(motif) — \(issue)"
    }
}
