import AppKit
import SwiftUI
import CasprCore

/// Ce que la version apporte, en puces.
///
/// Partagée par la carte des Réglages et la fenêtre du lancement : c'est la
/// même question posée aux deux endroits, et la laisser à chacun garantissait
/// qu'elles finiraient par ne plus dire la même chose.
///
/// **Vide, elle le dit** plutôt que de laisser un trou. C'est arrivé sur la
/// v0.9.1 : la release avait été publiée sans notes écrites à la main, GitHub
/// n'avait engendré qu'un lien « Full Changelog », et la carte demandait
/// d'installer une version sans pouvoir dire ce qu'elle changeait. Le silence
/// se lisait comme une panne d'affichage — ce qu'il n'était pas. Cf.
/// `RELEASES.md` : la vraie parade est en amont, dans `release-notes/`.
///
/// La hauteur est bornée et le contenu défile. Une release qui rassemble
/// quarante commits produirait autrement une fenêtre plus haute que l'écran, et
/// pousserait les boutons hors de portée — la panne que `NSWindow.caspr`
/// documente par ailleurs.
struct ReleaseNotesList: View {
    let notes: String
    var maxHeight: CGFloat = 120
    /// L'en-tête en capitales. La fenêtre du lancement le porte ; la carte des
    /// Réglages non — son encart annonce déjà « telle version est disponible »
    /// juste au-dessus, et un second titre entre les deux ferait redite.
    var showsHeader = true

    private var lines: [String] { ReleaseNotes.lines(from: notes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                Text("NOUVEAUTÉS DANS CETTE VERSION")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(Style.textTertiary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty {
                        Text("Cette version a été publiée sans notes : "
                             + "impossible de dire ici ce qu'elle change.")
                            .font(.system(size: 11.5))
                            .italic()
                            .foregroundStyle(Style.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(Style.accent)
                            // `.init` pour que le gras et le code en ligne
                            // des notes rédigées à la main soient rendus.
                            Text(.init(line))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Style.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: maxHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 8,
                                              style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)))
        }
    }
}

/// La version installée, et de quoi passer à la suivante.
///
/// Toute la mécanique — interrogation de l'API GitHub, vérification que la
/// nouvelle image porte la **même signature** que la copie en cours, mise en
/// place atomique, levée de la quarantaine, relance — reste dans
/// `UpdateChecker` et `UpdateInstaller`. Ce composant ne fait que la présenter.
///
/// ## Ce qui change se lit ici, pas sur GitHub
///
/// La carte portait un bouton « Voir ce qui change » qui ouvrait le navigateur.
/// C'était l'aveu qu'elle ne savait pas répondre elle-même — alors qu'elle
/// reçoit le corps de la release dans la même requête que le numéro de version.
/// Les notes sont donc dépliées dans l'encart, et le renvoi vers GitHub ne
/// subsiste **que** là où l'installation intégrée est impossible : sans image
/// disque attachée, ou sur une copie que Caspr n'a pas le droit de remplacer.
/// Dans ces deux cas-là le lien n'est pas un aveu, c'est le seul chemin.
///
/// ## La vérification automatique reste désactivée par défaut
///
/// C'est la seule requête réseau que Caspr fasse de lui-même — la voie
/// ChatGPT parle à ChatGPT, mais par le compte de l'utilisateur. Tant qu'elle
/// n'est pas activée, la voie macOS n'a aucune exception à énoncer à « rien ne
/// sort de votre Mac » — et une exception, même bénigne, oblige à la
/// mentionner partout et fait douter du reste. Le bouton « Vérifier maintenant », lui, marche
/// toujours : il est déclenché par quelqu'un qui sait ce qu'il demande.
struct UpdateCard: View {
    @State private var prefs = Preferences.shared
    @State private var checker = UpdateChecker.shared
    @State private var installer = UpdateInstaller.shared

    /// La version proposée, si elle n'a pas été écartée (cf.
    /// `UpdateChecker.proposee`).
    private var available: UpdateChecker.Release? { checker.proposee }

    var body: some View {
        Card {
            header

            if !UpdateChecker.isReleaseBuild {
                Note("Compilé depuis les sources : `\(UpdateChecker.gitDescribe)`. "
                     + "Les vérifications automatiques sont suspendues sur un "
                     + "build de développement, qui est presque toujours en "
                     + "avance sur la dernière release.")
            }

            if let update = available {
                self.available(update)
            } else if let ignored = checker.newer?.version,
                      prefs.ignoredUpdateVersion == ignored {
                ignoredNotice(ignored)
            }

            Divider().opacity(0.25)

            SettingsToggleRow(
                title: "Rechercher automatiquement les mises à jour (1x par jour)",
                description: "Caspr vérifie discrètement sur GitHub si une "
                    + "nouvelle version existe pour vous en informer.",
                note: "🔒 Respect de la vie privée : seule une requête anonyme "
                    + "est envoyée à GitHub pour obtenir le numéro de version. "
                    + "Aucune donnée personnelle ni texte dicté n'est transmis.",
                isOn: $prefs.checksForUpdates,
                isCard: false)
        }
    }

