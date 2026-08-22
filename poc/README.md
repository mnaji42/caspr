# Éprouver un moteur de reconnaissance vocale

Ce dossier contient l'outillage qui a servi à comparer cinq moteurs sur le
corpus réel de dictées, en août 2026. Il est là pour être **rejoué** : le jour
où un moteur candidat se présente, la question « est-il meilleur ? » a une
méthode, des instruments et des chiffres de référence.

L'application, elle, n'utilise que **macOS** et **CrisperWhisper**. Ce qui a été
essayé et écarté vit dans l'historique git, pas dans le code.

---

## Ce qui a été mesuré, et ce qui en est ressorti

Cinq moteurs, 170 dictées communes, rejouées à code figé, un seul modèle chargé
à la fois, mémoire libre. Sur un M4 Pro 48 Go, macOS 26.6.

| Moteur | Latence méd. | Phrase moy. | Fragments | Bafouillages | Disque | RAM (pic Metal) |
|---|---|---|---|---|---|---|
| **macOS Apple Intelligence** | **0,28 s** | 26,7 | 0,10 | 0,83 | **0** | négligeable |
| CrisperWhisper turbo, sans lexique | 1,15 s | 17,6 | 0,19 | 0,26 | 2,5 Go | 2,3 Go |
| CrisperWhisper turbo, lexique par défaut | 1,37 s | 16,0 | 0,25 | 0,43 | 2,5 Go | 2,3 Go |
| Voxtral 3B (MLX bf16) | 6,41 s | **19,4** | **0,07** | **0,17** | 9,7 Go | 10,9 Go |
| Voxtral Realtime 4B (MLX 4-bit, flux) | 17,61 s | 16,4 | 0,11 | 0,35 | 3,9 Go | 5,5 Go |

« Fragments » et « bafouillages » sont comptés pour cent mots — voir
`french_quality.py` pour ce que ces mots recouvrent.

### Les cinq conclusions qui ont compté

**1. Le lexique par défaut coûte plus qu'il ne rapporte.** `DEFAULT_LEXICON`,
dix-neuf termes codés dans `crisper.py`, s'applique dès que l'application passe
`nil` — c'est-à-dire en permanence tant qu'aucun terme n'a été ajouté à la main.
Rejoué sans lui sur 173 dictées : moins de fragments, moins de bafouillages,
phrases plus longues, et **zéro fuite** contre quatre. Il ne dégrade pas la
phrase, il la remplace : « Effect the button functions. » pour « Ça ne
fonctionne plus du tout, je sais pas pourquoi. »

Le plus contre-intuitif tient à la casse : « Whisper », qui **ne figure pas**
dans le lexique, est écrit correctement 51 fois sans lui et 12 fois avec. Le
prompt perturbe la casse au-delà de ses propres termes.

Ce que ça ne dit pas : que le conditionnement lexical soit inutile. Les 94 % de
termes préservés annoncés dans le README ont été mesurés sur huit clips choisis,
avec un lexique adapté à eux. Ce qui est mesuré ici, c'est qu'un lexique **par
défaut**, que personne n'a choisi, coûte plus qu'il ne rapporte sur de la parole
réelle.

**2. La pression mémoire fausse les mesures.** Une première série a tourné avec
9 Go de swap actif : CrisperWhisper y était à 1,52 s de latence médiane, contre
**1,25 s** au propre. Dix-huit pour cent d'écart, assez pour invalider toute
comparaison. Tout banc doit relever la pression mémoire avant et après —
`bench_all.py` le fait.

**3. L'accord mot à mot ne mesure pas la qualité d'écriture.** Deux
transcriptions peuvent s'accorder à 0,94 et l'une être lisible, l'autre hachée :
la ponctuation ne pèse presque rien dans une comparaison de mots. D'où
`french_quality.py`, qui compte des défauts nommables — points suivis d'une
minuscule, fragments de trois mots coincés entre deux phrases longues, mots
répétés d'affilée, apostrophes droites et courbes mélangées.

**4. macOS fait déjà beaucoup plus qu'on ne croyait.** Voir `apple/`. Le modèle
de langage du système rédige, range des notes dans le bon fichier, et lit une
capture d'écran via Vision. Sans rien télécharger, sans mémoire résidente.

**5. Le temps réel coûte trop cher en qualité.** Le Realtime 4B perd 9 % des
mots — le seul des cinq à en perdre — parce que son encodeur est causal : il
décide sans pouvoir revenir en arrière. Il est aussi le plus lent en lot et
sature le GPU à 91 %.

---

## Comment refaire tourner tout ça

### Les bancs

```bash
# CrisperWhisper, tel que l'application l'utilise
engine/.venv/bin/python poc/bench_all.py crisper

# Le même, lexique désactivé — la comparaison la plus rentable
engine/.venv/bin/python poc/bench_crisper_nolex.py

# macOS : seule l'application peut le mesurer, cf. plus bas
osascript -e 'quit app "Caspr"'
open -a /Applications/Caspr.app --args --bench-corpus \
     "$PWD/poc/mesures/run-macos.json"
```

### La lecture

```bash
engine/.venv/bin/python poc/compare_runs.py      # le tableau comparatif
engine/.venv/bin/python poc/report_engines.py    # la page HTML côte à côte
engine/.venv/bin/python poc/export_bench.py      # un JSON unique, partageable
```

