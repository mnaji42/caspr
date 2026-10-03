#!/usr/bin/env python3
"""Fabrique en.html à partir de index.html.

Une seule source : la page française. Toute chaîne visible non traduite ici
ressort dans le contrôle final, ce qui empêche les deux pages de diverger.
"""
import pathlib, re, sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
src = (ROOT / "index.html").read_text(encoding="utf-8")

PAIRS = [
# ---- tête ------------------------------------------------------------------
('<html lang="fr">', '<html lang="en">'),
('<meta name="viewport" content="width=device-width, initial-scale=1">',
 '<meta name="viewport" content="width=device-width, initial-scale=1">\n<base href="/">'),
("<title>Caspr — dictée vocale pour macOS, hors ligne ou par ChatGPT</title>",
 "<title>Caspr — dictation for macOS, offline or through ChatGPT</title>"),
("Caspr écrit votre voix là où se trouve votre curseur. Deux voies : macOS, hors ligne et sans compte, ou ChatGPT, par votre propre compte. Gratuit, open source, sans serveur.",
 "Caspr writes your voice wherever your caret is. Two paths: macOS, offline and with no account, or ChatGPT, through your own account. Free, open source, no server."),
('<link rel="canonical" href="https://caspr.lyriastudio.fr/">',
 '<link rel="canonical" href="https://caspr.lyriastudio.fr/en">'),
('<meta property="og:locale" content="fr_FR">', '<meta property="og:locale" content="en_US">'),
('<meta property="og:locale:alternate" content="en_US">', '<meta property="og:locale:alternate" content="fr_FR">'),
('<meta property="og:url" content="https://caspr.lyriastudio.fr/">',
 '<meta property="og:url" content="https://caspr.lyriastudio.fr/en">'),
("Caspr — dictée vocale pour macOS, hors ligne ou par ChatGPT", "Caspr — dictation for macOS, offline or through ChatGPT"),
("Parlez, Caspr écrit à votre curseur. Avec macOS, rien ne quitte votre Mac ; avec ChatGPT, votre voix passe par votre propre compte. Caspr n'a aucun serveur.",
 "Speak, and Caspr writes at your caret. With macOS nothing leaves your Mac; with ChatGPT your voice goes through your own account. Caspr has no server."),
("Parlez, Caspr écrit à votre curseur — avec macOS hors ligne, ou avec ChatGPT par votre compte.",
 "Speak, and Caspr writes at your caret — offline with macOS, or with ChatGPT through your account."),
("Caspr — dictée vocale pour macOS", "Caspr — dictation for macOS"),
("https://caspr.lyriastudio.fr/images/og-preview.png", "https://caspr.lyriastudio.fr/images/og-preview-en.png"),
('"inLanguage": "fr-FR"', '"inLanguage": "en"'),
('"@id": "https://caspr.lyriastudio.fr/#site"', '"@id": "https://caspr.lyriastudio.fr/#site-en"'),
('"@id": "https://caspr.lyriastudio.fr/#faq"', '"@id": "https://caspr.lyriastudio.fr/en#faq"'),
('"url": "https://caspr.lyriastudio.fr/",\n      "name": "Caspr"',
 '"url": "https://caspr.lyriastudio.fr/en",\n      "name": "Caspr"'),
('"operatingSystem": "macOS 14 ou plus récent"', '"operatingSystem": "macOS 14 or later"'),
('"processorRequirements": "Puce Apple (arm64)"', '"processorRequirements": "Apple silicon (arm64)"'),
('"applicationSubCategory": "Dictée vocale"', '"applicationSubCategory": "Dictation"'),
("Application de dictée vocale pour macOS, dans la barre des menus. Deux voies : la reconnaissance vocale de macOS, hors ligne et sans compte, ou ChatGPT, par le compte de l'utilisateur dans une page web embarquée. L'application n'a aucun serveur.",
 "Menu-bar dictation app for macOS. Two paths: macOS speech recognition, offline and with no account, or ChatGPT, through the user's own account in an embedded web page. The app has no server."),
("Dictée hors ligne avec la reconnaissance vocale de macOS", "Offline dictation with macOS speech recognition"),
("Dictée par ChatGPT, avec votre propre compte", "Dictation through ChatGPT, with your own account"),
("Modules ChatGPT : texte brut, réorganisation, question", "ChatGPT modules: raw text, reorganise, ask a question"),
("Insertion du texte au curseur de l'application active", "Text inserted at the caret of the active app"),
("Accumulation des dictées dans un fichier Markdown daté", "Dictations appended to a dated Markdown file"),
("Passage d'une voie à l'autre depuis le menu ou un raccourci", "Switch between paths from the menu or a shortcut"),
('"name": "De quel Mac ai-je besoin ?"', '"name": "Which Mac do I need?"'),
("Caspr demande macOS 14 ou plus récent, sur un Mac à puce Apple. Par la voie macOS, il prend Apple Intelligence à partir de macOS 26 quand la machine sait écrire votre langue, et la Dictée du système sinon. Par la voie ChatGPT, il faut un compte ChatGPT et une connexion à Internet.",
 "Caspr needs macOS 14 or later, on an Apple silicon Mac. On the macOS path it uses Apple Intelligence from macOS 26 when the machine can write your language, and system Dictation otherwise. The ChatGPT path needs a ChatGPT account and an internet connection."),
('"name": "Ma voix ou mes textes partent-ils sur un serveur ?"', '"name": "Does my voice or text leave my machine?"'),
("Cela dépend de la voie que vous choisissez. Avec macOS, non : la transcription s'exécute sur votre machine et rien n'est envoyé. Avec ChatGPT, oui : votre voix passe par votre propre compte ChatGPT, chez OpenAI, comme sur chatgpt.com. Caspr, lui, n'a ni serveur, ni compte, ni télémétrie ; sa seule requête à lui est la vérification des mises à jour sur GitHub, et l'automatique est désactivée par défaut.",
 "It depends on the path you choose. With macOS, no: transcription runs on your machine and nothing is sent. With ChatGPT, yes: your voice goes through your own ChatGPT account, to OpenAI, just as on chatgpt.com. Caspr itself has no server, no account and no telemetry; its only request of its own is the update check against GitHub, and the automatic one is off by default."),
('"name": "Pourquoi macOS refuse-t-il d\'ouvrir l\'application la première fois ?"',
 '"name": "Why does macOS refuse to open the app the first time?"'),
("Parce que l'application n'est pas notariée par Apple, ce qui suppose un compte développeur payant. Caspr est signé de façon ad hoc. macOS affiche donc un avertissement au premier lancement, et l'autorisation se donne une fois dans Réglages Système, rubrique Confidentialité et sécurité. Le guide d'installation détaille chaque étape.",
 "Because the app is not notarised by Apple, which requires a paid developer account. Caspr is ad-hoc signed, so macOS warns on first launch. You grant permission once in System Settings, under Privacy & Security. The install guide walks through every step."),
('"name": "Qu\'apporte la voie ChatGPT ?"', '"name": "What does the ChatGPT path add?"'),
("Une transcription souvent meilleure, et des modules : le texte brut, une réorganisation de ce que vous avez dit, ou une question à laquelle ChatGPT répond dans sa page. Caspr pilote l'interface web de ChatGPT, pas une API : si OpenAI la remanie, la voie peut cesser de fonctionner jusqu'à une nouvelle calibration, que Caspr mène seul.",
 "Often better transcription, and modules: the raw text, a reorganised version of what you said, or a question ChatGPT answers in its page. Caspr drives ChatGPT's web interface, not an API: if OpenAI redesigns it, the path can stop working until a new calibration, which Caspr runs on its own."),
('"name": "Quelle est la licence de Caspr ?"', '"name": "What is the licence?"'),
("Le code de Caspr est sous licence MIT, public sur GitHub. La voie ChatGPT utilise votre propre compte, selon les conditions d'OpenAI ; Caspr n'est pas affilié à OpenAI.",
 "Caspr's code is MIT licensed, public on GitHub. The ChatGPT path uses your own account, under OpenAI's terms; Caspr is not affiliated with OpenAI."),
('"name": "Puis-je désinstaller proprement ?"', '"name": "Can I uninstall cleanly?"'),
("Oui. L'application inclut un désinstallateur qui met à la corbeille les préférences, l'historique, la session ChatGPT s'il y en a une, les journaux et les autorisations. Il ne propose que ce qui est effectivement présent.",
 "Yes. The app ships an uninstaller that moves the preferences, the history, the ChatGPT session if there is one, the logs and the permissions to the Trash. It only offers what is actually there."),
# ---- chrome ----------------------------------------------------------------
("Passer au contenu", "Skip to content"),
('href="/" aria-label="Caspr, retour à l\'accueil"', 'href="/en" aria-label="Caspr, back to home"'),
('aria-label="Sections du site"', 'aria-label="Site sections"'),
('href="#voies">Deux voies</a>', 'href="#paths">Two paths</a>'),
('href="#dictee">La dictée</a>', 'href="#dictation">Dictation</a>'),
('href="#barre">La barre</a>', 'href="#bar">The bar</a>'),
('href="#notes">Les notes</a>', 'href="#notes">Notes</a>'),
('href="#local">Confidentialité</a>', 'href="#local">Privacy</a>'),
('<a href="/" aria-current="true" lang="fr">FR</a>\n        <a href="/en" hreflang="en" lang="en">EN</a>',
 '<a href="/" hreflang="fr" lang="fr">FR</a>\n        <a href="/en" aria-current="true" lang="en">EN</a>'),
("Voir Caspr sur ", "View Caspr on "),
(">\n        Télécharger\n      </button>", ">\n        Download\n      </button>"),
# ---- hero ------------------------------------------------------------------
("Parlez naturellement.\n          <span class=\"hero-sub\">Caspr écrit",
 "Speak naturally.\n          <span class=\"hero-sub\">Caspr writes"),
(">à la vitesse de votre pensée</span>", ">at the speed of your thoughts</span>"),
("""          Une dictée pour macOS, dans la barre des menus : vous parlez, le texte
          s'écrit à votre curseur ou dans vos notes. Deux voies au choix — macOS,
          hors ligne et sans compte, ou ChatGPT, par votre propre compte.
          Gratuite, open source, et sans serveur.""",
 """          A menu-bar dictation app for macOS: you speak, and the text is written
          at your caret or into your notes. Two paths to choose from — macOS,
          offline and with no account, or ChatGPT, through your own account.
          Free, open source, and with no server."""),
("Télécharger pour macOS", "Download for macOS"),
("Lire le code source", "Read the source"),
("Gratuit, sous licence MIT, sur GitHub.", "Free, MIT licensed, on GitHub."),
("macOS 14 ou plus récent, Mac à puce Apple", "macOS 14 or later, Apple silicon Macs"),
("Détail par voie", "Requirements by path"),
# ---- scène -----------------------------------------------------------------
("compte-rendu.md", "meeting-notes.md"),
("# Comité du 20 août", "# Board meeting, 20 August"),
("- le budget tient, la roadmap glisse d'un mois", "- budget holds, the roadmap slips by a month"),
("- valider le churn avant le prochain board", "- confirm the churn before the next board"),
('aria-label="La barre de Caspr pendant un enregistrement sur la voie macOS : minuteur à 42 secondes, micro en mode standard, l\'aperçu de ce qui est entendu, et sous la carte le français sélectionné à gauche, le curseur comme destination à droite."',
 'aria-label="The Caspr bar during a recording on the macOS path: timer at 42 seconds, microphone in standard mode, a preview of what is being heard, and below the card French selected on the left and the caret as destination on the right."'),
("valider le churn avant le prochain bord", "confirm the churn before the next bored"),
(">Curseur</span>", ">Caret</span>"),
("Sur la voie macOS, l'aperçu montre ce qui est entendu pendant que vous parlez, en version rapide — d'où le «&nbsp;bord&nbsp;» que le texte final peut encore corriger. Il répond à «&nbsp;le micro m'entend-il&nbsp;», pas à «&nbsp;la transcription sera-t-elle juste&nbsp;». La voie ChatGPT n'a pas d'aperçu : c'est sa page qui tient le micro.",
 "On the macOS path, the preview shows what is being heard as you speak, in a quick draft — hence “bored”, which the final text may still correct. It answers “is the mic hearing me”, not “will the transcription be right”. The ChatGPT path has no preview: its page holds the microphone."),
# ---- atouts ----------------------------------------------------------------
("<b>Hors ligne</b> avec macOS — rien ne sort de votre Mac", "<b>Offline</b> with macOS — nothing leaves your Mac"),
("<b>ChatGPT</b> par votre propre compte", "<b>ChatGPT</b> through your own account"),
("<b>Open source</b> — code sous licence MIT", "<b>Open source</b> — MIT licensed code"),
("<b>Aucun serveur</b> Caspr, aucun abonnement", "<b>No Caspr server</b>, no subscription"),
# ---- deux voies ------------------------------------------------------------
('id="voies" aria-labelledby="voies-titre"', 'id="paths" aria-labelledby="paths-title"'),
('<h2 id="voies-titre">Deux voies. Vous choisissez qui écoute.</h2>',
 '<h2 id="paths-title">Two paths. You choose who listens.</h2>'),
("""          Les deux ne peuvent pas écouter en même temps : l'une tient le micro,
          l'autre se tait. Vous en retenez une à l'installation, et vous en changez
          d'un clic — depuis le menu, les réglages ou un raccourci.""",
 """          They cannot both listen at once: one holds the microphone, the other
          stays quiet. You pick one when you install, and switch with one click —
          from the menu, the settings or a shortcut."""),
("Ce que font les deux voies de Caspr, macOS et ChatGPT, et ce que chacune demande",
 "What Caspr's two paths, macOS and ChatGPT, do and what each one needs"),
('<span class="col-note">Par votre propre compte</span>', '<span class="col-note">Through your own account</span>'),
('<th scope="row">Où va votre voix</th>', '<th scope="row">Where your voice goes</th>'),
('<td data-col="macOS">Nulle part : <strong>elle ne quitte pas votre Mac</strong></td>',
 '<td data-col="macOS">Nowhere: <strong>it never leaves your Mac</strong></td>'),
('<td data-col="ChatGPT">Chez OpenAI, <strong>par votre compte ChatGPT</strong></td>',
 '<td data-col="ChatGPT">To OpenAI, <strong>through your ChatGPT account</strong></td>'),
('<th scope="row">Compte</th>', '<th scope="row">Account</th>'),
('<td data-col="macOS">Aucun</td>', '<td data-col="macOS">None</td>'),
('<td data-col="ChatGPT">Un compte ChatGPT, par adresse et mot de passe</td>',
 '<td data-col="ChatGPT">A ChatGPT account, with email and password</td>'),
('<th scope="row">Connexion à Internet</th>', '<th scope="row">Internet connection</th>'),
('<td data-col="macOS">Inutile</td>', '<td data-col="macOS">Not needed</td>'),
('<td data-col="ChatGPT">Indispensable</td>', '<td data-col="ChatGPT">Required</td>'),
('<th scope="row">Aperçu en direct</th>', '<th scope="row">Live preview</th>'),
('<td data-col="macOS">Oui, sous la barre</td>', '<td data-col="macOS">Yes, under the bar</td>'),
('<td data-col="ChatGPT">Non : la page ChatGPT tient le micro</td>',
 '<td data-col="ChatGPT">No: the ChatGPT page holds the microphone</td>'),
('<th scope="row">Ce qu\'elle ajoute</th>', '<th scope="row">What it adds</th>'),
('<td data-col="macOS">Une transcription instantanée</td>', '<td data-col="macOS">Instant transcription</td>'),
('<td data-col="ChatGPT">Des <strong>modules</strong> : texte brut, réorganisation, question</td>',
 '<td data-col="ChatGPT"><strong>Modules</strong>: raw text, reorganise, ask a question</td>'),
('<th scope="row">Mise en route</th>', '<th scope="row">Setup</th>'),
('<td data-col="macOS">Un modèle de langue, que macOS télécharge</td>',
 '<td data-col="macOS">A language model, downloaded by macOS</td>'),
('<td data-col="ChatGPT">Se connecter, puis une calibration automatique</td>',
 '<td data-col="ChatGPT">Sign in, then an automatic calibration</td>'),
('<th scope="row">Ce qui peut la casser</th>', '<th scope="row">What can break it</th>'),
('<td data-col="macOS">Presque rien : c\'est une interface du système</td>',
 '<td data-col="macOS">Hardly anything: it is a system interface</td>'),
('<td data-col="ChatGPT">Un remaniement du site de ChatGPT</td>',
 '<td data-col="ChatGPT">A redesign of the ChatGPT website</td>'),
("""        Côté macOS, Caspr prend la meilleure reconnaissance que votre machine sait faire
        tourner, sans rien vous demander : <strong>Apple Intelligence</strong>, à partir de
        macOS 26, et la <strong>Dictée</strong> du système en repli, quand Apple Intelligence
        ne sait pas écrire votre langue — jamais par choix : mesurée sur 129 dictées réelles,
        elle perdait près de 44&nbsp;% des mots. La disponibilité est mesurée sur la machine,
        jamais déduite d'un numéro de version.""",
 """        On the macOS side, Caspr picks the best recogniser your machine can run, without
        asking you: <strong>Apple Intelligence</strong>, from macOS 26, and system
        <strong>Dictation</strong> as a fallback when Apple Intelligence cannot write your
        language — never by choice: measured on 129 real dictations, it lost close to 44% of
        the words. Availability is measured on the machine, never inferred from a version
        number."""),
("""        Côté ChatGPT, Caspr ouvre chatgpt.com dans une page qu'il héberge, avec votre
        session, et en clique les boutons à votre place. Ce n'est pas une API : si OpenAI
        remanie la page, la voie peut cesser de fonctionner. Caspr réapprend alors les
        boutons seul, en les essayant sous vos yeux — un seul message d'essai, annoncé
        avant de partir.""",
 """        On the ChatGPT side, Caspr opens chatgpt.com in a page it hosts, with your session,
        and clicks its buttons for you. It is not an API: if OpenAI redesigns the page, the
        path can stop working. Caspr then relearns the buttons by itself, trying them in
        front of you — a single test message, announced before it is sent."""),
# ---- avant / après ---------------------------------------------------------
('id="dictee" aria-labelledby="dictee-titre"', 'id="dictation" aria-labelledby="dictation-title"'),
('<h2 id="dictee-titre">Dites-le en vrac. Recevez-le en ordre.</h2>',
 '<h2 id="dictation-title">Say it any old way. Get it back in order.</h2>'),
("""          On hésite, on se reprend, on repart en arrière. Sur la voie ChatGPT, le
          module <strong>Réorganiser</strong> renvoie votre dictée à ChatGPT et écrit sa
          réponse à votre curseur : ce que vous vouliez dire, dans l'ordre.""",
 """          We hesitate, we backtrack, we start the sentence again. On the ChatGPT path,
          the <strong>Réorganiser</strong> (reorganise) module sends your dictation back to
          ChatGPT and writes its reply at your caret: what you meant, in order."""),
("Ce que vous dites", "What you say"),
("""            «&nbsp;Alors <span class="filler">euh</span> attends, on va
            <span class="filler">on va</span> décaler la réunion à jeudi
            <span class="filler">enfin non</span> vendredi matin
            <span class="filler">euh</span> et prévenir Sarah&nbsp;»""",
 """            “So <span class="filler">er</span> hang on, we'll
            <span class="filler">we'll</span> push the meeting to Thursday
            <span class="filler">no wait</span> Friday morning
            <span class="filler">er</span> and let Sarah know”"""),
("""            Une dictée ordinaire écrit tout, «&nbsp;euh&nbsp;» compris. Le temps gagné
            à parler se reperd à corriger.""",
 """            Ordinary dictation writes all of it down, every “er” included. The time
            speaking saved goes straight back into fixing it."""),
("Avec Réorganiser", "With Réorganiser"),
("«&nbsp;On va décaler la réunion à vendredi matin, et prévenir Sarah.&nbsp;»",
 "“We'll push the meeting to Friday morning, and let Sarah know.”"),
("""            Les hésitations, les reprises et les faux départs sont retirés ; la
            ponctuation suit le sens.""",
 """            Hesitations, restarts and false starts are removed; punctuation follows the
            meaning."""),
("""        La consigne se dit, elle ne se règle pas : «&nbsp;traduis en anglais&nbsp;» ou
        «&nbsp;fais-en une liste&nbsp;», prononcé dans la dictée, suffit. Si la
        réorganisation échoue, la transcription brute est écrite à la place : une dictée
        ne se perd pas. Sur la voie macOS, le texte s'écrit tel qu'il a été reconnu, sans
        seconde passe.""",
 """        The instruction is spoken, not configured: “translate this into English” or “make
        it a list”, said in the dictation, is enough. If reorganising fails, the raw
        transcription is written instead: a dictation is never lost. On the macOS path,
        the text is written as it was recognised, with no second pass."""),
]