    // MARK: - En-tête

    /// Nom, version, pastille d'état — et la date de la dernière vérification
    /// juste dessous, en permanence.
    ///
    /// Elle n'apparaissait qu'à jour et disparaissait dès qu'une version était
    /// trouvée, exactement quand elle sert : « proposé sur la foi de quelle
    /// vérification, et de quand ? ». Cf. `UpdateCard.jsx`.
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Caspr \(UpdateChecker.buildLabel)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    if available != nil {
                        badge("Mise à jour disponible", color: Self.amber,
                              text: Self.amberText)
                    } else if checker.lastCheckedAt != nil, !checker.checking,
                              checker.lastError == nil {
                        // `lastError == nil` est la condition qui manquait.
                        // `lastCheckedAt` n'est écrite que par une vérification
                        // **aboutie**, et elle est persistée : une requête qui
                        // échoue la laisse donc en place, et la pastille
                        // continuait d'affirmer « à jour » sur la foi d'une
                        // réponse vieille d'un jour. Constaté sur une machine
                        // sans réseau, qui était en réalité deux versions en
                        // retard.
                        //
                        // Rien ne la remplace : la raison de l'échec s'affiche
                        // juste en dessous, et une pastille « vérification
                        // impossible » répéterait en trois mots ce que la phrase
                        // dit déjà mieux.
                        badge("✓ À jour", color: Style.accent, text: Style.accent)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Style.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            checkButton
        }

