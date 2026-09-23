import Foundation

/// Des `UserDefaults` qui ne quittent jamais la mémoire.
///
/// Les tests de migration prenaient un domaine jetable par test,
/// `UserDefaults(suiteName: "caspr.tests.….<UUID>")`, qu'ils vidaient
/// ensuite par `removePersistentDomain`. Vider n'est pas effacer : macOS
/// laisse le fichier du domaine dans ~/Library/Preferences, et chaque
/// `swift test` en ajoutait une douzaine. Il y en avait 945 sur la machine
/// du propriétaire quand on s'en est aperçu.
///
/// Toutes les lectures et écritures typées sont reprises ici, et pas
/// seulement `object(forKey:)` et `set(_:forKey:)` : Foundation ne promet pas
/// que `bool(forKey:)` ou `set(_: Bool, …)` passent par elles, et une seule
/// qui y échapperait écrirait dans les réglages du lanceur de tests.
final class ReglagesEnMemoire: UserDefaults {
    private var valeurs: [String: Any] = [:]

    init() {
        // `nil` désigne le domaine de l'application, qu'on ne touche jamais :
        // chaque accès est redéfini plus bas.
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { valeurs[defaultName] }

    override func set(_ value: Any?, forKey defaultName: String) {
        valeurs[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        valeurs[defaultName] = nil
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        valeurs[defaultName] = value
    }

    override func set(_ value: Int, forKey defaultName: String) {
        valeurs[defaultName] = value
    }

    override func set(_ value: Double, forKey defaultName: String) {
        valeurs[defaultName] = value
    }

    override func set(_ value: Float, forKey defaultName: String) {
        valeurs[defaultName] = value
    }

    override func set(_ url: URL?, forKey defaultName: String) {
        valeurs[defaultName] = url
    }

    override func bool(forKey defaultName: String) -> Bool {
        (valeurs[defaultName] as? NSNumber)?.boolValue ?? false
    }

    override func integer(forKey defaultName: String) -> Int {
        (valeurs[defaultName] as? NSNumber)?.intValue ?? 0
    }

    override func string(forKey defaultName: String) -> String? {
        valeurs[defaultName] as? String
    }

    override func data(forKey defaultName: String) -> Data? {
        valeurs[defaultName] as? Data
    }

    override func array(forKey defaultName: String) -> [Any]? {
        valeurs[defaultName] as? [Any]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        valeurs[defaultName] as? [String: Any]
    }

    override func dictionaryRepresentation() -> [String: Any] { valeurs }
}
