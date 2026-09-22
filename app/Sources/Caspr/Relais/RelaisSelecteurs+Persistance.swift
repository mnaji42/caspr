import Foundation
import CasprCore

// La structure vit dans CasprCore, où son décodage est sous tests ; sa
// persistance reste ici, parce qu'elle touche aux réglages réels de
// l'utilisateur et qu'un test n'a rien à y écrire.
extension RelaisSelecteurs {
    // MARK: - Persistance

    private static let cle = "relais.selecteurs"

    static func charger() -> RelaisSelecteurs {
        guard let data = UserDefaults.standard.data(forKey: cle),
              let s = try? JSONDecoder().decode(RelaisSelecteurs.self, from: data)
        else { return RelaisSelecteurs() }
        return s
    }

    func enregistrer() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.cle)
    }
}
