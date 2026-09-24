# Le relais — la voie ChatGPT

Le relais fait dicter par le transcripteur de ChatGPT, dans une page web que
Caspr héberge et pilote. C'est **l'une des deux voies** du produit, à rang égal
avec macOS : du code de premier rang, qui ne se retire pas. La voie macOS
écrit hors ligne, sans compte ; la voie ChatGPT fait passer la voix par le
compte ChatGPT de l'utilisateur, dans la page embarquée, et Caspr n'a aucun
serveur.

Ce document garde ce qui a été appris à la dure en pilotant un service tiers
par son interface web. Les règles qui suivent ne se redécouvrent qu'en
cassant quelque chose chez quelqu'un.

Cette interface n'est pas une API : OpenAI la remanie sans prévenir, et rien
ne promet qu'un bouton garde sa place. C'est le prix de la voie, et il se
dit, au README comme sur le site. La défense est la calibration, qui
réapprend les boutons en les essayant, et un repère qui ne trouve rien dit
« absent » au lieu de deviner (cf. les règles plus bas).

## Les composants

Tout tient dans `app/Sources/Caspr/Relais/`, un fichier par responsabilité —
sauf les types sans dépendance système (modules, capacités, sorties, affichage,
structure des sélecteurs, modules livrés), rangés dans
`app/Sources/CasprCore/Relais/` pour être sous tests :

| Fichier | Responsabilité |
|---|---|
| `Relais.swift` | La façade et la vie de la page : l'occupation, dérivée de deux faits (une dictée a la page, une calibration l'a) ; la page au repos (`Repos` : prête, en préparation, gardée pour une récupération) ; et `finirLeCycle`, la seule sortie d'une dictée, qui tient la règle « la fin d'une dictée prépare la suivante ». |
| `RelaisPage.swift` | La `WKWebView`, la session, le micro. Au premier montage de chaque lancement, elle vide le cache disque de WebKit — jamais les cookies ni le stockage de la page, qui portent la session. |
| `RelaisPage+Pont.swift` | La façade du pont : un seul point d'appel, `pont(fonction, args…)`, qui décode le JSON que rend la page, et une méthode typée par fonction (`cliquer`, `lire`, `encadrer`, `copierLaReponse`…). Sans délai, et l'annulation le tranche sur-le-champ même quand la page ne répond jamais (`AppelAnnulable`, dans `CasprCore`) — le chemin d'une dictée. `sonder` l'enveloppe d'une borne, **au repos seulement** : son silence fait reconstruire la page, jamais échouer une dictée. Les noms des fonctions sont un type (`RelaisScripts.Fonction`), et un test vérifie que le pont les expose toutes, et elles seules. Un pont absent d'une page chargée — ni `charger()` en cours, ni `isLoading` de WebKit, qui couvre « Recharger » et les redirections de la page — est un échec prouvé (`pontAbsent`), pas une attente. Le pont vit dans un monde à lui (`RelaisPage.monde`, « caspr ») : il agit sur le DOM de chatgpt.com, mais la page ne le voit pas et ne peut pas l'écraser (éprouvé fonction par fonction contre le monde de la page : mêmes résultats) ; revenir au monde de la page tient en une ligne. |
| `RelaisFenetres.swift` | Les **deux** fenêtres, et la vue web qui passe de l'une à l'autre (cf. « Les deux fenêtres » plus bas). |
| `RelaisDictee.swift` (dans `CasprCore`) | Le scénario d'une dictée : écouter, rendre la transcription, envoyer, récupérer la réponse, la faire lire, arrêter la page après un abandon. Écrit sur ce qu'il demande à la page (`RelaisPageDictee`, dont `RelaisPage` est la vraie) et au presse-papiers, il se rejoue en test contre une page factice et une horloge qu'on avance à la main. Toutes ses attentes passent par une seule primitive, `observer` : un relevé par quart de seconde, **aucune échéance**, les échecs que la page prouve jugés avant tout. `RelaisPreparation` y décide ce que la fin d'une dictée fait de la page, selon ce qu'elle est au repos — morte, en chargement, muette, ou qui répond. |
| `RelaisObservation.swift` (dans `CasprCore`) | Le temps du scénario : l'horloge, `RelaisDelai` — la liste, et la seule, des délais de geste qui restent sur le chemin d'une dictée, chacun avec ce qu'il prouve —, et `AppelAnnulable`. |
| `RelaisPage+Calibration.swift` | Le message d'essai et les guetteurs de clic, pour les deux calibrations. |
| `RelaisPage+Navigation.swift` | Les délégués WebKit : l'autorisation du micro, les popups de connexion, les navigations échouées, le processus tué. |
| `RelaisErreur.swift` (dans `CasprCore`) | Ce qui peut échouer, et comment la barre et le menu le disent. |
| `RelaisScripts.swift` (dans `CasprCore`) | Le JavaScript injecté — le pont (cliquer, lire, vider, calibrer) et l'écho —, en chaînes Swift pour que les tests l'atteignent : une faute de syntaxe casse `swift test` au lieu de laisser la page sans pont. |
| `RelaisCalibrationAuto.swift` | Le parcours de la calibration automatique : essayer les boutons, ne retenir que ceux dont l'effet se voit. Il rend des preuves (`RelaisPreuves`, dans `CasprCore`) ; c'est `Relais` qui enregistre. |
| `RelaisSelecteurs+Persistance.swift` | La persistance des sélecteurs CSS appris ; leur structure et leur décodage vivent dans `CasprCore`. |
| `RelaisCycle.swift` (dans `CasprCore`) | La machine d'une dictée, en table : ses phases (`RelaisPhase`), leur libellé et la sortie que la barre dit avec le chrono, et ce que valent la touche de dictée et la croix à chacune (`RelaisCycle.decider`). Aucune ligne ne vient de l'horloge. |
| `RelaisReglages.swift` | Les réglages de la voie ChatGPT, sous sa ligne dans Réglages › Voie : la session, ce que le relais a appris, les modules, le point de départ. La carte de session (`RelaisSession`) est aussi celle de l'accueil, et c'est elle qui dit ce que la voie exige pour dicter. |
| `RelaisModuleCard.swift` | Le réglage d'un module : ses actions, sa sortie, son affichage. |
| `RelaisCatalogue.swift` | Les modules connus, fusionnés avec les réglages de l'utilisateur, et celui qui est retenu. |