PAIRS += [
# ---- la barre --------------------------------------------------------------
('id="barre" aria-labelledby="barre-titre"', 'id="bar" aria-labelledby="bar-title"'),
('<h2 id="barre-titre">Vous changez d\'avis en cours de phrase. La barre suit.</h2>',
 '<h2 id="bar-title">You change your mind mid-sentence. The bar keeps up.</h2>'),
("""          Dicter n'est pas une commande qu'on lance et qu'on subit. On réalise au
          milieu d'une phrase que le texte ne doit pas aller là où il va. Une barre
          flotte au bas de l'écran pendant que vous parlez, et tout ce qu'elle
          porte se change sans vous interrompre.""",
 """          Dictation is not a command you fire and endure. Halfway through a sentence you
          realise the text should not go where it is going. A bar floats at the bottom of
          the screen while you talk, and everything on it can change without
          interrupting you."""),
('<span class="control-name">La destination</span>', '<span class="control-name">Destination</span>'),
("<dd>Le curseur de l'application où vous êtes, ou un fichier. Le fichier de notes est mémorisé à part : l'aller-retour coûte un clic.</dd>",
 "<dd>The caret of whatever app you are in, or a file. The note file is remembered separately: the round trip costs one click.</dd>"),
('<span class="control-name">Le module</span>', '<span class="control-name">Module</span>'),
("<dd>Sur la voie ChatGPT : Brut, Réorganiser ou Discuter. Brut écrit la transcription telle quelle ; Discuter pose une question et garde la page ouverte pour la réponse.</dd>",
 "<dd>On the ChatGPT path: Brut, Réorganiser or Discuter — raw, reorganise, discuss. Raw writes the transcription as it is; discuss asks a question and keeps the page open for the answer.</dd>"),
('<span class="control-name">L\'aperçu en direct</span>', '<span class="control-name">Live preview</span>'),
("<dd>Sur la voie macOS : ce qui est entendu, pendant que vous le dites. Il répond à «&nbsp;le micro m'entend-il&nbsp;», pas à «&nbsp;le texte sera-t-il juste&nbsp;».</dd>",
 "<dd>On the macOS path: what is being heard, as you say it. It answers “is the mic hearing me”, not “will the text be right”.</dd>"),
('<span class="control-name">La voie</span>', '<span class="control-name">Path</span>'),
("<dd>macOS ou ChatGPT, depuis le menu de la barre ou un raccourci. Tant que la voie est ChatGPT, le fantôme de la barre des menus porte une étincelle.</dd>",
 "<dd>macOS or ChatGPT, from the menu bar menu or a shortcut. While ChatGPT is the path, the ghost in the menu bar wears a sparkle.</dd>"),
("""          La destination et le module sont lus <strong>à la fin de l'enregistrement</strong>,
          jamais au début. Appuyer sur <strong>Notes</strong> au milieu d'une phrase envoie
          cette dictée-là dans le fichier, et l'inverse fonctionne aussi. C'est ce qui rend
          la barre utile plutôt que décorative — et elle ne prend jamais le focus, pour que
          le texte atterrisse là où votre curseur se trouve déjà.""",
 """          Destination and module are read <strong>when the recording ends</strong>, never
          when it starts. Pressing <strong>Notes</strong> halfway through a sentence sends
          that dictation to the file, and the reverse works too. That is what makes the bar
          useful rather than decorative — and it never takes focus, so the text lands where
          your caret already is."""),
# ---- notes -----------------------------------------------------------------
('aria-labelledby="notes-titre"', 'aria-labelledby="notes-title"'),
('<h2 id="notes-titre">Parlez maintenant, triez plus tard</h2>', '<h2 id="notes-title">Speak now, sort it out later</h2>'),
("""          Toutes les phrases n'ont pas de destination au moment où elles vous viennent.
          Basculez sur <strong>Notes</strong> : le texte part dans un fichier Markdown daté
          au lieu du curseur, sans ouvrir d'application ni quitter ce que vous faisiez.
          La journée s'accumule, et vous la relisez quand c'est le moment.""",
 """          Not every sentence has a destination the moment it occurs to you. Switch to
          <strong>Notes</strong> and the text goes to a dated Markdown file instead of the
          caret — no app to open, nothing to leave behind. The day accumulates, and you
          read it back when the time comes."""),
("Rappeler à Sarah que le dossier attend sa relecture.", "Remind Sarah the file is waiting on her review."),
("Le churn remonte sur la cohorte de mars, creuser avant vendredi.", "Churn is up on the March cohort, dig in before Friday."),
("Idée : reprendre le protocole après le changement de seuil.", "Idea: revisit the protocol after the threshold change."),
("Vérifier le spread sur les échéances longues.", "Check the spread on the long maturities."),
("""        Le fichier reste un fichier texte, sur votre disque, lisible par n'importe quel
        éditeur. Rien à exporter le jour où vous changez d'outil.""",
 """        The file stays a text file, on your disk, readable by any editor. Nothing to
        export the day you change tools."""),
# ---- deux voies, en-têtes du tableau ---------------------------------------
('<span class="sr-only">Critère</span>', '<span class="sr-only">Criterion</span>'),
('<span class="col-note">La reconnaissance vocale du système</span>', '<span class="col-note">The system\'s speech recognition</span>'),
# ---- local / open source ---------------------------------------------------
('aria-labelledby="local-titre"', 'aria-labelledby="local-title"'),
('<h2 id="local-titre">Aucun serveur, et tout le code à lire</h2>',
 '<h2 id="local-title">No server, and all the code to read</h2>'),
("""          Caspr n'a pas de serveur : il n'existe nulle part chez nous où envoyer quoi
          que ce soit. Ce qui quitte votre Mac, et vers où, dépend seulement de la voie
          que vous choisissez. Et vous n'avez pas à me croire sur parole —
          l'intégralité du code est publique, sous licence MIT, lisible et compilable
          par vous.""",
 """          Caspr has no server: there is nowhere on our side to send anything to. What
          leaves your Mac, and where it goes, depends only on the path you choose. And
          you don't have to take my word for it — the whole codebase is public, MIT
          licensed, yours to read and to build."""),
("<strong>Voie macOS : hors ligne pour de bon.</strong> Coupez le Wi-Fi : la dictée fonctionne à l'identique, et rien n'est envoyé.",
 "<strong>macOS path: offline for real.</strong> Turn off Wi-Fi and dictation behaves identically, and nothing is sent."),
("<strong>Voie ChatGPT : votre compte, pas le nôtre.</strong> La voix passe par ChatGPT, dans une page que Caspr ouvre avec votre session, comme sur chatgpt.com — selon les conditions de votre compte OpenAI.",
 "<strong>ChatGPT path: your account, not ours.</strong> Your voice goes through ChatGPT, in a page Caspr opens with your session, just as on chatgpt.com — under your OpenAI account's terms."),
("<strong>Gratuit et open source.</strong> Code Swift sous licence MIT, sur GitHub. Aucun bridage, aucun abonnement, aucun compte Caspr.",
 "<strong>Free and open source.</strong> MIT licensed Swift code, on GitHub. Nothing held back, no subscription, no Caspr account."),
("<strong>Aucune télémétrie.</strong> Pas de statistiques d'usage, pas de traceur, pas de rapport d'incident silencieux.",
 "<strong>No telemetry.</strong> No usage statistics, no tracker, no silent crash reports."),
("<strong>Une seule requête à lui, facultative.</strong> La vérification des mises à jour interroge GitHub ; l'automatique est désactivée par défaut.",
 "<strong>One request of its own, optional.</strong> The update check queries GitHub; the automatic one is off by default."),
("<strong>Une désinstallation qui désinstalle.</strong> Préférences, historique, session ChatGPT, journaux et autorisations partent à la corbeille — et seulement ce qui est réellement présent.",
 "<strong>An uninstaller that uninstalls.</strong> Preferences, history, the ChatGPT session, logs and permissions go to the Trash — and only what is actually there."),
("Lire le code sur GitHub", "Read the code on GitHub"),
]

