import Testing
@testable import CasprCore

@Suite("Notes de version")
struct ReleaseNotesTests {

    /// La forme voulue : `docs/releases/vX.Y.Z.md`, des puces en français.
    @Test("Les puces rédigées à la main sont rendues telles quelles")
    func keepsHandWrittenBullets() {
        let body = """
            - Les notes de version s'affichent enfin dans la fenêtre.
            - Supprimer un modèle ne change plus la version de macOS retenue.
            """
        #expect(ReleaseNotes.lines(from: body) == [
            "Les notes de version s'affichent enfin dans la fenêtre.",
            "Supprimer un modèle ne change plus la version de macOS retenue.",
        ])
    }

    /// Ce que produit `--generate-notes`, c'est-à-dire tout ce qui a été publié
    /// jusqu'ici. Ces releases-là restent affichables.
    @Test("Les notes engendrées par GitHub sont ramenées à leurs phrases")
    func stripsGitHubBoilerplate() {
        let body = """
            ## What's Changed
            * Réorganiser la barre by @mnaji42 in https://github.com/mnaji42/caspr/pull/12
            * Sortir le catalogue des langues du code by @mnaji42 in https://github.com/mnaji42/caspr/pull/13

            **Full Changelog**: https://github.com/mnaji42/caspr/compare/v0.7.11...v0.7.12
            """
        #expect(ReleaseNotes.lines(from: body) == [
            "Réorganiser la barre",
            "Sortir le catalogue des langues du code",
        ])
    }

    @Test("Les titres, les filets et les lignes vides disparaissent")
    func dropsStructure() {
        let body = """
            # Caspr 0.9.0

            ---

            - Un vrai changement
            """
        #expect(ReleaseNotes.lines(from: body) == ["Un vrai changement"])
    }

    @Test("Les listes numérotées perdent leur numéro")
    func stripsNumbering() {
        #expect(ReleaseNotes.lines(from: "1. Premier\n2. Deuxième")
                == ["Premier", "Deuxième"])
    }

    /// La vue pose sa propre puce. Un paragraphe sans puce est une note à part
    /// entière, pas une ligne à jeter.
    @Test("Un paragraphe sans puce compte comme une entrée")
    func keepsPlainParagraphs() {
        #expect(ReleaseNotes.lines(from: "Cette version corrige la dictée.")
                == ["Cette version corrige la dictée."])
    }

    /// Le défaut qui a motivé la reprise : `release-notes/v0.9.0.md` est
    /// justifié à 80 colonnes, comme tout fichier Markdown écrit dans un
    /// éditeur. Découpé ligne à ligne, son premier paragraphe donnait trois
    /// puces coupées au milieu des phrases.
    @Test("Un paragraphe justifié reste une seule entrée")
    func joinsWrappedParagraphs() {
        let body = """
            La dictée passe par macOS ou par ChatGPT. Vos réglages sont repris
            automatiquement au premier lancement — il n'y a rien à refaire.
            """
        #expect(ReleaseNotes.lines(from: body) == [
            "La dictée passe par macOS ou par ChatGPT. Vos réglages sont repris "
                + "automatiquement au premier lancement — il n'y a rien à refaire.",
        ])
    }

    /// Une ligne blanche sépare deux paragraphes, comme en Markdown.
    @Test("La ligne blanche sépare, le retour à la ligne non")
    func blankLineSeparates() {
        #expect(ReleaseNotes.lines(from: "Premier\nparagraphe\n\nSecond")
                == ["Premier paragraphe", "Second"])
    }

    /// Une puce ferme ce qui la précède, sinon la phrase d'introduction
    /// avalerait la première entrée de la liste.
    @Test("Une puce ferme le paragraphe qui la précède")
    func bulletClosesParagraph() {
        let body = """
            Cette version apporte :
            - Le premier changement
            - Le second changement
            """
        #expect(ReleaseNotes.lines(from: body) == [
            "Cette version apporte :",
            "Le premier changement",
            "Le second changement",
        ])
    }

    /// Une puce justifiée sur deux lignes reste une seule entrée.
    @Test("Une puce sur deux lignes reste une entrée")
    func joinsWrappedBullets() {
        let body = """
            - Les langues qu'aucun moteur ne sait transcrire sont annoncées
              comme telles.
            - Recherche par nom français.
            """
        #expect(ReleaseNotes.lines(from: body) == [
            "Les langues qu'aucun moteur ne sait transcrire sont annoncées comme telles.",
            "Recherche par nom français.",
        ])
    }

    /// Le gras et le code en ligne survivent : `Text(.init(_:))` les rend, et
    /// ils portent du sens dans une note de version.
    @Test("Le Markdown en ligne est conservé")
    func keepsInlineMarkdown() {
        #expect(ReleaseNotes.lines(from: "- Le fichier `journal.md` est **préservé**")
                == ["Le fichier `journal.md` est **préservé**"])
    }

    /// « by @quelqu'un » sans URL derrière n'est pas une attribution GitHub :
    /// c'est une phrase, et la couper la mutilerait.
    @Test("Une phrase qui cite quelqu'un n'est pas tronquée")
    func doesNotTruncateProse() {
        let line = "Correctif signalé by @unetierce, merci à elle"
        #expect(ReleaseNotes.lines(from: line) == [line])
    }

    @Test("Une note répétée n'est affichée qu'une fois")
    func deduplicates() {
        #expect(ReleaseNotes.lines(from: "- Même chose\n- Même chose")
                == ["Même chose"])
    }

    @Test("Un corps vide ne produit aucune ligne")
    func handlesEmpty() {
        #expect(ReleaseNotes.lines(from: "").isEmpty)
        #expect(ReleaseNotes.lines(from: "\n\n   \n").isEmpty)
    }

    /// Une release qui ne contient que le pied engendré par GitHub — ça arrive
    /// quand aucun commit n'est rattaché à une pull request — ne doit pas
    /// afficher une section « Nouveautés » vide.
    @Test("Un corps réduit au pied de page ne produit rien")
    func handlesBoilerplateOnly() {
        let body = """
            ## What's Changed

            **Full Changelog**: https://github.com/mnaji42/caspr/compare/v0.8.0...v0.9.0
            """
        #expect(ReleaseNotes.lines(from: body).isEmpty)
    }
}
