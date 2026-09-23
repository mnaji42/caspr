import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Où le texte dicté atterrit : au curseur, ou dans un fichier.
///
/// ## Pourquoi la zone de fichier reste toujours visible
///
/// Elle n'apparaissait qu'une fois « notes » choisi, ce qui produisait une
/// impasse : l'option est inutilisable sans fichier, et le champ qui permet
/// d'en désigner un n'apparaissait qu'après l'avoir choisie. On cliquait sur
/// une option qui ne faisait rien.
///
/// La zone est donc là dans les deux modes, et c'est elle qui **débloque**
/// l'option : la pastille « Fichier de notes » reste grisée tant qu'aucun
/// fichier n'est désigné, et s'active d'elle-même dès qu'on en dépose un.
///
/// ## Ce qui n'est pas ici
///
/// Le doc 02 §6 place le démarrage automatique dans cette carte ; le doc 01
/// §2.bis en fait une section distincte. C'est le second qui a raison :
/// « lancer Caspr à l'ouverture de session » ne dit rien de la destination du
/// texte, et les ranger ensemble ferait chercher l'un sous l'autre.
struct DestinationCard: View, ValidatingComponent {
    @State private var prefs = Preferences.shared
    @State private var isDropTarget = false
    @State private var rejected: String?
    @State private var showsDiagnostics = false