        if let error = checker.lastError {
            Note(error, warning: true)
        }
    }

    private var subtitle: String {
        let build = UpdateChecker.isReleaseBuild
            ? "Release officielle" : "Build de développement"
        guard let date = checker.lastCheckedAt else {
            return "Jamais vérifié · \(build)"
        }
        return "Dernière vérification : "
            + date.formatted(.relative(presentation: .named)) + " · \(build)"
    }

    /// Le bouton net du prototype : turquoise sur turquoise, avec sa lueur.
    ///
    /// `.bordered` le rendait gris parmi des gris — la seule action de la carte
    /// qui marche toujours, y compris quand la vérification automatique est
    /// coupée, ne se distinguait de rien.
    @ViewBuilder
    private var checkButton: some View {
        Button {
            Task { await checker.check() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text(checker.checking ? "Vérification…" : "Vérifier maintenant")
            }
        }
        .buttonStyle(AccentGhostButtonStyle())
        .disabled(checker.checking || installer.isBusy)
    }

    private func badge(_ label: String, color: Color, text: Color) -> some View {
        Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(color.opacity(0.35), lineWidth: 1)))
    }

    // MARK: - Une version est disponible

    /// Le jaune du prototype — `rgba(234, 179, 8, …)`, et non l'ambre des
    /// avertissements. Une mise à jour n'est pas une alerte : elle appelle
    /// l'œil sans annoncer que quelque chose ne va pas.
    private static let amber = Color(hex: 0xEAB308)
    private static let amberText = Color(hex: 0xFDE047)

    @ViewBuilder
    private func available(_ update: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Caspr v\(update.version) est disponible\(sizeSuffix(update))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Self.amberText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if let date = update.publishedAt {
                    Text("Publiée le \(Self.published.string(from: date))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .fixedSize()
                }
            }

            // Ce que la version apporte, déplié ici : c'est la seule chose qui
            // puisse motiver de remplacer un logiciel qui marche.
            ReleaseNotesList(notes: update.notes, maxHeight: 110,
                             showsHeader: false)

            action(update)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Self.amber.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Self.amber.opacity(0.35), lineWidth: 1)))
    }

    /// Le poids du téléchargement, annoncé avant de le lancer.
    ///
    /// Mesuré depuis toujours — il sert à détecter un transfert tronqué — et
    /// affiché nulle part. En français : `ByteCountFormatter` suit la langue du
    /// **système**, et posait « 24.8 MB » au milieu d'une phrase française.
    private func sizeSuffix(_ update: UpdateChecker.Release) -> String {
        guard let size = update.asset?.size, size > 0 else { return "" }
        return " (\(Self.frenchSize(size)))"
    }

    /// « 25 Mo », « 1,62 Go ».
    private static func frenchSize(_ bytes: Int64) -> String {
        let mo = Double(bytes) / 1_000_000
        if mo < 1000 { return "\(Int(mo.rounded())) Mo" }
        return String(format: "%.2f Go", mo / 1000)
            .replacingOccurrences(of: ".", with: ",")
    }

    /// « 18 août 2026 ». Le format long est explicite, et la locale est forcée
    /// pour la même raison que la taille : l'interface est française sur un Mac
    /// qui ne l'est pas forcément.
    private static let published: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    /// « Ignorer » ne doit pas être une trappe.
    ///
    /// Sans cette ligne, écarter une version la faisait disparaître pour de
    /// bon : la carte affichait « à jour » — un mensonge — et plus rien ne
    /// permettait de revenir dessus sans aller éditer les préférences.
    private func ignoredNotice(_ version: String) -> some View {
        HStack(spacing: 8) {
            Text("La v\(version) a été ignorée : elle ne sera plus proposée.")
                .font(.system(size: 11.5))
                .foregroundStyle(Style.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("La réafficher") { prefs.ignoredUpdateVersion = nil }
                .buttonStyle(.link)
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
    }

    /// Chaque étape est nommée pendant qu'elle dure.
    ///
    /// Une barre muette, sur une opération qui remplace l'application qu'on est
    /// en train d'utiliser, invite surtout à cliquer ailleurs pour voir si elle
    /// répond encore.
    @ViewBuilder
    private func action(_ update: UpdateChecker.Release) -> some View {
        switch installer.phase {
        case .idle:
            ready(update)
        case .downloading(let fraction):
            step("Téléchargement de la v\(update.version)…", fraction: fraction)
        case .verifying:
            step("Vérification de signature & intégrité macOS…")
        case .installing:
            step("Remplacement du bundle…")
        case .relaunching:
            step("Mise à jour posée. Caspr redémarre…")
        case .failed(let message):
            Note(message, warning: true)
            ButtonRow {
                Button("Réessayer") { installer.reset() }
                Button("Ouvrir la page de téléchargement") {
                    NSWorkspace.shared.open(update.page)
                }
            }
        }
    }

    @ViewBuilder
    private func ready(_ update: UpdateChecker.Release) -> some View {
        // L'obstacle est consulté **avant** d'offrir le bouton, jamais après le
        // clic : un dossier non inscriptible ou une copie signée ad hoc ne
        // s'arrangeront pas d'un second essai.
        if let obstacle = UpdateInstaller.obstacle {
            fallback(update, why: obstacle)
        } else if update.asset == nil {
            fallback(update, why: "Cette release n'attache pas d'image disque : "
                     + "l'installation depuis l'application n'est pas possible "
                     + "pour celle-ci.")
        } else {
            HStack(spacing: 8) {
                Button("Mettre à jour vers v\(update.version)") {
                    Task { await installer.install(update) }
                }
                .buttonStyle(CasprPrimaryButtonStyle())

                // Discret, et à côté : c'est la réponse la plus définitive des
                // deux, elle ne doit pas être la plus facile à cliquer.
                Button("Ignorer cette version") {
                    prefs.ignoredUpdateVersion = update.version
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Style.textTertiary)
                .help("Ne plus proposer la v\(update.version). Les suivantes "
                      + "seront proposées normalement.")

                Spacer(minLength: 0)
            }
            Note("Tout se passe ici : le téléchargement, la vérification que la "
                 + "nouvelle version porte bien la même signature que celle-ci, "
                 + "le remplacement et le redémarrage. Vos réglages, votre "
                 + "historique et les autorisations restent en place.")
        }
    }

    /// Le seul cas où GitHub reste offert : l'installation intégrée est
    /// impossible, et la page est le dernier chemin praticable.
    @ViewBuilder
    private func fallback(_ update: UpdateChecker.Release, why: String) -> some View {
        ButtonRow {
            Button("Ouvrir la page de téléchargement") {
                NSWorkspace.shared.open(update.page)
            }
        }
        Note(why, warning: true)
    }

    @ViewBuilder
    private func step(_ label: String, fraction: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.amberText)
                Spacer(minLength: 8)
                if let fraction {
                    Text("\(Int(fraction * 100)) %")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Self.amberText)
                }
            }
            ProgressView(value: fraction ?? 0, total: fraction == nil ? 0 : 1)
                .progressViewStyle(.linear)
                .tint(Style.warning)
        }
    }
}

/// Le bouton « flashy » du prototype : turquoise sur fond turquoise, bordé,
/// avec une lueur qui s'intensifie au survol.
///
/// Distinct de `CasprPrimaryButtonStyle`, qui est plein : celui-ci porte une
/// action *fréquente et sans conséquence* — vérifier — là où le plein porte
/// l'action décisive de l'écran. Deux boutons pleins côte à côte se
/// disputeraient le regard.
private struct AccentGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Style.accent)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Style.accent.opacity(hovering && isEnabled ? 0.22 : 0.12))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Style.accent.opacity(0.4), lineWidth: 1)))
            .shadow(color: isEnabled
                    ? Style.accent.opacity(hovering ? 0.25 : 0.12) : .clear,
                    radius: hovering ? 9 : 7)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("Mises à jour") {
    ScrollView {
        UpdateCard()
            .padding(Style.windowPadding)
    }
    .frame(width: Style.windowWidth, height: 420)
    .background(Color(hex: 0x141821))
}
