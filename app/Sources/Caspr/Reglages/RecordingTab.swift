import SwiftUI

/// Comment on déclenche, ce qu'on entend pendant, et ce qu'on voit.
///
/// Tout ce qui touche à l'acte de dicter, par opposition à l'onglet Général,
/// qui porte ce qui vaut pour l'application entière.
struct RecordingTab: View {
    @State private var prefs = Preferences.shared
    @State private var soundsEnabled = Feedback.soundsEnabled

    var body: some View {
        // La même vue que l'accueil, sans la zone d'essai : on ne découvre pas
        // la dictée depuis les Réglages. Les deux écrans posaient la même
        // question avec deux implémentations, et elles avaient déjà divergé.
        SectionLabel("Déclencheur & Permissions", followsHeader: true)
        TriggerCard(showTrialSandbox: false, showVoieShortcut: true)

        SectionLabel("Aperçu du texte en direct (Live Preview)")
        SettingsToggleRow(
            title: "Afficher les mots prononcés en temps réel",
            description: "Affiche le flux sous la barre flottante pendant la "
                + "parole (moteur macOS).",
            // La note n'apparaît **que** désactivé : rappeler ce qu'on perd
            // quand on ne perd rien serait du bruit.
            note: prefs.livePreviewEnabled ? nil
                : "L'aperçu textuel est masqué. La barre flottante affichera "
                  + "uniquement les ondes sonores pendant la parole.",
            isOn: $prefs.livePreviewEnabled,
            bottomMargin: 0)
        // Pas de carte du moteur ici : l'aperçu tourne sur la version de
        // macOS qui écrit, et celle-ci est dans l'onglet Voie. Une seconde
        // carte identique laisserait croire qu'il y a deux réglages.

        SectionLabel("Retours Sonores")
        Card {
            SettingsToggleRow(
                title: "Sons de début et de fin",
                description: "Émet un bip discret pour confirmer l'ouverture et "
                    + "la fermeture de la barre d'écoute.",
                isOn: $soundsEnabled,
                isCard: false)
                .onChange(of: soundsEnabled) { _, new in Feedback.soundsEnabled = new }
        }

        SectionLabel("Micro")
        MicrophoneModeCard()
    }
}

/// Mode micro de macOS.
///
/// Il n'apparaissait que sur la barre d'enregistrement, ce qui donnait
/// l'impression d'un réglage de Caspr rangé au mauvais endroit. En réalité
/// **aucune application ne peut le changer** : c'est un réglage système,
/// commun à toutes les apps. Le dire ici évite de le chercher.
private struct MicrophoneModeCard: View {
    @State private var mode = AudioRecorder.microphoneModeLabel

    var body: some View {
        Card {
            Row(label: "Mode") {
                Text(mode).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Note("**L'isolement de la voix** retire le bruit autour de vous et "
                 + "améliore nettement la transcription en environnement "
                 + "bruyant.")
            Note("macOS ne laisse aucune application imposer ce mode : il vaut "
                 + "pour toutes à la fois, et c'est vous qui le choisissez.")
            // Pas de bouton ici, et c'est mesuré : `showSystemUserInterface`
            // n'ouvre rien tant qu'aucune capture n'est en cours. macOS ne
            // propose ce choix que pendant qu'une application utilise le
            // micro. Le bouton existait, ne faisait rien depuis les réglages,
            // et laissait croire à une panne.
            Note("Le choix ne s'offre que **pendant** qu'une application "
                 + "utilise le micro. Depuis la barre de Caspr, en pleine "
                 + "dictée, un clic sur le mode l'ouvre ; sinon, il est dans "
                 + "le Centre de contrôle, sous « Micro ».")
        }
        // Il change depuis le Centre de contrôle, sans nous prévenir.
        .onAppear { mode = AudioRecorder.microphoneModeLabel }
    }
}