PAIRS += [
# ---- questions -------------------------------------------------------------
('aria-labelledby="questions-titre"', 'aria-labelledby="questions-title"'),
('<h2 id="questions-titre">Questions</h2>', '<h2 id="questions-title">Questions</h2>'),
("<span>De quel Mac ai-je besoin&nbsp;?</span>", "<span>Which Mac do I need?</span>"),
("<p>Caspr demande <strong>macOS 14 ou plus récent</strong>, sur un <strong>Mac à puce Apple</strong>. Par la voie macOS, il prend Apple Intelligence à partir de macOS 26 quand la machine sait écrire votre langue, et la Dictée du système sinon.</p>",
 "<p>Caspr needs <strong>macOS 14 or later</strong>, on an <strong>Apple silicon Mac</strong>. On the macOS path it uses Apple Intelligence from macOS 26 when the machine can write your language, and system Dictation otherwise.</p>"),
("<p>Par la voie <strong>ChatGPT</strong>, il faut un compte ChatGPT et une connexion à Internet : c'est la page de ChatGPT qui écoute et transcrit.</p>",
 "<p>The <strong>ChatGPT</strong> path needs a ChatGPT account and an internet connection: the ChatGPT page is what listens and transcribes.</p>"),
("<span>Ma voix ou mes textes partent-ils sur un serveur&nbsp;?</span>", "<span>Does my voice or text leave my machine?</span>"),
("<p>Cela dépend de la voie. <strong>Avec macOS, non</strong> : la transcription s'exécute sur votre machine, et rien n'est envoyé — coupez le Wi-Fi, elle fonctionne à l'identique. <strong>Avec ChatGPT, oui</strong> : votre voix passe par votre propre compte ChatGPT, chez OpenAI, comme sur chatgpt.com.</p>",
 "<p>It depends on the path. <strong>With macOS, no</strong>: transcription runs on your machine and nothing is sent — turn off Wi-Fi and it behaves identically. <strong>With ChatGPT, yes</strong>: your voice goes through your own ChatGPT account, to OpenAI, just as on chatgpt.com.</p>"),
("<p>Caspr, lui, n'a ni serveur, ni compte, ni télémétrie. Sa seule requête à lui est la vérification des mises à jour sur GitHub, et l'automatique est désactivée par défaut.</p>",
 "<p>Caspr itself has no server, no account and no telemetry. Its only request of its own is the update check against GitHub, and the automatic one is off by default.</p>"),
("<span>Pourquoi macOS refuse-t-il d'ouvrir l'application la première fois&nbsp;?</span>", "<span>Why does macOS refuse to open the app the first time?</span>"),
("<p>Parce que l'application n'est pas notariée par Apple — la notarisation suppose un compte développeur payant. Caspr est signé de façon ad hoc, alors macOS affiche un avertissement au premier lancement.</p>",
 "<p>Because the app is not notarised by Apple — notarisation requires a paid developer account. Caspr is ad-hoc signed, so macOS warns on first launch.</p>"),
("<p>L'autorisation se donne une fois, dans Réglages Système, rubrique Confidentialité et sécurité. Le guide qui s'ouvre au téléchargement montre chaque étape en image.</p>",
 "<p>You grant permission once, in System Settings under Privacy &amp; Security. The guide that opens on download shows every step in pictures.</p>"),
("<span>Qu'apporte la voie ChatGPT&nbsp;?</span>", "<span>What does the ChatGPT path add?</span>"),
("<p>Une transcription souvent meilleure, et des <strong>modules</strong> : le texte brut, une réorganisation de ce que vous avez dit, ou une question à laquelle ChatGPT répond dans sa page.</p>",
 "<p>Often better transcription, and <strong>modules</strong>: the raw text, a reorganised version of what you said, or a question ChatGPT answers in its page.</p>"),
("<p>Caspr pilote l'<strong>interface web</strong> de ChatGPT, pas une API. Si OpenAI la remanie, la voie peut cesser de fonctionner jusqu'à une nouvelle calibration, que Caspr mène seul en essayant les boutons de la page. La voie macOS, elle, ne dépend de personne.</p>",
 "<p>Caspr drives ChatGPT's <strong>web interface</strong>, not an API. If OpenAI redesigns it, the path can stop working until a new calibration, which Caspr runs on its own by trying the page's buttons. The macOS path depends on no one.</p>"),
("<span>Quelle est la licence&nbsp;?</span>", "<span>What is the licence?</span>"),
("<p>Le code de Caspr est sous <strong>licence MIT</strong>, public sur GitHub : vous pouvez le lire, le compiler et le modifier.</p>",
 "<p>Caspr's code is under the <strong>MIT licence</strong>, public on GitHub: you can read it, build it and change it.</p>"),
("<p>La voie ChatGPT utilise votre propre compte, selon les conditions d'OpenAI. Caspr n'est pas affilié à OpenAI.</p>",
 "<p>The ChatGPT path uses your own account, under OpenAI's terms. Caspr is not affiliated with OpenAI.</p>"),
("<span>Puis-je désinstaller proprement&nbsp;?</span>", "<span>Can I uninstall cleanly?</span>"),
("<p>Oui. L'application inclut un désinstallateur qui met à la corbeille les préférences, l'historique, la session ChatGPT s'il y en a une, les journaux et les autorisations — et il ne propose que ce qui est effectivement présent.</p>",
 "<p>Yes. The app ships an uninstaller that moves the preferences, the history, the ChatGPT session if there is one, the logs and the permissions to the Trash — and it only offers what is actually there.</p>"),
# ---- appel final -----------------------------------------------------------
('aria-labelledby="final-titre"', 'aria-labelledby="final-title"'),
('<h2 id="final-titre">Essayez-le sur la prochaine phrase que vous alliez taper</h2>',
 '<h2 id="final-title">Try it on the next sentence you were about to type</h2>'),
("""        Une touche, votre voix, et le texte arrive à votre curseur. Vous choisissez la
        voie à l'installation, et vous en changez d'un clic.""",
 """        One key, your voice, and the text arrives at your caret. You choose the path
        when you install, and switch with one click."""),
("Voir toutes les versions", "See all releases"),
("Gratuit et open source · macOS 14 ou plus récent · aucun compte Caspr", "Free and open source · macOS 14 or later · no Caspr account"),
# ---- pied de page ----------------------------------------------------------
("Dictée vocale pour macOS. Hors ligne avec macOS, ou par votre compte ChatGPT. Open source, sans serveur, sans abonnement.",
 "Dictation for macOS. Offline with macOS, or through your ChatGPT account. Open source, no server, no subscription."),
("Un projet de <b>Lyria Studio</b>", "A project by <b>Lyria Studio</b>"),
('aria-labelledby="foot-produit"', 'aria-labelledby="foot-product"'),
('<h2 id="foot-produit">Le produit</h2>', '<h2 id="foot-product">Product</h2>'),
('<li><a href="#voies">Deux voies</a></li>', '<li><a href="#paths">Two paths</a></li>'),
('<li><a href="#dictee">La dictée</a></li>', '<li><a href="#dictation">Dictation</a></li>'),
('<li><a href="#barre">La barre</a></li>', '<li><a href="#bar">The bar</a></li>'),
('<li><a href="#notes">Les notes</a></li>', '<li><a href="#notes">Notes</a></li>'),
('<li><a href="#local">Confidentialité</a></li>', '<li><a href="#local">Privacy</a></li>'),
('<h2 id="foot-code">Le code</h2>', '<h2 id="foot-code">Code</h2>'),
("Dépôt GitHub", "GitHub repository"),
(">Versions</a>", ">Releases</a>"),
("Signaler un problème", "Report an issue"),
("Licence MIT du code", "MIT licence"),
('<h2 id="foot-site">Le site</h2>', '<h2 id="foot-site">Site</h2>'),
('<li><a href="/en" hreflang="en" lang="en">English version</a></li>', '<li><a href="/" hreflang="fr" lang="fr">Version française</a></li>'),
('<li><a href="mentions-legales.html">Mentions légales</a></li>', '<li><a href="legal.html">Legal notice</a></li>'),
('<li><a href="politique-de-confidentialite.html">Confidentialité</a></li>', '<li><a href="privacy.html">Privacy</a></li>'),
('© 2026 Caspr — un projet <a href="https://lyriastudio.fr" rel="noopener">Lyria Studio</a>. Code sous licence MIT.',
 '© 2026 Caspr — a <a href="https://lyriastudio.fr" rel="noopener">Lyria Studio</a> project. Code under the MIT licence.'),
('<a href="mentions-legales.html">Mentions légales</a>\n        <a href="politique-de-confidentialite.html">Politique de confidentialité</a>',
 '<a href="legal.html">Legal notice</a>\n        <a href="privacy.html">Privacy policy</a>'),
# ---- fenêtre d'installation ------------------------------------------------
('aria-labelledby="modal-titre"', 'aria-labelledby="modal-title"'),
('aria-label="Fermer le guide d\'installation"', 'aria-label="Close the install guide"'),
('<h2 id="modal-titre">Le téléchargement a commencé</h2>', '<h2 id="modal-title">Your download has started</h2>'),
("<p>Votre fichier <code>Caspr.dmg</code> arrive. Voici comment l'ouvrir, en huit étapes illustrées.</p>",
 "<p>Your <code>Caspr.dmg</code> file is on its way. Here is how to open it, in eight illustrated steps.</p>"),
("<p><strong>Pourquoi ces étapes ?</strong> Caspr n'est pas notarié par Apple, ce qui suppose un compte développeur payant. macOS affiche donc un avertissement au premier lancement. L'autorisation se donne une fois, et prend une trentaine de secondes.</p>",
 "<p><strong>Why these steps?</strong> Caspr is not notarised by Apple, which requires a paid developer account. macOS therefore warns you on first launch. You grant permission once, and it takes about thirty seconds.</p>"),
('id="step-title">Ouvrez le fichier téléchargé</span>', 'id="step-title">Open the downloaded file</span>'),
("Double-cliquez sur <code>Caspr.dmg</code> dans vos téléchargements pour monter l'image disque.",
 "Double-click <code>Caspr.dmg</code> in your downloads to mount the disk image."),
('id="step-prev">Précédente</button>', 'id="step-prev">Previous</button>'),
('aria-label="Aller à une étape"', 'aria-label="Go to a step"'),
('id="step-next">Suivante</button>', 'id="step-next">Next</button>'),
("Le téléchargement n'a pas démarré ?", "Download didn't start?"),
('id="modal-done">J\'ai terminé</button>', 'id="modal-done">I\'m done</button>'),
]

