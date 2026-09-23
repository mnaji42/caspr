import AppKit
import SwiftUI

/// Ce qui vaut pour toute l'application, par opposition à l'onglet Dictée,
/// qui porte l'acte de dicter.
struct GeneralTab: View {
    var body: some View {
        // La langue d'abord : c'est elle qui décide de ce que les moteurs
        // peuvent faire, et elle vaut pour toute l'application.
        SectionLabel("Langue Principale de Dictée", followsHeader: true)
        PrimaryLanguageSelector()

        SectionLabel("Destination des Dictées")
        DestinationCard()

        SectionLabel("Mises à jour du Logiciel")
        UpdateCard()

        SectionLabel("Démarrage & Système")
        LoginItemCard()
    }
}

/// Démarrage à l'ouverture de session.
///
/// L'état est relu à chaque affichage plutôt que mémorisé : ce réglage existe
/// aussi dans Réglages Système › Général › Ouverture, et l'utilisateur peut
/// l'y couper sans nous prévenir. Un interrupteur qui afficherait l'inverse de
/// la réalité serait pire que pas d'interrupteur du tout.
private struct LoginItemCard: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var refused = false

    var body: some View {
        Card {
            SettingsToggleRow(
                title: "Lancer Caspr à l'ouverture de session",
                description: "Disponible dans la barre de menus dès le "
                    + "démarrage de votre Mac.",
                isOn: $enabled, isCard: false)
                .onChange(of: enabled) { _, wanted in
                    let actual = LoginItem.set(wanted)
                    refused = actual != wanted
                    // Recaler l'interrupteur sur ce que le système a vraiment
                    // fait, pas sur ce qu'on lui a demandé.
                    if actual != enabled { enabled = actual }
                }

            if refused, LoginItem.requiresApproval {
                Note("macOS a gardé le refus enregistré dans Réglages Système "
                     + "› Général › Ouverture : c'est là qu'il faut "
                     + "réautoriser Caspr.", warning: true)
                Button("Ouvrir Réglages Système › Ouverture") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            } else {
                Note("Caspr vit dans la barre de menus : s'il ne tourne pas, "
                     + "la touche de dictée ne fait rien, et rien n'indique "
                     + "que c'est la raison.")
            }
        }
        .onAppear { enabled = LoginItem.isEnabled }
    }
}
