import AppKit
import CasprCore

/// Les dernières transcriptions, pour les réinsérer sans reparler.
///
/// Volontairement court : au-delà de quelques entrées, retrouver la bonne dans
/// une liste coûte plus de temps que de redicter la phrase.
///
/// Seul le **texte** est conservé, jamais l'audio. Le stockage passe par les
/// préférences de l'app : effacer une entrée la supprime réellement, sans
/// fichier résiduel ni passage par la corbeille.
@MainActor
final class TranscriptionHistory {
    /// Le format écrit vit dans CasprCore, où il est testé : il doit se
    /// relire dans les versions d'avant comme dans celles d'après.
    typealias Entry = HistoryEntry

    /// Les capacités proposées. Cinq par défaut : au-delà, retrouver la bonne
    /// entrée dans une liste coûte plus de temps que de redicter la phrase —
    /// mais c'est un jugement, pas une loi, et quelqu'un qui enchaîne les
    /// dictées courtes a de bonnes raisons d'en vouloir cinquante.
    static let limits = [5, 10, 20, 50]
    static let defaultLimit = 5

    private static let storageKey = "caspr.history"
    private let storageKey = TranscriptionHistory.storageKey
    private let enabledKey = "caspr.history.enabled"
    private let limitKey = "caspr.history.limit"

    /// Combien d'entrées sont conservées.
    ///
    /// **Réduire la limite ne vide pas l'historique**, il le tronque : passer de
    /// vingt à dix retire les dix plus anciennes et garde les dix récentes.
    /// Tout effacer sur un changement de capacité serait une perte de données
    /// pour un réglage que personne ne lit comme destructeur.
    var limit: Int {
        didSet {
            UserDefaults.standard.set(limit, forKey: limitKey)
            if entries.count > limit {
                entries.removeLast(entries.count - limit)
                persist()
            }
        }
    }

    /// Combien de transcriptions sont stockées, sans instancier l'historique.
    ///
    /// Le désinstalleur doit pouvoir annoncer ce qu'il s'apprête à effacer, et
    /// il n'a aucune raison de posséder un historique pour ça — celui qui
    /// existe appartient au contrôleur de dictée.
    static var storedCount: Int {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return 0 }
        return stored.count
    }

    private(set) var entries: [Entry] = []

    /// Historique désactivable : certains ne veulent aucune trace écrite de ce
    /// qu'ils dictent, même locale.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            if !isEnabled { clear() }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let stored = defaults.integer(forKey: limitKey)
        limit = Self.limits.contains(stored) ? stored : Self.defaultLimit
        if isEnabled, let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored
        }
    }

    /// `brut` : la transcription de ChatGPT quand un module l'a reprise.
    /// Gardée seulement si elle diffère du texte inséré — quand la reprise a
    /// échoué, c'est le brut lui-même qui s'insère.
    func add(_ text: String, brut: String? = nil) {
        guard isEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let brut = (brut?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty || $0 == trimmed ? nil : $0 }

        entries.insert(Entry(text: trimmed, brut: brut), at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
        // Force l'écriture immédiate : sans ça l'effacement demandé par
        // l'utilisateur resterait en attente en mémoire.
        UserDefaults.standard.synchronize()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