    /// Les formats dans lesquels on peut ajouter du texte sans rien casser.
    ///
    /// Un `.docx` ou un `.pages` sont des archives : y ajouter une ligne de
    /// texte brut les corrompt. La liste est donc restrictive à dessein.
    private static let acceptedExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "org", "rst", "text", "",
    ]

    static func validate() -> ComponentValidationError? {
        let prefs = Preferences.shared
        guard prefs.destination == .notes else { return nil }
        return prefs.noteFile == nil ? .notesFileMissing : nil
    }

    private var hasFile: Bool { prefs.noteFile != nil }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mode d'insertion par défaut")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Se bascule aussi depuis la barre flottante, même en "
                         + "pleine phrase.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                destinationPicker
            }

            fileZone

            if let rejected {
                Note(rejected, warning: true)
            }

            Note(destinationNote)

            diagnostics
        }
    }

    /// Ce que devient la dictée, selon le mode et ce qui est configuré.
    ///
    /// Trois variantes, et non deux : « au curseur » ne dit pas la même chose
    /// selon qu'un fichier attend à côté ou non. Quand il y en a un, le
    /// rappeler évite de croire qu'on l'a perdu en revenant au curseur.
    ///
    /// La phrase du prototype annonce un ajout « avec horodatage ».
    /// `TargetWriter.append` n'horodate pas, et je ne l'ai pas ajouté de
    /// moi-même : ce fichier appartient à l'utilisateur — le désinstalleur le
    /// dit en toutes lettres — et y glisser des lignes qu'il n'a pas demandées
    /// serait décider à sa place de ce que contient son journal. La clause est
    /// donc retirée du texte plutôt que promise en l'air.
    private var destinationNote: String {
        guard let name = prefs.noteFile?.lastPathComponent else {
            return "Insère le texte directement là où clignote votre curseur "
                + "dans l'application active."
        }
        return prefs.destination == .notes
            ? "Chaque transcription est automatiquement ajoutée à la fin de "
                + "`\(name)`, sans toucher à votre fenêtre active."
            : "Insère le texte directement là où clignote votre curseur. Le "
                + "fichier `\(name)` reste prêt si vous souhaitez y rediriger "
                + "vos notes."
    }

    /// Ce que Caspr perçoit du document au premier plan.
    ///
    /// La barre flottante sait basculer sur « notes » sans fichier mémorisé :
    /// elle tente alors de reconnaître le document ouvert devant, pour éviter
    /// un sélecteur en pleine dictée. Quand cette reconnaissance échoue, il n'y
    /// a aucun moyen de savoir pourquoi — d'où ce rapport, qui vivait dans le
    /// menu de la barre et n'y avait plus sa place.
    ///
    /// Replié : c'est un outil de dépannage, et il ne concerne personne tant
    /// que rien ne cloche.
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toute la ligne, pas le seul chevron : un `DisclosureGroup` ne
            // réagit qu'à son triangle sous macOS, et viser le libellé sans
            // effet fait conclure que le bouton est cassé.
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showsDiagnostics.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Un fichier ouvert n'est pas détecté ?")
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showsDiagnostics ? 90 : 0))
                }
                .foregroundStyle(Style.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverHighlightButtonStyle())

            if showsDiagnostics {
                Note("Caspr tente de reconnaître le document au premier plan "
                     + "par l'accessibilité. Ce rapport dit ce qu'il voit — "
                     + "utile seulement si un fichier ouvert devant vous n'est "
                     + "pas détecté.")
                ButtonRow {
                    Button("Afficher le rapport") {
                        // Capturé **avant** d'activer Caspr : activer
                        // changerait l'application au premier plan, donc ce
                        // qu'on observe.
                        let report = TargetWriter.diagnostics()
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "Détection du fichier"
                        alert.informativeText = report
                        alert.addButton(withTitle: "Copier")
                        alert.addButton(withTitle: "Fermer")
                        if alert.runModal() == .alertFirstButtonReturn {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Le sélecteur

    /// « Fichier de notes » reste inerte sans fichier : c'est un réglage qu'on
    /// ne peut pas tenir, et le proposer quand même mènerait à une dictée
    /// écrite nulle part.
    private var destinationPicker: some View {
        HStack(spacing: 2) {
            segment(.caret, "Au curseur", enabled: true)
            segment(.notes, "Fichier de notes", enabled: hasFile)
        }
        .padding(4)
        .frame(height: 32)
        .background(
            Capsule().fill(Color.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.06),
                                                lineWidth: 1)))
    }

    private func segment(_ value: Preferences.Destination, _ label: String,
                         enabled: Bool) -> some View {
        let active = prefs.destination == value
        return Text(label)
            .font(.system(size: 12, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Style.accent : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? Style.accent.opacity(0.20) : .clear))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { prefs.destination = value } }
            .help(enabled
                  ? "Écrire dans le fichier de notes configuré"
                  : "Configurez d'abord un fichier de notes ci-dessous pour "
                    + "activer ce mode")
    }

    // MARK: - Le fichier

    @ViewBuilder
    private var fileZone: some View {
        if let file = prefs.noteFile {
            configured(file)
        } else {
            dropZone
        }
    }

    private func configured(_ file: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 15))
                .foregroundStyle(Style.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.04)))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                Text(file.deletingLastPathComponent().path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            ButtonRow {
                Button("Afficher") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
                Button("Modifier…") { choose() }
                    .help("Choisir un autre fichier")
                Button("✕ Retirer") {
                    prefs.noteFile = nil
                    // Sans fichier, « notes » n'est plus tenable : y rester
                    // ferait écrire la prochaine dictée nulle part.
                    prefs.destination = .caret
                    rejected = nil
                }
                .help("Retirer ce fichier")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Style.fieldRadius, style: .continuous)
                .fill(Style.innerBoxFill)
                .overlay(RoundedRectangle(cornerRadius: Style.fieldRadius,
                                          style: .continuous)
                    .strokeBorder(Style.cardStroke, lineWidth: 1)))
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: accept)
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.04)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Aucun fichier de notes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Glissez un fichier texte ici — .txt, .md, .log")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("+ Choisir un fichier…") { choose() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Style.fieldRadius, style: .continuous)
                .fill(isDropTarget ? Style.accent.opacity(0.08)
                                   : Color.black.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: Style.fieldRadius,
                                     style: .continuous)
                        .strokeBorder(isDropTarget ? Style.accent
                                                   : Color.white.opacity(0.14),
                                      style: StrokeStyle(lineWidth: 1.5,
                                                         dash: [4, 3]))))
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: accept)
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
    }

    // MARK: - Désignation

    private func choose() {
        guard let picked = TargetWriter.chooseFile() else { return }
        adopt(picked)
    }

    /// Reçoit un fichier déposé.
    ///
    /// Le chargement est asynchrone, donc le retour de cette fonction ne dit
    /// que « je prends la main », pas « c'est accepté » : la validation a lieu
    /// dans `adopt`, une fois l'URL réellement là.
    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in adopt(url) }
        }
        return true
    }

    /// Retient le fichier, ou dit pourquoi il ne convient pas.
    ///
    /// Deux refus possibles, et chacun mérite sa phrase : un format qu'on
    /// corromprait en y ajoutant du texte, et un fichier qu'on n'a pas le droit
    /// d'écrire. Les confondre en « fichier invalide » enverrait chercher au
    /// mauvais endroit.
    private func adopt(_ url: URL) {
        let extensionName = url.pathExtension.lowercased()
        guard Self.acceptedExtensions.contains(extensionName) else {
            rejected = "**\(url.lastPathComponent)** n'est pas un fichier "
                + "texte. Un document .docx, .pages ou .rtf est une archive : "
                + "y ajouter une ligne de texte brut le corromprait. "
                + "Choisissez un .txt, .md ou .log."
            return
        }
        // Un dossier passe le test d'extension — il n'en a pas — et se ferait
        // retenir comme destination.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path,
                                                    isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            rejected = "**\(url.lastPathComponent)** est un dossier. Désignez "
                + "le fichier dans lequel écrire."
            return
        }
        // Vérifié maintenant plutôt qu'à la première dictée : découvrir qu'un
        // fichier est en lecture seule au moment où l'on vient de parler trois
        // minutes est le pire instant possible.
        if exists, !FileManager.default.isWritableFile(atPath: url.path) {
            rejected = "**\(url.lastPathComponent)** est en lecture seule. "
                + "Caspr ne pourrait rien y ajouter."
            return
        }
        rejected = nil
        prefs.noteFile = url
        // Désigner un fichier, c'est vouloir y écrire : l'option s'active
        // d'elle-même plutôt que d'attendre un second clic sur une pastille
        // qui vient tout juste de cesser d'être grise.
        prefs.destination = .notes
    }
}

#Preview("Destination") {
    ScrollView {
        DestinationCard()
            .padding(Style.windowPadding)
    }
    .frame(width: Style.windowWidth, height: 420)
    .background(Color(hex: 0x141821))
}
