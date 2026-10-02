import AppKit
import CasprCore

/// Une dictée, telle qu'elle était quand on a cessé de parler.
///
/// Tout ce qui décide de ce que devient le texte, figé une fois et porté
/// jusqu'à la livraison. Le module et la destination étaient relus à chaque
/// étape — `RelaisCatalogue.courant` relit les préférences à chaque accès —
/// une fois pour choisir la transformation, puis de nouveau pour décider si le
/// texte s'insère et où, avec l'aller-retour ChatGPT entre les deux. Rien ne
/// les faisait diverger en pratique, la pastille n'étant plus cliquable
/// pendant l'attente ; mais c'est un effet de bord de l'affichage qui fermait
/// la faille, et le menu de la barre, lui, change la destination à tout
/// moment.
///
/// **À l'arrêt, et non à l'appui.** Changer de module ou passer aux notes en
/// pleine phrase doit valoir pour la dictée en cours : on change d'avis
/// parce qu'on a déjà commencé à parler. Seules la voie et l'application
/// visée sont plus anciennes — elles sont prises à l'appui, la première parce
/// que c'est elle qui a ouvert le micro, la seconde parce que c'est là qu'on
/// parlait.
struct DicteeEnCours {
    let voie: VoieDeDictee
    /// Le module du relais, `nil` sous macOS : on y écrit ce qu'on a dit.
    let module: RelaisModule?
    let destination: DictationTarget
    /// L'application où l'on parlait, `nil` quand c'était Caspr lui-même — la
    /// zone d'essai de l'accueil.
    let applicationVisee: NSRunningApplication?
    /// Le temps parlé, en secondes : le journal le dit à la fin de l'écoute.
    /// Il ne dimensionne aucune attente de ChatGPT, qui n'a pas de fin (cf.
    /// RELAIS.md, sixième règle).
    let duree: TimeInterval
}
