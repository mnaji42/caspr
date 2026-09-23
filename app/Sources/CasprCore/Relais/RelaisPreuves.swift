import Foundation

/// Ce que la calibration automatique a **vu faire** à chaque repère.
///
/// Un repère n'y entre que par son effet observé : la zone de texte relit ce
/// qu'on y a écrit, le micro fait enregistrer la page, l'arrêt ramène la zone
/// de texte, l'envoi ouvre une conversation, « copier » remplit le
/// presse-papiers de la réponse. Un libellé qui ressemble ne prouve rien — il
/// change avec la langue de l'interface, et c'est en s'y fiant que le relais a
/// déjà appris le bloc autour de la zone de texte au lieu de la zone.
///
/// ## Rien ne s'écrit tant que tout n'est pas prouvé
///
/// Le parcours manuel enregistre repère par repère, et c'est tolérable : chaque
/// repère y est désigné par une main, qui voit ce qu'elle clique. Un automate
/// qui ferait de même et échouerait à mi-chemin — une page qui charge mal, un
/// quota atteint avant la réponse — remplacerait en silence la moitié d'un
/// calibrage qui marchait depuis des semaines par la moitié d'un autre. Les
/// preuves s'accumulent donc à part, et `calibrage(remplacant:)` ne rend un
/// calibrage que lorsque l'aller-retour entier a été vu.
public struct RelaisPreuves: Equatable {
    /// Les repères que le parcours automatique éprouve, dans l'ordre où il les
    /// éprouve — chacun a besoin des précédents pour exister.
    ///
    /// Sans « Lire à haute voix » : il se cache parfois derrière le menu
    /// « … », qui porte aussi « Régénérer » et « Supprimer ». Un automate qui
    /// ouvre ce menu et en clique les entrées à l'aveugle finira par faire
    /// quelque chose d'irréversible sur le compte de quelqu'un. Il reste à
    /// montrer à la main.
    public static let parcours: [RelaisCible] = [.composeur, .micro, .stop, .envoi, .copier]

    public private(set) var selecteurs: [RelaisCible: String] = [:]
    /// Le bloc qui porte le bouton « copier », vide quand aucun ne se laisse
    /// désigner sans ambiguïté : la page retombe alors sur sa recherche autour
    /// de la dernière réponse, et c'est ce chemin-là que la preuve a éprouvé.
    public private(set) var copierParent = ""
    /// Pourquoi un repère manque, dit à l'utilisateur tel quel.
    public private(set) var raisons: [RelaisCible: String] = [:]

    public init() {}

    /// Retient un repère dont l'effet a été observé.
    ///
    /// Un sélecteur vide ne prouve rien, et un repère hors du parcours n'a pas
    /// été éprouvé par lui : l'un et l'autre sont ignorés, plutôt que de
    /// laisser un appel distrait écrire ce que personne n'a vu.
    public mutating func prouve(_ cible: RelaisCible, _ selecteur: String, parent: String = "") {
        guard Self.parcours.contains(cible), !selecteur.isEmpty else { return }
        selecteurs[cible] = selecteur
        raisons[cible] = nil
        if cible == .copier { copierParent = parent }
    }

    /// Note qu'un repère n'a pas pu être prouvé, et pourquoi.
    public mutating func manque(_ cible: RelaisCible, _ raison: String) {
        guard Self.parcours.contains(cible), selecteurs[cible] == nil else { return }
        raisons[cible] = raison
    }

    public var manquants: [RelaisCible] { Self.parcours.filter { selecteurs[$0] == nil } }

    /// L'aller-retour entier a-t-il été vu ?
    public var complet: Bool { manquants.isEmpty }

    /// Le calibrage à enregistrer, ou `nil` tant que le parcours n'est pas
    /// prouvé en entier.
    ///
    /// Tiré de l'ancien, dont il garde tout ce que le parcours n'éprouve pas :
    /// « Lire à haute voix », qui reste manuel, et le repère de la réponse des
    /// calibrages d'avant le bouton « copier », que la page consulte encore
    /// pour retrouver la dernière réponse.
    public func calibrage(remplacant ancien: RelaisSelecteurs) -> RelaisSelecteurs? {
        guard complet else { return nil }
        var nouveau = ancien
        for (cible, selecteur) in selecteurs { nouveau[cible] = selecteur }
        nouveau.copierParent = copierParent
        return nouveau
    }
}
