import Foundation

/// Ce que prouve un relevé de la page (`RelaisInstantane`), jugé sans elle.
///
/// Les attentes d'une dictée n'ont pas de fin (RELAIS.md, sixième règle) :
/// seuls l'utilisateur et un échec que la page **prouve** les arrêtent. Ce qui
/// compte pour une preuve se décide ici, pur, et se teste.
public struct RelaisVeille {
    /// Le message est parti : une alerte inconnue peut alors être un refus.
    public let apresEnvoi: Bool
    private var silences = 0

    public init(apresEnvoi: Bool) { self.apresEnvoi = apresEnvoi }

    /// Le refus de ChatGPT que prouve ce relevé, ou `nil`. Seulement sur un
    /// relevé qui porte les alertes : un relevé sans elles romprait le compte.
    ///
    /// Un échec reconnu par ses motifs interrompt sur-le-champ. Avant l'envoi,
    /// rien d'autre ne compte : on n'a rien demandé à quoi refuser. Après,
    /// une alerte nouvelle qu'aucun motif ne connaît — un quota atteint à
    /// l'instant — ne compte que tant que ChatGPT ne répond pas : aucune
    /// réponse nouvelle, aucune génération en cours. Sans cette condition, une
    /// bannière « limite bientôt atteinte » apparue à l'envoi faisait jeter la
    /// réponse que ChatGPT était en train d'écrire. Et ce silence doit durer
    /// trois relevés d'affilée : juste après l'envoi, la réponse met un
    /// instant à paraître, et une bannière tombée dans ce creux passerait
    /// sinon pour un refus.
    public mutating func refus(_ vu: RelaisInstantane) -> String? {
        guard let echec = vu.echec else { silences = 0; return nil }
        if echec.reconnue { return echec.texte }
        guard apresEnvoi else { return nil }
        if let r = vu.reponse, r.nouvelles > 0 || r.enCours { silences = 0; return nil }
        silences += 1
        return silences >= 3 ? echec.texte : nil
    }

    /// La session que montre ce relevé : vrai, connectée ; faux, l'écran de
    /// connexion ; `nil` quand la page n'a rien dit.
    ///
    /// Connectée : un élément de l'application — zone de saisie, micro ou
    /// arrêt, la zone disparaissant pendant qu'on dicte — sans aucun signe
    /// d'authentification, qui l'emporte : ChatGPT montre une zone et un
    /// micro à qui n'est pas connecté. Rien du tout, c'est une page qui se
    /// charge, pas une session fermée.
    public static func session(_ vu: RelaisInstantane) -> Bool? {
        if vu.authentification { return false }
        return vu.composeur || vu.micro || vu.stop ? true : nil
    }

    /// La dernière ligne non vide de la consigne — ce qui, dans la zone, signe
    /// le message envoyé, et ce qu'une copie ne doit pas contenir ; vide
    /// quand elle n'a que des blancs.
    ///
    /// Meilleure empreinte que le début du texte : elle est courte, très
    /// distinctive, et elle ne souffre pas de la façon dont la page replie les
    /// espaces d'un long paragraphe. Une consigne de blancs rendait ces
    /// blancs, que la zone ne relit jamais tels quels : l'envoi attendait sa
    /// relecture, et échouait.
    public static func empreinte(_ consigne: String) -> String {
        consigne.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
    }

    /// La transcription qui revient dans la zone de saisie, rendue quand elle
    /// cesse de bouger.
    ///
    /// **La zone doit d'abord revenir.** Pendant la dictée, ChatGPT la retire
    /// au profit de la barre d'onde, et elle ne revient qu'après la
    /// transcription, dont la durée suit celle de la dictée.
    ///
    /// **Le texte doit ensuite cesser de bouger.** Il arrive par fragments, et
    /// le flux marque entre deux des pauses plus longues qu'on ne l'imagine :
    /// une seconde pleine sans changement, et non 500 ms, seuil qui coupait la
    /// phrase. Un texte qui bouge encore n'est jamais rendu : coupé au milieu,
    /// il s'insérerait sans que rien signale la coupure.
    ///
    /// **Une zone revenue qui reste vide** dit que ChatGPT n'a rien
    /// transcrit — appuyer sans parler est un geste ordinaire. Quatre
    /// secondes, et non une : la zone revient d'ordinaire déjà remplie, mais
    /// rien ne garantit que les deux arrivent au même instant. C'est un
    /// jugement sur une zone revenue, pas une échéance : ChatGPT a déjà rendu
    /// la main. Et il ne perd plus rien : si la page entendait une voix,
    /// c'est macOS qui la transcrit (cf. `RelaisRepli.parole`).
    public struct Stabilisation {
        public enum Issue: Equatable { case texte(String), vide }
        private var revenue = false, precedent = "", stable = 0, vides = 0

        public init() {}

        /// Un relevé de la zone : son texte, `nil` quand elle est introuvable
        /// — absente avant son retour, vide après.
        public mutating func juger(_ zone: String?) -> Issue? {
            guard revenue else { revenue = zone != nil; return nil }
            let texte = zone ?? ""
            defer { precedent = texte }
            guard !texte.isEmpty else {
                stable = 0
                vides += 1
                return vides >= 16 ? .vide : nil          // ~4 s
            }
            vides = 0
            guard texte == precedent else { stable = 0; return nil }
            stable += 1
            return stable >= 4 ? .texte(texte) : nil      // ~1 s sans changement
        }
    }

    /// La réponse attendue est-elle finie ?
    ///
    /// Nouvelle — postérieure à la marque : la précédente, qu'une discussion
    /// porte déjà, est finie et immobile depuis longtemps —, plus en cours
    /// d'écriture, et de même longueur depuis `seuil` relevés. Ou le bouton
    /// « copier » de son tour est là : il n'apparaît qu'une fois la réponse
    /// finie. Les pauses entre deux fragments d'une longue réponse dépassent
    /// régulièrement la seconde, et un seuil trop court rendrait un texte
    /// coupé au milieu.
    public struct ReponseFinie {
        private let seuil: Int
        private var precedente = -1, stable = 0

        /// `seuil` : les relevés identiques qui suivent le premier ; 0 pour
        /// une réponse qu'on sait déjà finie, que le premier relevé montre.
        public init(seuil: Int) { self.seuil = seuil }

        public mutating func juger(_ r: RelaisInstantane.Reponse?) -> Bool {
            guard let r, r.nouvelles > 0 else { stable = 0; return false }
            if r.copierPret { return true }
            let finie = !r.enCours && r.longueur > 0
            stable = finie && r.longueur == precedente ? stable + 1 : 0
            precedente = r.longueur
            return finie && stable >= seuil
        }
    }
}
