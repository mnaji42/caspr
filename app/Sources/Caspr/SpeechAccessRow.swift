import SwiftUI

/// L'autorisation de reconnaissance vocale d'Apple, demandée là où elle sert.
///
/// ## Pourquoi elle ne vit pas avec les deux autres
///
/// Le micro et l'accessibilité sont inconditionnels : sans eux, Caspr ne peut
/// ni entendre ni écrire, quel que soit le moteur. Ils appartiennent donc au
/// déclencheur (`TriggerCard`).
///
/// Celle-ci non. Elle ne concerne que `SFSpeechRecognizer`, c'est-à-dire la
/// version **Dictée** du moteur de macOS. Quelqu'un qui dicte avec Apple
/// Intelligence, ou par ChatGPT, n'en a aucun usage — et la lui
/// réclamer serait exactement ce qu'on reproche aux applications qui demandent
/// plus de droits qu'elles n'en emploient.
///
/// Elle apparaît donc **à côté du moteur qui la consomme**, et seulement quand
/// ce moteur est réellement en jeu. `PermissionsMonitor.requiresSpeech` en juge
/// sur trois usages possibles : la Dictée écrit, elle tourne pour la collecte,
/// ou c'est elle qui assure l'aperçu en direct.
struct SpeechAccessRow: View {
    /// Explique à quoi sert le droit. Vrai à l'accueil ; faux dans les
    /// Réglages, où l'on vient réparer, pas lire un exposé.
    var explains = false

    @State private var monitor = PermissionsMonitor.shared

    var body: some View {
        Group {
            if monitor.speechGranted {
                GrantedLine("Reconnaissance Vocale Apple accordée")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        // Ambre quand le droit a été refusé ou retiré, gris
                        // quand il n'a simplement jamais été demandé : « il
                        // reste une étape » et « quelque chose a été coupé » ne
                        // se lisent pas pareil. Même code couleur que la ligne
                        // de la Dictée juste au-dessus.
                        Circle()
                            .strokeBorder(monitor.speechAccess == .denied
                                          ? Style.warning : Style.textTertiary,
                                          lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reconnaissance Vocale Apple (Requis)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Exigée par macOS pour permettre à Apple "
                                 + "Dictée de traiter le signal vocal.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Style.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        // Deux boutons pour deux impasses différentes, et
                        // jamais celui qui n'ouvrirait rien.
                        if monitor.speechAccess == .undetermined {
                            Button("Accorder") {
                                // Le moniteur porte la demande, comme pour le
                                // micro : c'est lui qui sait reprendre le
                                // premier plan une fois l'alerte refermée.
                                Task { await monitor.requestSpeechRecognition() }
                            }
                            .buttonStyle(CasprPrimaryButtonStyle())
                        } else {
                            Button("Ouvrir les Réglages") {
                                Permissions.openSpeechRecognitionSettings()
                            }
                            .buttonStyle(CasprPrimaryButtonStyle())
                        }
                    }

                    // Refusé ou révoqué : dire pourquoi le dialogue ne
                    // reviendra pas. Sans cette phrase, quelqu'un qui vient de
                    // décocher la case dans les Réglages Système cherche le
                    // bouton qui la recocherait, et il n'existe pas.
                    if monitor.speechAccess == .denied {
                        Note("macOS ne représente plus son dialogue une fois le "
                             + "refus enregistré : il faut réactiver Caspr à la "
                             + "main dans Réglages Système › Confidentialité et "
                             + "sécurité › Reconnaissance vocale. Caspr le voit "
                             + "aussitôt et reprend la main.", warning: true)
                    }

                    if explains {
                        Note("Le moteur de la **Dictée** de macOS passe par ce "
                             + "droit — macOS le compte séparément du micro. "
                             + "**Rien ne part chez Apple** : Caspr force la "
                             + "reconnaissance hors ligne et refuse de "
                             + "transcrire si la machine ne sait pas le faire.")
                    }

                }
            }
        }
        .onAppear { monitor.observe() }
        .onDisappear { monitor.release() }
    }
}

#Preview("Reconnaissance vocale") {
    VStack(alignment: .leading, spacing: 16) {
        Card {
            SpeechAccessRow(explains: true)
        }
    }
    .padding(Style.windowPadding)
    .frame(width: Style.windowWidth)
    .background(Color(hex: 0x141821))
}

/// L'interrupteur de la Dictée de macOS, quand il est éteint.
///
/// ## Pourquoi ce n'est pas un `SpeechAccessRow` de plus
///
/// Les deux se ressemblent et ne sont pas de même nature. La reconnaissance
/// vocale est une autorisation : Caspr la demande, macOS pose la question, on
/// répond, c'est fini en un clic sans quitter l'application. Celle-ci est un
/// réglage du système, que rien ne permet ni de lire officiellement ni de
/// basculer — le mieux qu'on puisse faire est d'ouvrir le bon volet et de
/// constater le changement.
///
/// Le chemin est donc celui de l'accessibilité, pas celui du micro : un bouton
/// qui emmène dans les Réglages Système, et `PermissionsMonitor` qui repère la
/// bascule dans la seconde et remet Caspr devant.
///
/// **Invisible tant qu'il n'y a rien à réparer.** Pas de ligne « ✓ Dictée
/// activée » sur les Mac où elle l'est : ce serait une quatrième pastille verte
/// pour un réglage que l'utilisateur n'a pas eu à accorder, et la carte en
/// porte déjà assez.
struct SystemDictationRow: View {
    @State private var monitor = PermissionsMonitor.shared

    var body: some View {
        Group {
            if monitor.dictationDisabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .strokeBorder(Style.warning, lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dictée de macOS (à activer)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Éteinte dans les Réglages Système. C'est elle "
                                 + "qui installe les modèles de reconnaissance : "
                                 + "tant qu'elle l'est, ce moteur n'écrit rien.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Style.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Ouvrir les Réglages") {
                            SystemDictation.openSettings()
                        }
                        .buttonStyle(CasprPrimaryButtonStyle())
                    }

                    Note("Réglages Système › Clavier › Dictée. Aucune "
                         + "application ne peut basculer cet interrupteur "
                         + "elle-même — Caspr reste ouvert pendant ce temps et "
                         + "se met à jour tout seul dès que c'est fait. **Rien "
                         + "ne part chez Apple pour autant** : Caspr force la "
                         + "reconnaissance hors ligne et refuse de transcrire "
                         + "si la machine ne sait pas le faire.")
                }
            }
        }
        // Pas de `.onAppear { monitor.observe() }` ici, contrairement à
        // `SpeechAccessRow` : ce composant ne rend **rien** quand tout va bien,
        // et un `.onAppear` posé sur un `Group` vide n'est jamais appelé —
        // SwiftUI n'instancie pas `EmptyView`. L'horloge est donc tenue par la
        // carte qui l'affiche, cf. `AppleEngineCard.body`.
    }
}
