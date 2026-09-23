import SwiftUI
import CasprCore

/// La bascule entre les deux voies, et les réglages de celle qui est retenue.
///
/// ## Deux lignes de même rang
///
/// Elle remplace un interrupteur « ChatGPT » qui enveloppait la carte de
/// macOS et décidait de son affichage : ChatGPT y avait l'air d'une option
/// posée sur macOS, alors que c'est la moitié du produit. Deux lignes côte à
/// côte, chacune avec ce qu'elle offre, disent qu'il y a deux chemins et qu'on
/// en prend un.
///
/// Elles s'excluent, et ce n'est pas une préférence de présentation : les deux
/// ne peuvent pas ouvrir le micro en même temps. Une capture par la page
/// ChatGPT laisse celle de Caspr sur du silence — mesuré au niveau crête,
/// 0,072 avant, 0,000 après (cf. RELAIS.md).
///
/// ## Seule la voie retenue se règle
///
/// Sous macOS, la page ChatGPT n'existe pas : des boutons qui la calibrent
/// n'auraient rien à calibrer. Et laisser les réglages de macOS sous une voie
/// qui ne s'en sert pas invite à y cliquer, puis à chercher pourquoi rien ne
/// change.
///
/// **La langue ne se change pas ici.** Elle vaut pour les deux voies et vit
/// dans l'onglet Général : deux endroits pour un seul réglage, ce sont deux
/// endroits à tenir d'accord.
struct CarteVoie: View {
    @State private var prefs = Preferences.shared
    @ObservedObject private var relais = Relais.partage

    var body: some View {
        Card {
            ligne(.apple)
            Divider().opacity(0.25)
            ligne(.chatgpt)
            Note("Vaut pour la dictée suivante : une dictée en cours va au bout "
                 + "sur la voie qu'elle avait. La bascule est aussi dans le menu "
                 + "de la barre, et sur un raccourci à choisir dans l'onglet "
                 + "Dictée.")
        }

        switch prefs.voie {
        case .apple:
            SectionLabel("macOS")
            AppleEngineCard()
        case .chatgpt:
            SectionLabel("ChatGPT")
            RelaisReglages()
        }
    }

    // MARK: - Une voie

    private func ligne(_ voie: VoieDeDictee) -> some View {
        let retenue = prefs.voie == voie
        return Button { choisir(voie) } label: {
            HStack(alignment: .top, spacing: 12) {
                Rond(plein: retenue)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(titre(voie))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 8)
                        if let manque = manque(voie) {
                            Text(manque)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Style.warning)
                        }
                    }
                    Text(.init(promesse(voie)))
                        .font(.system(size: 12))
                        .foregroundStyle(Style.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(titre(voie))
        .accessibilityAddTraits(retenue ? [.isSelected] : [])
    }

    private func titre(_ voie: VoieDeDictee) -> String {
        switch voie {
        case .apple: "macOS"
        case .chatgpt: "ChatGPT"
        }
    }

    /// Ce que la voie offre, et ce qu'elle coûte — ce qu'on compare au moment
    /// de choisir.
    private func promesse(_ voie: VoieDeDictee) -> String {
        switch voie {
        case .apple:
            "**Hors ligne, sans compte.** La voix est transcrite sur ce Mac et "
                + "n'en sort pas ; l'aperçu s'écrit pendant que vous parlez."
        case .chatgpt:
            "**La meilleure transcription, et des modules** qui réorganisent le "
                + "texte ou répondent à une question. La voix passe par votre "
                + "compte ChatGPT, dans une page que Caspr héberge : il faut une "
                + "connexion, et il n'y a pas d'aperçu en direct."
        }
    }

    /// Ce qui manque à une voie pour dicter, dit sur sa ligne : on le voit
    /// avant de la choisir, pas après.
    ///
    /// Pour ChatGPT, la session est la dernière que la page a montrée (cf.
    /// `Relais.sessionVue`) — observée, pour que la ligne change d'avis avec
    /// elle.
    private func manque(_ voie: VoieDeDictee) -> String? {
        switch voie {
        case .apple:
            return AppleEngineCard.isValid ? nil : "à terminer"
        case .chatgpt:
            if relais.sessionVue == .deconnecte { return "déconnecté" }
            return Relais.partage.estCalibre ? nil : "à configurer"
        }
    }

    /// Vaut pour la dictée suivante : une dictée en cours garde la voie
    /// qu'elle avait à l'appui.
    ///
    /// Vers ChatGPT sans calibrage, la calibration part aussitôt : c'est ce que
    /// la voie réclame avant tout, et la page n'existe que sur cette voie
    /// (cf. `Relais.pageActive`) — on ne peut pas calibrer d'abord et choisir
    /// ensuite. Pas pendant une dictée macOS : elle construirait la page sous
    /// le magnétophone. Les réglages disent alors pourquoi leurs boutons
    /// attendent, et « Apprendre les boutons… » se rallume à l'arrêt.
    private func choisir(_ voie: VoieDeDictee) {
        guard voie != prefs.voie else { return }
        prefs.voie = voie
        switch voie {
        case .chatgpt:
            if !Relais.partage.estCalibre, !Relais.partage.ecouteMacOS {
                Relais.partage.calibrerTout()
            }
        case .apple:
            break
        }
    }
}

/// La pastille radio : un cercle bordé, rempli d'un point quand la voie est
/// retenue. Dessinée plutôt qu'empruntée à SF Symbols, dont le
/// `largecircle.fill.circle` n'a pas l'épaisseur des autres contours.
private struct Rond: View {
    let plein: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(plein ? Style.accent : Style.textTertiary, lineWidth: 1.5)
                .frame(width: 18, height: 18)
            if plein {
                Circle().fill(Style.accent).frame(width: 8, height: 8)
            }
        }
        .padding(.top, 1)
    }
}

#Preview("Voie") {
    ScrollView {
        CarteVoie()
            .padding(Style.windowPadding)
    }
    .frame(width: Style.windowWidth, height: Style.windowHeight)
    .background(Color(hex: 0x141821))
}