### Ce qu'on montre pendant la dictée

Trois niveaux, réglables : rien, la barre seule, la page entière. Le troisième
existe pour rendre un défaut diagnosticable sans lire un journal — on y voit le
texte envoyé, la réponse, une erreur de ChatGPT.

Les trois passent par la **fenêtre de la barre**, jamais par celle des
réglages, quelle que soit leur taille. Une fenêtre capable de devenir clé ferait
écrire la dictée dans la page au lieu de l'éditeur.

### Les deux fenêtres

Leurs exigences sont opposées, et une seule fenêtre qui change de costume ne
peut pas les satisfaire toutes deux.

| | Grande fenêtre | Barre |
|---|---|---|
| Sert à | se connecter, calibrer, récupérer un texte | regarder une dictée |
| Clavier | oui — sans quoi ni saisie ni copier-coller | jamais |
| Active l'application | oui | jamais |
| Suit les bureaux | non | oui |
| Niveau | normal | `.statusBar` |

`.nonactivatingPanel`, nécessaire à la barre, rend le copier-coller impossible
dans l'autre rôle : cliquer une telle fenêtre n'active pas l'application, et ⌘C
part vers celle qui l'est. La vue web passe de l'une à l'autre ; elle vit dans
la barre par défaut, rangée hors champ — jamais retirée de l'écran, le système
suspendant une fenêtre qu'il croit cachée.

### Les modules

Ce que Caspr fait d'une dictée est un **module** : des actions (envoyer,
récupérer la réponse, la faire lire à haute voix), une sortie (le curseur, les
notes, ou nulle part) et un affichage. Ceux que l'application livre ne sont
que des modules pré-remplis :