# Une paire qui ne trouve plus rien est une traduction périmée : la page
# française a changé, et l'anglaise garderait l'ancien texte sans le dire.
stale = [a for a, _ in PAIRS if a not in src]
if stale:
    print("pairs matching nothing in index.html:")
    for a in stale:
        print("  ", a[:90].replace("\n", " "))

out = src
for a, b in PAIRS:
    out = out.replace(a, b)

# Les ancres restantes suivent les identifiants anglais.
for a, b in [("#voies", "#paths"), ("#dictee", "#dictation"), ("#barre", "#bar")]:
    out = out.replace(f'href="{a}"', f'href="{b}"')

(ROOT / "en.html").write_text(out, encoding="utf-8")
en_dir = ROOT / "en"
en_dir.mkdir(exist_ok=True)
(en_dir / "index.html").write_text(out, encoding="utf-8")

# --- contrôle : plus un mot de français dans le texte visible ---------------
from html.parser import HTMLParser
class Visible(HTMLParser):
    def __init__(s):
        super().__init__(); s.t=[]; s.skip=0; s.a=[]
    def handle_starttag(s, tag, at):
        if tag in ("script", "style"): s.skip += 1
        d = dict(at)
        for k in ("alt", "aria-label", "title", "content"):
            if d.get(k): s.a.append(d[k])
    def handle_endtag(s, tag):
        if tag in ("script", "style"): s.skip = max(0, s.skip - 1)
    def handle_data(s, d):
        if not s.skip and d.strip(): s.t.append(d.strip())

v = Visible(); v.feed(out)
blob = " ".join(v.t) + " " + " ".join(v.a)
# Les citations françaises sont l'exemple : elles doivent rester.
# Les noms des modules sont ceux de l'application, qui est en français.
for keep in ["Réorganiser", "Version française"]:
    blob = blob.replace(keep, "")
left = sorted(set(re.findall(r"\b[A-Za-zÀ-ÿ']*(?:é|è|ê|à|ù|ç|û|ô|î|É)[A-Za-zÀ-ÿ']*\b", blob)))
print("en.html — French left in visible text:", left if left else "none")
