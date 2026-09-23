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

## Les composants

Tout tient dans `app/Sources/Caspr/Relais/`, un fichier par responsabilité —
sauf les types sans dépendance système (modules, capacités, sorties, affichage,
structure des sélecteurs, modules livrés), rangés dans
`app/Sources/CasprCore/Relais/` pour être sous tests :

| Fichier | Responsabilité |
|---|---|
| `Relais.swift` | La façade et le cycle de vie. `apresLivraison` y tient la règle « la fin d'une dictée prépare la suivante ». |
| `RelaisPage.swift` | La `WKWebView`, ses **deux** fenêtres, le micro, les popups de connexion. |
| `RelaisPont.swift` | Le JavaScript injecté : cliquer, lire, vider, calibrer. |
| `RelaisSelecteurs+Persistance.swift` | La persistance des sélecteurs CSS appris ; leur structure et leur décodage vivent dans `CasprCore`. |
| `RelaisAttente.swift` | L'échéance **unique** d'une dictée, fixée à l'arrêt de l'écoute sur la durée parlée, et la phase en cours que la barre affiche. Toutes les attentes après l'arrêt la consomment ; aucune n'a plus son propre budget. |
| `RelaisCard.swift` | La bascule entre les deux voies, dans Réglages › Moteur IA, et ce que le relais a appris. |
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

## Où le relais touche le reste de l'application

Plus des accroches à défaire un jour : les endroits où la voie ChatGPT se
distingue de la voie macOS, et pourquoi.

- **`TranscriptionSettings.swift`** — une ligne.
  `RelaisCard { AppleEngineCard() }` enveloppe la carte de macOS, dont elle
  décide l'affichage : les deux voies s'excluent à l'écran comme en
  fonctionnement.
- **`CasprApp.swift`** — la page est chargée au lancement quand la voie est
  ChatGPT, pour que la première dictée ne paie pas l'ouverture de chatgpt.com.
- **`UninstallWindow.swift`** — la session est effacée par l'API de WebKit
  avant le balayage des fichiers. C'est l'appelant qui attend, parce qu'il est
  dans un contexte qui le peut : le faire depuis le désinstalleur lui-même
  bloquerait le fil principal qu'attend l'effacement.
- **`Uninstall.swift`** — ramasse ce qui pourrait rester dans
  `~/Library/WebKit/<bundle>`, et **dit** dans la liste qu'une session ChatGPT
  est connectée. Sans cette mention, une case nommée « Réglages et historique »
  décidait en silence d'une session ouverte sur un service tiers.
- **`RecordingOverlay.swift`** — la pastille des modules (`moduleLabels`,
  `onSelectModule`) : le choix se fait au moment de parler, pas dans un écran
  de réglages. L'attente, elle, s'affiche avec sa phase et son chrono dès dix
  secondes, et la sortie par la touche de dictée
  (`showProcessing(_:progress:)`).
- **`DictationController.swift`** — le cycle : la voie figée à l'appui
  (`voieDuCycle`), le numéro qui dit si un cycle est encore le sien, l'état,
  Échap, et l'abandon par la touche de dictée. Ce qui se passe sur chaque voie
  vit dans son fichier.
- **`VoieChatGPT.swift`** — le chemin de la voie ChatGPT : prendre la page,
  attendre qu'elle écoute sans ouvrir le micro de Caspr, puis arrêter et lire,
  transformer, ouvrir la discussion ou livrer, laisser le texte dans la page
  quand ça échoue. Aucun audio à conserver, donc pas de « Réessayer ». Le
  pendant de `VoieApple.swift`, qui ne partage avec elle que la livraison.
- **`DicteeEnCours.swift`** — le module et la destination, figés à l'arrêt de
  l'écoute et portés jusqu'à la livraison : `RelaisCatalogue.courant` relit
  les préférences à chaque accès, et l'aller-retour ChatGPT sépare les
  lectures de plusieurs minutes.
- **`Livraison.swift`** — la queue commune aux deux voies : insérer au curseur
  ou dans les notes, l'historique. Et le retour à l'application où l'on
  parlait, capturée à l'appui : il vaut pour les deux voies, mais c'est pour
  ChatGPT qu'il compte, parce que trente secondes à trois minutes séparent la
  parole de l'insertion.
- **`SetupRecoveryGuard.swift`** — le socle minimal de la voie ChatGPT : le
  raccourci, et une page connectée et calibrée. Rien sur macOS.

## Cinq règles à ne jamais oublier

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

Tout champ ajouté à `RelaisSelecteurs` **doit** être décodé avec
`decodeIfPresent`. Le décodage synthétisé par Swift échoue sur une clé absente
— il n'utilise pas les valeurs par défaut des propriétés — et une structure
enrichie rend d'un coup illisibles tous les calibrages déjà enregistrés. La
sanction n'est pas une erreur visible : c'est un réglage effacé chez chaque
utilisateur à la mise à jour, et un écran qui annonce « configuration
inachevée » à qui vient de la terminer. C'est arrivé en 0.13.0.

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
au bout sur la page qu'elle a prise. Dans l'autre sens, choisir ChatGPT pendant
une dictée macOS ne construit la page — ni ne lance la calibration — qu'une fois
le magnétophone arrêté (`Relais.ecouteMacOS`) : née plus tôt, elle aurait
réduit au silence le reste de l'enregistrement.

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
qui casse tout. La barre le dit au lieu d'afficher une attente sans fin.

**Aucun banc d'essai.** Le relais n'accepte pas d'audio enregistré : la page
veut un micro en direct. Rejouer des dictées enregistrées contre ChatGPT
supposerait de les diffuser en temps réel : une heure de parole, une heure
d'horloge, pour une seule série.