| Module | Ta voix est… | Sortie |
|---|---|---|
| **Brut** | le texte lui-même | au curseur ou en note, rien n'est envoyé |
| **Réorganiser** | la matière à remettre en ordre | au curseur ou en note, après la réponse de ChatGPT |
| **Discuter** | une question | nulle part : la page reste ouverte et prend le clavier |

Un module déclare les **capacités** dont il a besoin, et une capacité ne se
choisit pas : elle s'acquiert, par calibration ou par autorisation système. La
barre ne propose que les modules dont les capacités sont acquises.

La consigne se **dit**, elle ne se configure pas : « traduis ça en anglais » ne
tient pas dans un réglage. Caspr n'ajoute qu'un emballage, dont le seul rôle
est d'obtenir un résultat utilisable sans « Bien sûr ! Voici… » devant.

Chaque passe qui écrit ouvre une **conversation neuve**, par rechargement de
la page de départ ; « Discuter » seul garde son fil. Sans cela, la note
précédente oriente la suivante — et le contexte finirait par déborder. Cette page de départ est réglable : pointée sur un
projet ChatGPT dédié, elle y range toutes les conversations créées par Caspr,
à l'écart des vraies. C'est une URL et non un sélecteur, donc rien qui casse au
prochain remaniement de la page.

Une transformation qui échoue rend la **transcription brute**. Une dictée de
dix minutes ne se perd pas parce que la seconde passe n'a pas abouti.

Et ce brut est gardé **dès qu'il est lu**, avant la seconde passe
(`Livraison.garderLeBrut`). Si la suite échoue — l'insertion refusée, une
réponse qu'on renonce à attendre —, « Insérer la transcription brute de
ChatGPT », dans le menu de Caspr, le rend : c'est l'entrée qui sert à l'aperçu
de macOS, puisque la voie ChatGPT n'a pas d'audio à rejouer. Une livraison
réussie l'oublie. Quand un module a remanié le texte, l'historique garde le
brut à côté (sous ⌥ dans le menu, « Brut » dans les réglages) : une seconde
passe qui aboutit peut quand même avoir perdu ce qu'on avait dit.

### La calibration

Deux parcours, qui apprennent les mêmes repères. **L'automatique** essaie
lui-même les boutons de la page et ne retient que ceux dont il a vu l'effet ;
**le manuel** les fait montrer, clic par clic. Le second reste toujours à un
bouton : c'est le repli d'une page que l'automate ne sait pas lire.

La preuve est l'effet, jamais le libellé :

| Repère | Retenu quand… |
|---|---|
| zone de texte | ce qu'on y écrit s'y relit, et elle se vide |
| micro | après le clic, la page enregistre |
| arrêt | après le clic, la zone de texte revient |
| envoi | après le clic, la page porte une conversation |
| copier | le presse-papiers change, n'est pas vide, et ne contient pas le message envoyé |

C'est ce qui rend la langue de l'interface sans objet, et Caspr ne la force
pas. Les candidats viennent du filet du pont, `data-testid` d'abord ; chacun
doit être **seul** à répondre à son repère, du bon genre — vérifier qu'un
sélecteur retrouve l'élément qu'on a trouvé par lui ne vérifierait rien.

« Copier » y compris quand aucun bloc ne le porte sans ambiguïté : son repère
doit alors être seul autour de la dernière réponse, selon la règle même de la
dictée (`copierAutour`). L'essai passe par `copierLaReponse`, comme la
dictée, et ni l'un ni l'autre ne retombe sur les libellés : un repère qui ne
trouve rien veut dire que le bouton n'est pas encore là. Ce repli existait,
et il cliquait en pleine génération le « Copier le code » d'un bloc de code —
une copie non vide, étrangère au message envoyé, qui s'insérait à la place
de la réponse. La lecture de la réponse suit la même règle : le filet ne sert
qu'à qui n'a pas de repère.

Ce que l'automate s'interdit, et pourquoi :