`report_engines.py` produit une page où l'on coche les moteurs à afficher — de
deux à six colonnes, en 2×2 au-delà de quatre — avec les mots divergents
surlignés et un bouton pour **écouter** la dictée d'origine.

### Où atterrissent les sorties

Tout dans `poc/mesures/`, **entièrement gitignoré**. Le dépôt est public et ces
fichiers contiennent la parole de quelqu'un, mot pour mot. Les scripts sont
versionnés ; leurs sorties, jamais.

---

## Ce qu'il faut savoir avant d'ajouter un moteur

Ces points ont tous coûté du temps à découvrir. Les relire évitera de les
repayer.

### Le corpus n'a pas de vérité terrain

Ces dictées n'ont jamais été retranscrites à la main. **Un WER n'est pas
calculable.** Fabriquer une référence à partir d'un moteur reviendrait à le
sacrer juge de ses concurrents. On ne peut que comparer les moteurs entre eux,
et lire.

### `sessions.jsonl` n'est pas un banc

Le corpus de l'application porte ce qui a été **inséré** au fil des mois, par
des moteurs d'alors, sous des versions d'alors. Les `run-*.json` portent le
corpus **rejoué**. Confondre les deux mène à des conclusions fausses — c'est
arrivé.

### Le RSS ment sur Apple Silicon

Le service CrisperWhisper affiche 0,11 Go de RSS avec 1,5 Go de poids chargés :
la mémoire unifiée les range côté Metal. Relever trois compteurs — RSS, mémoire
allouée par le pilote, empreinte physique. `measure_cost.py` le fait.

### Tout passe par le GPU, jamais par le Neural Engine

MLX comme PyTorch/MPS ciblent Metal. L'ANE demanderait CoreML, donc reconvertir
le modèle. Et il n'est pas instrumentable sans root : `powermetrics --samplers
ane` exige un mot de passe. Le GPU, lui, se lit dans `ioreg`.

### Les moteurs de macOS ne se mesurent que depuis l'application

Le framework Speech exige l'autorisation de reconnaissance vocale, et TCC
l'accorde à une **identité de code** — celle de Caspr, pas celle d'un binaire
d'essai. D'où `--bench-corpus` dans l'application elle-même
(`app/Sources/Caspr/CorpusBatch.swift`). Trois pièges s'y sont succédé :

- faire tourner `RunLoop.current` depuis l'acteur principal tout en y planifiant
  une tâche est un interblocage — c'est AppKit qui doit piloter la boucle ;
- `print` vers un tube reste en tampon, et on croit le banc bloqué alors qu'il
  travaille (`setvbuf`) ;
- `open -a` ne transmet pas `--args` à une application **déjà lancée** : il faut
  la quitter d'abord.

`SFSpeechRecognizer` — le moteur de la Dictée — reste hors banc : lancé depuis
ce mode il fait planter le process sur une vérification TCC réclamant
`NSSpeechRecognitionUsageDescription`, alors que la clé est bien présente et que
le moteur fonctionne dans le parcours normal. Il avale 40 % des mots de toute
façon.

### La couture du projet tient

Le protocole app ↔ moteur ne nomme aucun modèle : il envoie du PCM et un mode,
il reçoit du texte. Un moteur entièrement différent a été branché derrière
pendant cette session **sans toucher une ligne de Swift**. C'est la propriété la
plus utile du projet pour qui voudra en essayer un autre.

Deux préparations l'ont rendue possible et méritent d'être conservées :

- `engine/caspr_engine/contract.py` — `Transcription`, `Timings` et
  `SAMPLE_RATE` sortis de `crisper.py`, qui importe `torch` en tête de fichier.
  Sans ça, faire tourner un moteur sur un autre runtime obligeait à installer
  PyTorch pour rien.
- `EngineChoice` dans `CasprCore`, avec ses capacités écrites en `switch`
  exhaustifs — `isSystem`, `isLocalService`, `hasModes`, `honoursLexicon`.
  Ajouter un cas force le compilateur à poser la question partout, au lieu de
  laisser un nouveau moteur hériter en silence des règles écrites pour un autre.
  Vérifié en ajoutant un cinquième cas puis en le retirant : **quatorze `switch`**
  deviennent non exhaustifs, et le test « la liste des moteurs système
  correspond à la capacité » attrape ce qu'un `switch` complété sans réfléchir
  laisserait passer.

---

## Les fichiers

| Fichier | Rôle |
|---|---|
| `bench_all.py` | Rejoue le corpus, un moteur à la fois, avec relevé mémoire |
| `bench_crisper.py` | CrisperWhisper seul, les deux modes |
| `bench_crisper_nolex.py` | Le même, `hotwords=[]` — mesure ce que coûte le lexique |
| `bench_voxtral.py` | Un moteur externe, incrémental (gardé comme gabarit) |
| `probe_voxtral.py` | Éprouve les consignes d'un modèle qui en accepte |
| `measure_cost.py` | Disque, RSS, Metal, CPU, GPU |
| `engine_stats.py` | Décrochages, termes techniques, similarité |
| `french_quality.py` | Les défauts nommables du texte français |
| `compare_runs.py` | Le tableau comparatif |
| `report_engines.py` | La page HTML côte à côte, audio compris |
| `export_bench.py` | Un JSON unique, à donner à quelqu'un d'autre |
| `apple/` | Ce que macOS 26 sait déjà faire, éprouvé |
| `mesures/` | Les sorties. **Gitignoré.** |
