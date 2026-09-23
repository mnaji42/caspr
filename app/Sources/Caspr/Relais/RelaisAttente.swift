import Foundation

/// L'attente d'une dictée ChatGPT, de l'arrêt de l'écoute à la livraison :
/// ce qu'on attend, et depuis quand. **Rien de plus — aucune échéance.**
///
/// Elle en a porté une, fixée à l'arrêt sur la durée parlée, qui faisait
/// échouer la dictée sur « ChatGPT n'a pas répondu en 3 min ». Or ChatGPT met
/// parfois dix, vingt, trente secondes, ou plusieurs minutes, à transcrire une
/// longue dictée puis à y répondre : ce n'est pas au temps de décider qu'on
/// renonce (cf. RELAIS.md, sixième règle). Seul l'utilisateur met fin à une
/// attente, ou un échec que la page prouve.
///
/// Ce qui reste est ce qui rend l'attente supportable : la barre montre la
/// phase, puis le chrono et la sortie dès dix secondes (cf.
/// `Relais.avancement`) — une barre sans chiffre se lit comme un gel.
@MainActor
final class RelaisAttente: ObservableObject {
    /// Ce qu'on attend de ChatGPT à cet instant.
    ///
    /// Publiée pour que la barre le dise : « Transcription… » pendant que
    /// ChatGPT répond, c'était annoncer une étape déjà franchie, et le temps
    /// passé ne se lisait nulle part.
    enum Phase: String {
        case transcription
        case envoi
        case reponse
        case lecture

        /// Le libellé de la barre, en quelques mots.
        var libelle: String {
            switch self {
            case .transcription: "ChatGPT transcrit…"
            case .envoi: "Envoi à ChatGPT…"
            case .reponse: "ChatGPT répond…"
            case .lecture: "Lecture à haute voix…"
            }
        }
    }

    let debut = Date.now
    @Published private(set) var phase: Phase = .transcription

    var ecoule: TimeInterval { Date.now.timeIntervalSince(debut) }

    /// Change de phase, et le journal dit après combien de temps : c'est la
    /// seule trace de ce que chaque étape de ChatGPT a coûté.
    func entrer(_ nouvelle: Phase) {
        guard nouvelle != phase else { return }
        Log.info("relais : \(phase.rawValue) → \(nouvelle.rawValue) "
                 + "après \(String(format: "%.1f", ecoule)) s")
        phase = nouvelle
    }
}