- **Se connecter.** C'est le compte de l'utilisateur : sans session, la
  fenêtre s'ouvre, et le parcours attend qu'il s'y connecte — dix minutes au
  plus, au bout desquelles il le dit ; fermer la fenêtre l'arrête en
  silence — avant de demander, comme toujours, la
  permission d'envoyer le message d'essai. « Sans session » veut dire que la
  page l'a **dit** (un bouton de connexion, une page d'authentification), vu
  par le filet et non par le calibrage peut-être faux, après l'avoir laissée
  se charger. Une page qui ne dit rien en trente secondes « ne répond pas » :
  elle est rechargée, et personne n'est envoyé chercher un mot de passe.
- **Écrire avant la fin.** Le parcours manuel enregistre repère par repère,
  sous une main qui voit ce qu'elle clique. Un automate qui ferait de même et
  échouerait à mi-chemin remplacerait en silence la moitié d'un calibrage qui
  marchait. Il travaille donc sur des preuves à part, et n'écrit que
  l'aller-retour entier.
- **Envoyer plus d'un message.** Le message d'essai est annoncé avant de
  partir ; s'il quitte la zone de texte, aucun bouton d'envoi ne se retente.
- **Ouvrir un menu.** Le menu « … » de la réponse porte « Régénérer » et
  « Supprimer ». D'où « Lire à haute voix », qui s'y cache parfois : il reste
  à montrer à la main, et le rapport le propose tant que la réponse est à
  l'écran.
- **Garder le presse-papiers.** Sauvegardé tout entier avant d'essayer
  « copier », rendu après.

## Où le relais touche le reste de l'application

Plus des accroches à défaire un jour : les endroits où la voie ChatGPT se
distingue de la voie macOS, et pourquoi.

- **`CarteVoie.swift`** — la bascule, dans Réglages › Voie : deux lignes de
  même rang, macOS et ChatGPT, et sous elles les réglages de la seule voie
  retenue. Sous macOS, la page n'existe pas : des boutons qui la calibrent
  n'auraient rien à calibrer.
- **`CasprApp.swift`** — la même bascule dans le menu de la barre (« Écrire
  avec ChatGPT », coché ou non) et sur un raccourci facultatif, vide par
  défaut. Vers ChatGPT, seulement si la page sait dicter — connectée et
  calibrée — ; sinon ces deux chemins ouvrent Réglages › Voie au lieu de
  basculer. Vers macOS, toujours : c'est la porte de sortie. L'icône porte
  une étincelle tant que la voie est ChatGPT (`MenuBarIcon.markedForChatGPT`).
  Et la page est chargée au lancement quand la voie est ChatGPT, pour que la
  première dictée ne paie pas l'ouverture de chatgpt.com.
- **`UninstallWindow.swift`** — la session est effacée par l'API de WebKit
  avant le balayage des fichiers. C'est l'appelant qui attend, parce qu'il est
  dans un contexte qui le peut : le faire depuis le désinstalleur lui-même
  bloquerait le fil principal qu'attend l'effacement.
- **`Uninstall.swift`** — ramasse ce qui pourrait rester dans
  `~/Library/WebKit/<bundle>`, et **dit** dans la liste qu'une session ChatGPT
  est connectée. Sans cette mention, une case nommée « Réglages et historique »
  décidait en silence d'une session ouverte sur un service tiers.
- **`Dictee/Barre/RecordingOverlay.swift`** — la pastille des modules (`moduleLabels`,
  `onSelectModule`) : le choix se fait au moment de parler, pas dans un écran
  de réglages. L'attente, elle, s'affiche avec sa phase et son chrono dès dix
  secondes, et la sortie (`showProcessing(_:progress:)`). La croix, pendant
  l'écoute et pendant une attente de ChatGPT, annule tout sans rien insérer
  (`onCancel`) ; la touche de dictée, elle, renonce à ChatGPT en insérant la
  transcription brute si elle est déjà lue (cf. `RelaisCycle`).
- **`DictationController.swift`** — l'état commun, la voie figée à l'appui
  (`voieDuCycle`), le cycle macOS, Échap et les recours du menu. Sous
  ChatGPT, la touche et la croix ne font que passer le geste à la machine.
