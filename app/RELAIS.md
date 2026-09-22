# ChatGPT Web Preview — mode d'emploi du retrait

Le relais fait dicter par le transcripteur de ChatGPT, dans une page web que
Caspr héberge. C'est une fonctionnalité **personnelle**, qui pilote un service
tiers par son interface web. Elle n'a pas sa place dans un produit vendu, et
elle a été écrite pour être retirée sans rien démonter.

## Retirer

```
rm -rf app/Sources/Caspr/Relais app/RELAIS.md relais
grep -rn "RELAIS —" app/Sources/Caspr
```

Le `grep` liste les points d'accroche restants — trois fichiers, une vingtaine
de lignes. Chacun est soit un bloc entier à supprimer, soit une condition dont
il faut garder la branche `else`. Puis `swift build` : ce qui aurait été oublié
ne compile plus.

## Les composants

Tout tient dans `app/Sources/Caspr/Relais/`, un fichier par responsabilité —
sauf les types sans dépendance système (modules, capacités, sorties, affichage,
structure des sélecteurs, modules livrés), rangés dans
`app/Sources/CasprCore/Relais/` pour être sous tests :

| Fichier | Responsabilité |
|---|---|
| `Relais.swift` | La façade et le cycle de vie. Contient aussi `RelaisEngine`, l'adaptateur vers `SpeechEngine`. |
| `RelaisPage.swift` | La `WKWebView`, ses **deux** fenêtres, le micro, les popups de connexion. |

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
| `RelaisPont.swift` | Le JavaScript injecté : cliquer, lire, vider, calibrer. |
| `RelaisSelecteurs+Persistance.swift` | La persistance des sélecteurs CSS appris ; leur structure et leur décodage vivent dans `CasprCore`. |
| `RelaisAttente.swift` | L'échéance **unique** d'une dictée, fixée à l'arrêt de l'écoute sur la durée parlée, et la phase en cours que la barre affiche. Toutes les attentes après l'arrêt la consomment ; aucune n'a plus son propre budget. |
| `RelaisCard.swift` | La bascule dans Réglages › Moteur IA. |
| `RelaisCatalogue.swift` | Les modules connus, fusionnés avec les réglages de l'utilisateur, et celui qui est retenu. |

### Les modes

Ce qui les sépare n'est pas la quantité de traitement, mais **le rôle que joue
la parole**.

| Mode | Ta voix est… | Envoyé à ChatGPT |
|---|---|---|
| **Brut** | le texte lui-même | rien |
| **Réorganiser** | la matière à remettre en ordre | oui |
| **Rédiger** | la commande d'un texte à produire | pas encore construit |

Les trois sont des façons d'**écrire** : ce qui sort est toujours le texte
qu'on voulait, jamais une réponse de conversation. Le screenshot n'est pas un
quatrième mode mais une option de « Rédiger », qui apparaîtra sur une pastille
à part quand ce mode existera.

La consigne se **dit**, elle ne se configure pas : « traduis ça en anglais » ne
tient pas dans un réglage. Caspr n'ajoute qu'un emballage, dont le seul rôle
est d'obtenir un résultat utilisable sans « Bien sûr ! Voici… » devant.

Chaque passe ouvre une **conversation neuve**, par rechargement de la page de
départ. Sans cela, la note précédente oriente la suivante — et le contexte
finirait par déborder. Cette page de départ est réglable : pointée sur un
projet ChatGPT dédié, elle y range toutes les conversations créées par Caspr,
à l'écart des vraies. C'est une URL et non un sélecteur, donc rien qui casse au
prochain remaniement de la page.

Une transformation qui échoue rend la **transcription brute**. Une dictée de
dix minutes ne se perd pas parce que la seconde passe n'a pas abouti.

## Les points d'accroche

- **`TranscriptionSettings.swift`** — une ligne.
  `RelaisCard { AppleEngineCard(target: .final) }` enveloppe la carte de
  macOS, dont elle décide l'affichage : les deux s'excluent à l'écran comme en
  fonctionnement.
- **`CasprApp.swift`** — la page est chargée au lancement quand le mode est
  actif, pour que la première dictée ne paie pas l'ouverture de chatgpt.com.
- **`UninstallWindow.swift`** — la session est effacée par l'API de WebKit
  avant le balayage des fichiers. C'est l'appelant qui attend, parce qu'il est
  dans un contexte qui le peut : le faire depuis le désinstalleur lui-même
  bloquerait le fil principal qu'attend l'effacement.
- **`Uninstall.swift`** — ramasse ce qui pourrait rester dans
  `~/Library/WebKit/<bundle>`, et **dit** dans la liste qu'une session ChatGPT
  est connectée. Sans cette mention, une case nommée « Réglages et historique »
  décidait en silence d'une session ouverte sur un service tiers.
- **`RecordingOverlay.swift`** — la pastille des modes accepte des libellés de
  rechange. Le relais n'a ni « Texte nettoyé » ni « Mot à mot », et le choix se
  fait au moment de parler, pas dans un écran de réglages. L'attente, elle,
  s'affiche avec sa phase et son chrono dès dix secondes, et la sortie par la
  touche de dictée (`showProcessing(_:progress:)`).
- **`DictationController.swift`** — l'essentiel : un drapeau posé au début du
  cycle, une branche qui n'ouvre pas le micro, une autre qui choisit
  `RelaisEngine` plutôt que le moteur configuré, et deux exclusions
  (gestionnaire de repli, réglages de barre sans objet).

## Quatre règles à ne jamais oublier

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

**Rien n'entre dans `Preferences`.** Les réglages du relais vivent dans
`UserDefaults` sous le préfixe `relais.`, lus depuis ce dossier seulement.

**Rien n'existe tant que ce n'est pas activé.** La `WKWebView` et la session
ChatGPT ne sont construites qu'à l'allumage de l'interrupteur, et détruites à
son extinction.

**Le relais se conforme à `SpeechEngine`.** `transcribeAndInject` ne sait pas
qu'il existe : l'insertion, l'historique, la barre, les échecs et le bouton
« Réessayer » fonctionnent sans une ligne écrite pour lui.

## Pourquoi une exclusion, et pas un moteur de plus

Les deux ne peuvent pas ouvrir le micro en même temps. Mesuré au niveau crête
de l'enregistrement : **0,072 avant tout usage du relais, 0,000 sur toutes les
dictées suivantes** dès qu'une page ChatGPT existe. La touche principale
répondait alors « rien n'a été entendu », sans que rien ne désigne le coupable.

D'où l'interrupteur plutôt qu'une entrée dans la liste des moteurs : proposer
les deux côte à côte laisserait croire qu'on passe de l'un à l'autre d'une
dictée sur l'autre. On ne peut pas.

L'exclusion a une contrepartie heureuse : tant que le relais est allumé, Caspr
ne touche jamais au micro, donc la page peut rester ouverte entre deux dictées
et le raccourci reste instantané.

## Ce qu'il ne fait délibérément pas

**Aucun apprentissage du repli.** `EngineSafetyManager` ne doit se souvenir que
de moteurs que l'utilisateur a réellement choisis.

**Aucun aperçu en direct.** Il faudrait un second flux micro — celui-là même
qui casse tout. La barre le dit au lieu d'afficher une attente sans fin.

**Aucun banc d'essai.** Le relais n'accepte pas d'audio enregistré : la page
veut un micro en direct. Rejouer des dictées enregistrées contre ChatGPT
supposerait de les diffuser en temps réel : une heure de parole, une heure
d'horloge, pour une seule série.
