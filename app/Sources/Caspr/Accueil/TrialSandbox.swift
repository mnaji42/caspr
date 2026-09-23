import SwiftUI

/// Le champ où l'on essaie la dictée pour la première fois.
///
/// ## Il ne simule rien, et c'est tout le sujet
///
/// Le prototype React propose un bouton `[ 🎙️ Simuler Touche Option ]` qui
/// écrit une phrase toute faite, lettre à lettre. C'est une maquette, et à ce
/// titre c'est légitime — il n'y a pas de micro derrière une page web.
///
/// En natif, ce bouton serait un mensonge, et un mensonge coûteux. Ce qu'on
/// cherche à prouver ici, c'est précisément que **le vrai déclencheur, le vrai
/// micro et le vrai moteur écrivent dans un vrai champ de saisie** — par
/// exactement le même chemin que dans n'importe quelle autre application.
/// Une animation qui imite le résultat ne prouve rien, et si la dictée est
/// cassée elle le cache.
///
/// Le champ ci-dessous n'est donc jamais rempli par le code. Le texte y arrive
/// par `TextInjector`, comme partout ailleurs. S'il n'arrive pas, c'est
/// l'information la plus utile que l'accueil puisse donner.
struct TrialSandbox: View {
    /// Grisé tant que le micro ou l'accessibilité manque : sans eux, appuyer
    /// sur la touche ne produirait rien, et l'essai raté se lirait comme
    /// « Caspr ne marche pas » au lieu de « il manque un droit ».
    var isLocked: Bool
    /// Le déclencheur à annoncer — « ⌥ droite », « ⌃⌥⌘D ».
    var triggerLabel: String

    /// Une dictée est-elle en cours ? Le champ le dit, plutôt que de rester
    /// muet pendant qu'on parle sans savoir si l'appui a été pris.
    var isListening = false

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ZONE D'ESSAI EN DIRECT")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.55)
                    .foregroundStyle(Style.textTertiary)
                Spacer()
                if isLocked {
                    Text("🔒 Accordez les accès ci-dessus pour débloquer")
                        .font(.system(size: 11))
                        .foregroundStyle(Style.warning)
                } else {
                    Text("✨ Prêt pour l'essai")
                        .font(.system(size: 11))
                        .foregroundStyle(Style.accent)
                }
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(isListening
                         ? "Écoute en cours... Parlez maintenant..."
                         : "Cliquez ici puis appuyez sur \(triggerLabel) pour tester...")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Style.textTertiary)
                        // Exactement l'encart du `TextEditor` : un pixel
                        // d'écart et le curseur paraît sauter au premier
                        // caractère tapé.
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }
            .frame(height: 80)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Style.innerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: Style.innerRadius,
                                         style: .continuous)
                            .strokeBorder(Style.cardStroke, lineWidth: 1)))

            if !text.isEmpty {
                Text("Bravo ! Votre voix écrit directement au curseur.")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Style.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(isLocked ? 0.38 : 1)
        .disabled(isLocked)
        .animation(.easeOut(duration: 0.25), value: isLocked)
    }
}

#Preview("Essai — déverrouillé") {
    TrialSandbox(isLocked: false, triggerLabel: "⌥ droite")
        .padding(Style.windowPadding)
        .frame(width: Style.windowWidth)
        .background(Color(hex: 0x141821))
}

#Preview("Essai — verrouillé") {
    TrialSandbox(isLocked: true, triggerLabel: "⌥ droite")
        .padding(Style.windowPadding)
        .frame(width: Style.windowWidth)
        .background(Color(hex: 0x141821))
}
