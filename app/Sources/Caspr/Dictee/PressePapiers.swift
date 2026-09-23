import AppKit
import CasprCore

/// Le presse-papiers entier, pour le rendre tel quel.
///
/// Il appartient à l'utilisateur, et Caspr s'en sert pour récupérer une
/// réponse de ChatGPT — son bouton « copier » ne sait écrire que là : pendant
/// une dictée (`RelaisDictee.recuperer`) comme pendant la calibration
/// automatique, qui l'essaie.
///
/// Tous les éléments et tous leurs types, et non la seule chaîne : une image,
/// un fichier ou un texte mis en forme qu'on y gardait ne doit pas revenir en
/// texte brut — ni disparaître.
@MainActor
struct PressePapiers {
    private let elements: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ presse: NSPasteboard) {
        elements = (presse.pasteboardItems ?? []).map { element in
            element.types.compactMap { type in element.data(forType: type).map { (type, $0) } }
        }
    }

    func rendre(_ presse: NSPasteboard) {
        presse.clearContents()
        let rendus = elements.map { types -> NSPasteboardItem in
            let element = NSPasteboardItem()
            for (type, donnees) in types { element.setData(donnees, forType: type) }
            return element
        }
        if !rendus.isEmpty { presse.writeObjects(rendus) }
    }
}

/// Le presse-papiers du système, tel que le scénario d'une dictée s'en sert
/// pour récupérer la réponse (cf. `RelaisDictee`).
extension NSPasteboard: RelaisPressePapiers {
    public func texte() -> String? { string(forType: .string) }

    public func sauvegarder() -> () -> Void {
        let garde = PressePapiers(self)
        return { garde.rendre(self) }
    }
}
