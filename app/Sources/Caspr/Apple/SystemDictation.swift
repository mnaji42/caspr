import AppKit
import Foundation

/// La Dictée de macOS est-elle activée dans les Réglages Système ?
///
/// ## Pourquoi la question se pose
///
/// `SFSpeechRecognizer` — le moteur derrière la version « Dictée » — ne dispose
/// de ses modèles hors ligne que si la Dictée du système a été activée au moins
/// une fois : c'est **elle** qui les installe, pas nous. Sur un Mac neuf où
/// personne n'y a touché, le recogniseur se déclare pourtant disponible et
/// accepte de démarrer une tâche. Elle ne rend rien.
///
/// Mesuré sur une machine virtuelle en macOS 26 sans Apple Intelligence :
/// micro, accessibilité et reconnaissance vocale tous accordés, aperçu en
/// direct muet, puis « Transcription impossible » à l'insertion. Une fois la
/// Dictée activée dans Réglages Système › Clavier › Dictée, tout fonctionne.
/// Rien dans l'application ne pouvait le dire, et rien ne le suggérait : les
/// trois pastilles étaient vertes.
///
/// ## Ce n'est pas une autorisation
///
/// Le micro et la reconnaissance vocale se demandent par un dialogue : macOS
/// pose la question pour nous. Celle-ci, non — c'est un interrupteur des
/// Réglages Système, et aucune API ne permet ni de le lire officiellement ni de
/// le basculer. Le plus proche du chemin de l'accessibilité qu'on puisse faire,
/// c'est : le constater, l'expliquer, ouvrir le bon volet, et le voir changer
/// tout seul. C'est ce que fait `PermissionsMonitor`.
///
/// ## Comment on le constate
///
/// En lisant la préférence que les Réglages Système écrivent, `Dictation
/// Enabled` dans le domaine `com.apple.assistant.support`. Caspr n'est pas dans
/// un bac à sable (cf. `Caspr.entitlements`), donc `CFPreferencesCopyAppValue`
/// y accède.
///
/// C'est une clé non documentée, et elle est traitée comme telle : **le doute
/// profite à l'utilisateur**. `isEnabled` rend `nil` — et non `false` — quand
/// la clé est absente ou illisible, et rien ne bloque dans ce cas. Une clé
/// renommée dans un macOS futur fera au pire disparaître un avertissement
/// utile ; elle n'interdira jamais de dicter à quelqu'un dont la Dictée
/// marche.
enum SystemDictation {
    private static let domain = "com.apple.assistant.support" as CFString

    /// L'interrupteur maître, ou `nil` si on ne sait pas.
    static var isEnabled: Bool? {
        // Sans synchronisation, la valeur reste celle lue au premier accès :
        // l'interrupteur basculerait dans les Réglages Système sans que Caspr
        // le voie jamais, ce qui vide de son sens la relecture d'une fois par
        // seconde.
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("Dictation Enabled" as CFString,
                                         domain) as? Bool
    }

    /// Vrai **seulement** quand on a lu l'interrupteur et qu'il est éteint.
    ///
    /// C'est la forme à utiliser partout : elle rend le doute inoffensif.
    static var isDisabled: Bool { isEnabled == false }

    /// Le volet où l'activer, en un clic plutôt qu'en quatre.
    ///
    /// L'ancre `Dictation` est ignorée par les versions de macOS qui ne la
    /// connaissent pas — le volet Clavier s'ouvre alors sans faire défiler, ce
    /// qui reste très au-dessus de « cherchez dans les Réglages ».
    static func openSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation")!)
    }

    /// Ce qu'il faut faire, en une phrase, là où il n'y a pas la place d'une
    /// carte entière — messages d'erreur, notes de repli.
    static let instruction =
        "La Dictée de macOS est désactivée sur ce Mac. Activez-la dans "
        + "Réglages Système › Clavier › Dictée : c'est elle qui installe les "
        + "modèles de reconnaissance dont Caspr se sert, et rien ne peut être "
        + "transcrit tant qu'elle est éteinte."
}