- **`VoieChatGPT.swift`** — la machine d'une dictée ChatGPT, en marche : sa
  phase, écrite par `entrer` seulement (le journal « a → b après x s », l'état
  du contrôleur, l'occupation de la page, la barre) ; une tâche, `moteur`, qui
  déroule tout de l'appui à la livraison — attendre la page, écouter sans
  ouvrir le micro de Caspr, arrêter et lire, transformer, ouvrir la
  discussion ou livrer — ; un numéro, `generation`, vérifié après chaque
  attente, pour qu'un cycle abandonné ne touche plus rien ; et `geste`, qui
  décide sur-le-champ par la table de `RelaisCycle`. Aucun audio à conserver,
  donc pas de « Réessayer » : le recours est la transcription brute, gardée
  dès qu'elle est lue. Le pendant de `VoieApple.swift`, qui ne partage avec
  elle que la livraison.
- **`DicteeEnCours.swift`** — le module et la destination, figés à l'arrêt de
  l'écoute et portés jusqu'à la livraison : `RelaisCatalogue.courant` relit
  les préférences à chaque accès, et l'aller-retour ChatGPT sépare les
  lectures de plusieurs minutes.
- **`Livraison.swift`** — la queue commune aux deux voies : insérer au curseur
  ou dans les notes, l'historique. Et le retour à l'application où l'on
  parlait, capturée à l'appui : il vaut pour les deux voies, mais c'est pour
  ChatGPT qu'il compte, parce que trente secondes à trois minutes séparent la
  parole de l'insertion.
- **`Accueil/`** (`OnboardingView+Screens.swift`) — le choix de la voie, juste après la bienvenue :
  les deux lignes de `CarteVoie`. Choisir ChatGPT y lance la connexion puis
  la calibration, et l'écran du premier essai montre `RelaisSession` au lieu
  du moteur de macOS. La promesse de confidentialité y est dite par voie.
- **`SetupRecoveryGuard.swift`** — le socle minimal de la voie ChatGPT : le
  raccourci, et une page connectée et calibrée (`RelaisSession.isValid`).
  Rien sur macOS.

## Six règles à ne jamais oublier

Un repère appris **doit** dire de quel genre il est — zone de saisie, bouton —
et ce genre sert trois fois : pour retrouver l'élément, pour juger le repère au
moment où on l'apprend, et pour écarter les clics hors sujet pendant la
calibration.

Un sélecteur n'est pas une adresse : c'est une question posée à la page, et
plusieurs éléments peuvent y répondre. ChatGPT pose le même libellé
d'accessibilité sur la zone de saisie et sur le bloc qui l'entoure ;
`querySelector` rendait le bloc, dont on ne peut rien lire. Toutes les dictées
partaient bien dans ChatGPT et revenaient vides — « rien n'a été entendu » — et
la calibration annonçait « le message d'essai n'a pas pu être écrit » devant une
zone où il était pourtant écrit.

Un repère appris qui ne trouve rien veut dire **absent**, et non « cherchons
quelque chose qui lui ressemble ». Les heuristiques du pont sont le filet de qui
n'a pas encore calibré, et rien d'autre. Pendant l'enregistrement, ChatGPT retire
la zone de saisie de la page : se rabattre sur « une zone éditable » trouvait
alors le document que ChatGPT avait produit à la réorganisation précédente, et
chaque dictée rendait ce document au lieu de ce qu'on venait de dire — en une
seconde et demie, au caractère près, sans que rien ne le signale.

C'est **la fin d'une dictée qui prépare la suivante**. Au repos, la page est
toujours prête : le fil ouvert quand on discute, une conversation neuve quand un
message est parti, une zone de saisie vidée sinon. Rien ne se décide à l'appui —
ni fil neuf, ni nettoyage — donc changer de module en pleine phrase n'a aucun
état à rattraper, et l'on ne paie jamais un rechargement pendant qu'on parle.
Une seule exception : un échec qui laisse la transcription dans la fenêtre
remet la préparation à plus tard (`Repos.recuperation`), pour ne pas
détruire sous les yeux le texte à récupérer. Elle se fait à la fermeture de
cette fenêtre (`fenetreFermee`) ou, si l'on rappuie sans l'avoir fermée, à
l'appui (`attendreLaPreparation`) : la barre l'annonce par « ChatGPT se
prépare… », et la touche de dictée interrompt l'attente.

Tout champ ajouté à `RelaisSelecteurs` **doit** être décodé avec
`decodeIfPresent`. Le décodage synthétisé par Swift échoue sur une clé absente
— il n'utilise pas les valeurs par défaut des propriétés — et une structure
enrichie rend d'un coup illisibles tous les calibrages déjà enregistrés. La
sanction n'est pas une erreur visible : c'est un réglage effacé chez chaque
utilisateur à la mise à jour, et un écran qui annonce « configuration
inachevée » à qui vient de la terminer. C'est arrivé en 0.13.0.

**Aucune attente de ChatGPT ne finit parce que le temps passe.** Sur le
chemin d'une dictée, une attente ne finit que par un geste de l'utilisateur —
la touche de dictée, la croix de la barre, Échap pendant l'écoute — ou par
un échec que la page
**prouve** : une alerte de refus apparue depuis la demande, le processus
WebKit mort, l'écran d'authentification montré, le pont de Caspr absent d'une
page chargée (le script ne s'y est pas installé, rien ne l'y installera :
l'attendre serait attendre toujours). Le propriétaire, le
24 septembre 2026 : « Des fois ça prend dix, vingt, trente secondes, parce
que si je parle plusieurs minutes, ChatGPT prend beaucoup de temps. Donc non,
il n'y a pas de limite. » Une échéance a existé, sur la durée parlée, et un
délai de cinq secondes sur chaque appel au pont : ils jetaient des dictées
qui aboutissaient, sous « ChatGPT n'a pas répondu en 3 min ». En
contrepartie, la sortie est instantanée — l'annulation tranche l'attente même
quand un appel JavaScript ne revient jamais —, et la barre dit laquelle dès
dix secondes. Restent des **délais de geste**, qui prouvent l'effet d'un
geste de Caspr et non la lenteur de ChatGPT : le bouton micro qui existe dès
que la page s'est dite connectée, la page qui se met à écouter après son
clic — un micro que WebKit tenait déjà avant ce clic ne le prouve pas, seul
l'enregistrement le fait alors —, l'arrêt pendant l'écoute, la consigne qui se relit dans la zone, le
bouton d'envoi, le message qui quitte la zone après son clic — un clic sans
effet est un échec dit, pas une attente sans fin —, la copie qui atterrit
après le clic, « Lire à haute voix » sous une réponse finie. Ils sont tous
dans `RelaisDelai`, et il n'en existe aucun autre ; chaque appel qui en
passe un le dit dans un commentaire « délai de geste : … ». Dans le doute,
pas de délai : la réponse qu'on vient de copier, et que le texte attend pour
s'insérer après le clic de lecture, n'en a plus — la touche de dictée en
sort, et la barre le dit. Au repos, en revanche, un silence se constate
(`sonder`) : une page muette y est reconstruite — une vue neuve, la session
intacte —, parce qu'un rechargement ne débloque pas un fil JavaScript figé.

## Les règles tenues

**Ce qui est pur vit dans `CasprCore`, et y est testé.** La règle inverse —
rien n'y entrait — protégeait la possibilité de retirer le relais, abandonnée
depuis que ChatGPT est l'une des deux voies du produit. Ce qui décide des
modules proposés, et ce qui relit un calibrage, n'avait aucun test.

**La voie vit dans `Preferences`, et nulle part ailleurs.** Qui écoute le
micro est `Preferences.voie` (`caspr.voie`, un `VoieDeDictee`), relu à
chaque fois et figé au début de chaque dictée : basculer en pleine phrase
vaut pour la suivante. L'ancien interrupteur `relais.actif` n'est plus lu que
par la migration, qui en déduit la voie une fois, et il reste sur le disque.
Les autres réglages du relais vivent sous le préfixe `relais.`, lus depuis ce
dossier seulement.

**Rien n'existe tant que la voie n'est pas ChatGPT.** La `WKWebView` et la
session ChatGPT ne sont construites que sur cette voie, et détruites quand on
choisit macOS — à la fin de la dictée ChatGPT en cours s'il y en a une, qui va
au bout sur la page qu'elle a prise. Si cette dictée échoue en laissant son
texte dans la page, la fenêtre ouverte pour qu'on l'y copie survit à la fin
du cycle : la page part quand on la ferme, ou à l'appui de la dictée macOS
suivante, avant que le magnétophone n'écoute — en rendant alors le premier
plan que sa fenêtre tenait, sans quoi cette dictée s'écrirait chez Caspr
(`Relais.libererLaPageGardee`). Dans l'autre sens, choisir ChatGPT pendant
une dictée macOS ne construit la page qu'une fois le magnétophone arrêté
(`Relais.ecouteMacOS`) : née plus tôt, elle aurait réduit au silence le reste
de l'enregistrement. La calibration automatique que ce choix lance d'ordinaire
n'est alors pas relancée — l'arrêt précède la livraison au curseur, qu'elle
aurait privée de son premier plan : « Calibrer automatiquement… » se rallume à
l'arrêt, et la dictée suivante renvoie à Réglages › Voie tant qu'elle n'a pas
eu lieu.

**Les deux voies se rejoignent à la livraison, pas en amont.** Le relais s'est
d'abord conformé au protocole des moteurs de macOS, `SpeechEngine`, pour
hériter de l'insertion, de l'historique et des échecs. Il ne pouvait le faire
qu'en mentant : il recevait un enregistrement vide par construction, et
inventait une latence découpée en mel, encodeur et décodeur. Ce protocole a
disparu. Chaque voie a son chemin — `VoieApple`, `VoieChatGPT` —, et ils se
rejoignent dans `Livraison` : rendre le clavier, insérer au curseur ou en
note, archiver, garder de quoi reprendre un échec. Elle ne distingue les voies
qu'une fois, pour rendre le clavier, que seule une dictée ChatGPT a pu donner
à la fenêtre du relais. Les autres différences sont écrites là où elles se
produisent, et ce sont des différences réelles : aucun audio de notre côté,
donc pas de « Réessayer » ; une page à rendre et à préparer à la fin de
chaque dictée.

## Pourquoi une exclusion, et pas un moteur de plus

Les deux ne peuvent pas ouvrir le micro en même temps. Mesuré au niveau crête
de l'enregistrement : **0,072 avant tout usage du relais, 0,000 sur toutes les
dictées suivantes** dès qu'une page ChatGPT existe. La touche principale
répondait alors « rien n'a été entendu », sans que rien ne désigne le coupable.

D'où deux voies plutôt qu'une entrée de plus dans une liste de moteurs : les
proposer côte à côte laisserait croire qu'ils peuvent écouter ensemble. On ne
peut pas. La voie est un type à deux cas, `VoieDeDictee`, et un `switch` sans
`default` oblige à poser la question partout où elle se pose.

L'exclusion a une contrepartie heureuse : tant que la voie est ChatGPT, Caspr
ne touche jamais au micro, donc la page peut rester ouverte entre deux dictées
et le raccourci reste instantané.

## Ce qu'il ne fait délibérément pas

**Aucun aperçu en direct.** Il faudrait un second flux micro — celui-là même
qui casse tout. La barre le dit au lieu d'afficher une attente sans fin. Ce
que l'aperçu apporte à la voie macOS quand la passe finale échoue — un texte à
insérer malgré tout —, la voie ChatGPT le tient de sa transcription brute.

**Aucun banc d'essai.** Le relais n'accepte pas d'audio enregistré : la page
veut un micro en direct. Rejouer des dictées enregistrées contre ChatGPT
supposerait de les diffuser en temps réel : une heure de parole, une heure
d'horloge, pour une seule série.
