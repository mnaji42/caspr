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

Tout tient dans `app/Sources/Caspr/Relais/`, un fichier par responsabilité :

| Fichier | Responsabilité |
|---|---|
| `Relais.swift` | La façade et le cycle de vie. Contient aussi `RelaisEngine`, l'adaptateur vers `SpeechEngine`. |
| `RelaisPage.swift` | La `WKWebView`, ses **deux** fenêtres, le micro, les popups de connexion. |

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
| `RelaisSelecteurs.swift` | Les sélecteurs CSS appris, et leur persistance. |
| `RelaisCard.swift` | La bascule dans Réglages › Moteur IA. |
| `RelaisMode.swift` | Les modes de dictée et l'emballage des prompts. |

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

Une transformation qui échoue rend la **transcription brute**. Une dictée de
dix minutes ne se perd pas parce que la seconde passe n'a pas abouti.

## Les points d'accroche

- **`TranscriptionSettings.swift`** — une ligne. `RelaisCard { FinalEngineCard() }`
  enveloppe la liste des moteurs, dont la carte décide l'affichage : les deux
  s'excluent à l'écran comme en fonctionnement. Retrait : remplacer par
  `FinalEngineCard()`.
- **`Preferences.swift`** — `needsLocalEngine` rend `false` quand le relais est
  actif. Corrigé là plutôt qu'aux trois endroits qui appellent
  `EngineService.reconcile`, où un oubli aurait remis le modèle en mémoire pour
  un moteur devenu inatteignable.
- **`EngineStartupNotice.swift`** — le bandeau « CrisperWhisper démarre… » ne
  s'affiche pas : le service n'étant pas lancé, il annoncerait une attente qui
  ne finit jamais.
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
  fait au moment de parler, pas dans un écran de réglages.
- **`DictationController.swift`** — l'essentiel : un drapeau posé au début du
  cycle, une branche qui n'ouvre pas le micro, une autre qui choisit
  `RelaisEngine` plutôt que le moteur configuré, et trois exclusions (collecte,
  gestionnaire de repli, réglages de barre sans objet).

## Une règle à ne jamais oublier

Tout champ ajouté à `RelaisSelecteurs` **doit** être décodé avec
`decodeIfPresent`. Le décodage synthétisé par Swift échoue sur une clé absente
— il n'utilise pas les valeurs par défaut des propriétés — et une structure
enrichie rend d'un coup illisibles tous les calibrages déjà enregistrés. La
sanction n'est pas une erreur visible : c'est un réglage effacé chez chaque
utilisateur à la mise à jour, et un écran qui annonce « configuration
inachevée » à qui vient de la terminer. C'est arrivé en 0.13.0.

## Les règles tenues

**Rien n'entre dans `CasprCore`.** Un cas `.relais` dans `EngineChoice` aurait
obligé à le traiter dans les réglages, `EngineSafetyManager`, le corpus, les
statistiques, les recommandations — et à défaire tout cela ensuite.

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

**Aucune collecte.** Le corpus sert à arbitrer des moteurs mesurables sur les
mêmes dictées ; un service tiers dont on ignore le modèle et la version y
fausserait les comparaisons.

**Aucun apprentissage du repli.** `EngineSafetyManager` ne doit se souvenir que
de moteurs que l'utilisateur a réellement choisis.

**Aucun aperçu en direct.** Il faudrait un second flux micro — celui-là même
qui casse tout. La barre le dit au lieu d'afficher une attente sans fin.

**Aucun banc d'essai.** Le relais n'accepte pas d'audio enregistré : la page
veut un micro en direct. Rejouer les 129 dictées du corpus contre ChatGPT
supposerait de les diffuser en temps réel, soit deux heures d'horloge pour une
seule série.
