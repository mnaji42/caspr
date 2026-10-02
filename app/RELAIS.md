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

## Les composants, en quatre couches

Une couche ne s'appuie que sur celle d'en dessous. Ce qui **décide** est pur
et vit dans `CasprCore`, sous Swift Testing ; ce qui touche WebKit ne décide
rien ; la vie de la page — quand elle naît, se prépare, meurt — est à part de
la dictée qui s'en sert ; et la dictée elle-même est une voie, à côté de la
voie macOS.

### 1. `CasprCore/Relais` — ce qui décide, pur et testé

| Fichier | Contenu |
|---|---|
| `RelaisCycle.swift` | La machine d'une dictée, en table : ses phases (`RelaisPhase`), leur libellé et la sortie que la barre dit avec le chrono, ce que valent la touche de dictée et la croix à chacune (`RelaisCycle.decider`), et quel échec de la page mène au repli (`RelaisCycle.replie`). Aucune ligne ne vient de l'horloge. |
| `RelaisDictee.swift` | Le scénario d'une dictée — ouvrir l'écoute, arrêter et lire, encadrer et envoyer, copier la réponse, la faire lire, arrêter la page après un abandon — écrit sur ce qu'il demande à la page (`RelaisPageDictee`) et au presse-papiers (`RelaisPressePapiers`). Il se rejoue en test contre une page factice et une horloge qu'on avance à la main : cinq minutes de ChatGPT y passent en un instant. Toutes ses attentes de la page passent par `observer`, posée sur la primitive du relais. `RelaisPreparation` y décide ce que la fin d'une dictée fait de la page. |
| `RelaisObservation.swift` | Le temps du relais : l'horloge et **la** boucle d'attente, `guetter`, par où passent toutes les attentes ; `RelaisDelai` — la liste, et la seule, des délais de geste —, et `AppelAnnulable`, l'appel dont on cesse d'attendre la réponse à l'instant où l'on renonce. |
| `RelaisInstantane.swift` | Ce que la page dit en un seul aller-retour (`RelaisInstantane`), ce qu'on lui demande (`RelaisDemande`), et la marque relevée avant une demande (`RelaisMarque`). Chaque champ du relevé absent ou nul prend sa valeur par défaut, par son type (`ParDefaut`). |
| `RelaisVeille.swift` | Les jugements portés sur un instantané : la session, la transcription qui se stabilise, la réponse finie, le refus, l'empreinte de la consigne. |
| `RelaisRepli.swift` | Ce qu'on livre quand on renonce à ChatGPT ou qu'il échoue — le brut, le son transcrit par macOS, l'aperçu, rien — et ce que la barre en dit ; si une zone revenue vide portait pourtant une voix (`parole`). |
| `RelaisErreur.swift` | Ce qui peut échouer, et comment la barre et le menu le disent. |
| `RelaisScripts.swift` | Tout le JavaScript injecté : le pont (calibration comprise) et l'écho. En chaînes Swift pour que les tests l'atteignent : une faute de syntaxe casse `swift test` au lieu de laisser une page sans pont, qu'aucune échéance ne viendrait plus dénoncer. |
| `RelaisSelecteurs.swift` | Les repères appris, et leur relecture (`decodeIfPresent` sur chaque champ). |
| `RelaisModule.swift`, `RelaisCapacite.swift`, `RelaisAffichage.swift` | Un module (son envoi, sa consigne, son affichage, sa lecture), ce qu'il exige, comment il se montre. |
| `RelaisCatalogue.swift` | Les modules livrés, leur fusion avec ceux qu'on a rangés, celui qui est retenu, la création et la suppression, les formes d'avant, et la relecture de ce qui est rangé sous `relais.*`. |
| `RelaisPreuves.swift`, `RelaisEtape.swift` | Ce que la calibration automatique doit avoir prouvé avant d'écrire ; le parcours manuel, décrit en données. |

### 2. `Caspr/Relais` — la page : WebKit, sans décision

| Fichier | Contenu |
|---|---|
| `RelaisPage.swift` | La `WKWebView`, sa configuration et ses scripts, le chargement, l'**époque** (+1 à chaque mort du processus), le micro (rendu en une seconde au plus), `detruire()`, qui rend les appels en suspens et retire le gestionnaire de l'écho, le point de départ. Au premier montage de chaque lancement, elle vide le cache disque de WebKit — jamais les cookies ni le stockage de la page, qui portent la session. |
| `RelaisPage+Pont.swift` | La façade du pont : un seul point d'appel, `pont(fonction, args…)`, qui décode le JSON que rend la page, et une méthode typée par fonction. C'est la vraie `RelaisPageDictee`. Sans délai sur le chemin d'une dictée ; `sonder` et `auPlus`, bornés, **au repos seulement**. |
| `RelaisPage+Navigation.swift` | Les délégués WebKit : le micro accordé à chatgpt.com et openai.com seulement, les popups de connexion dans un panneau qui partage la session, les navigations échouées, le processus tué. |
| `RelaisFenetres.swift` | Les **deux** fenêtres, et la vue web qui passe de l'une à l'autre (cf. « Les deux fenêtres »). |
| `RelaisEcho.swift` | L'écho côté Swift : la copie du son que la page capte, reçue en mémoire vive (cf. « L'écho »). |

### 3. `Caspr/Relais` — la vie de la page

| Fichier | Contenu |
|---|---|
| `Relais.swift` | La façade : la page n'existe que sur la voie ChatGPT ; l'occupation, **dérivée** de deux faits (une dictée a la page, une calibration l'a) ; la session vue ; la page au repos (`Repos`) et la discussion ; le premier plan rendu ; `finirLeCycle`, la seule sortie d'une dictée, qui prépare la suivante ; la reconstruction d'une page muette. |
| `RelaisCalibration.swift` | Un seul cycle de vie pour les deux parcours de la calibration : les gardes, la discussion et la préparation oubliées au départ, et à **toute** sortie — fin, abandon, fenêtre fermée, passage à macOS — l'occupation rendue, la page rangée et la dictée suivante préparée, sous un numéro qui empêche un parcours abandonné de rendre la main d'un autre. |
| `RelaisCalibrationAuto.swift` | Le parcours automatique : essayer les boutons, ne retenir que ceux dont l'effet se voit. Il rend des preuves ; c'est `RelaisCalibration` qui enregistre. |
| `RelaisDialogues.swift` | Ce que le relais dit dans une alerte : les consignes et le rapport de la calibration, le diagnostic. |
| `RelaisMagasin.swift` | Ce que le relais a appris et ce qu'on en a réglé — sélecteurs, modules, module choisi, point de départ —, en mémoire et publié : les écrans l'observent au lieu de se relire. Écrit sous les clés `relais.*` de toujours. |
| `RelaisReglages.swift`, `RelaisModuleCard.swift` | Les réglages de la voie ChatGPT ; créer, régler et supprimer un module. La carte de session (`RelaisSession`) est aussi celle de l'accueil. |

### 4. `Caspr/Dictee` — la voie

| Fichier | Contenu |
|---|---|
| `VoieChatGPT.swift` | La machine en marche : la phase, écrite par `entrer` seulement ; une tâche, `moteur`, qui déroule tout de l'appui à la livraison ; un numéro, `generation`, vérifié après chaque attente ; `geste`, qui décide sur-le-champ par la table de `RelaisCycle` ; le repli et l'aperçu. Le pendant de `VoieApple.swift`. |
| `DictationController.swift` | L'état commun (projeté par la machine sur la voie ChatGPT), la voie figée à l'appui, l'application visée, le cycle macOS, Échap, les recours du menu, et le seul anti-rebond (0,4 s) de tous les déclencheurs. `toggle()` et `cancel()` passent le geste à la voie. |
| `ApercuEnDirect.swift` | L'aperçu par le moteur de macOS, nourri par le micro de Caspr ou par l'écho de la page. |
| `Livraison.swift` | La queue commune aux deux voies : rendre le clavier, ramener l'application de l'appui, insérer au curseur ou en note, archiver, garder de quoi reprendre un échec. |
| `PressePapiers.swift` | Le presse-papiers sauvegardé tout entier et rendu tel quel — par l'insertion, la copie de la réponse et la calibration. |

## La machine d'une dictée

```
             touche ou croix : annuler le démarrage
             ┌──────────┐
repos ──► demarrage ──► ecoute ──► transcription ──► envoi ──► reponse ──► lecture ──► livraison ──► repos
             │ échec       │ touche : arrêter       │ touche : replier (le brut s'il est lu, sinon le son)
             ▼ prouvé      │ croix, Échap : annuler │ croix : annuler      lecture : touche = cesser d'attendre
           échouer         └─ échec prouvé : replier┘                      livraison : touche ou croix = annuler
```

| Phase | Touche de dictée | Croix (et Échap pendant l'écoute) | Échec prouvé par la page |
|---|---|---|---|
| `demarrage` | annuler le démarrage | annuler le démarrage | échouer |
| `ecoute` | arrêter | annuler | replier |
| `transcription` | replier : le son transcrit par macOS | annuler | replier |
| `envoi`, `reponse` | replier : le brut | annuler | le brut, avec la raison |
| `lecture` | cesser d'attendre : le texte s'insère, ou la discussion s'ouvre | annuler | continuer, avec un avertissement |
| `livraison` | annuler : rien n'est activé ni écrit | annuler | — |

- **Annuler** : rien n'est inséré ; le meilleur texte déjà en main (la
  réponse, sinon le brut, sinon l'aperçu) et le son de la page vont au menu,
  sans message.
- **Replier** : cf. « Le repli ».
- **Aucune transition ne vient de l'horloge.** Le chrono de la barre — depuis
  l'appui, puis depuis l'arrêt — n'est qu'un affichage.
- `entrer` est le seul point d'écriture de la phase : il journalise « a → b
  après x s », projette l'état du contrôleur, publie le fait « une dictée a la
  page » (d'où l'occupation), met la barre à jour et règle Échap.
- Une seule tâche, `moteur`, et un numéro, `generation`, vérifié après chaque
  `await` : un effet tardif d'un cycle abandonné — un clic, une insertion,
  une préparation — ne touche plus rien, et deux appuis dans le même tour ne
  font qu'un arrêt. La lecture à haute voix est la seule tâche fille : c'est
  elle, et elle seule, que la touche fait taire en phase `lecture`.

Tenu par `RelaisCycleTests` (la table entière, le repli tant que le brut
n'est pas lu, le libellé et la sortie de chaque attente).

## L'attente unique

```swift
// RelaisObservation : la seule boucle d'attente du relais
func guetter<T>(toutes pas: Duration = .milliseconds(250), auPlus borne: Duration? = nil,
                _ juger: () async throws -> T?) async throws -> T?
// RelaisDictee, privée : la même, avec les preuves d'une page qu'on attend
func observer<T>(_ demande: RelaisDemande, delai: RelaisDelai? = nil,
                 _ juger: (RelaisInstantane) async throws -> T?) async throws -> T
```

Toutes les attentes du relais passent par `RelaisHorloge.guetter` : juger,
rendre la valeur s'il y en a une, rendre `nil` passé la borne s'il y en a une,
dormir un pas — annulable à chaque pas et pendant le sommeil. Sans borne,
seule une valeur ou une erreur en sort. La dictée l'appelle par `observer`,
la page au repos et la calibration par `RelaisPage.observer(auPlus:)`,
l'appui qui attend la préparation et le premier plan rendu avant l'insertion
directement. Une seule attente reste à part, et pour une raison : celle de la
copie dans le presse-papiers, qui ne regarde pas la page et doit survivre une
seconde à l'annulation pour défaire une copie déjà partie.

Sur le chemin d'une dictée, `observer` : un instantané par quart de seconde,
jusqu'à ce que `juger` rende une valeur.
**Aucune échéance.** Avant de juger, les échecs que la page prouve : sa mort
depuis l'ouverture de l'écoute (l'époque a changé), l'écran
d'authentification, et — un tour sur quatre, parce que les chercher coûte à
la page qu'on attend de voir avancer — une alerte de refus apparue depuis la
marque. Rien n'est demandé pendant un chargement ; un relevé qui échoue ne dit
rien, et l'on passe au suivant. Annulée, elle rend la main dans l'instant,
même si l'appel en cours ne revient jamais : `AppelAnnulable` fait courir la
réponse contre l'annulation, sans minuteur.

`delai:` ne sert qu'à prouver l'**effet d'un geste** de Caspr, et chaque
appel qui en passe un le dit dans un commentaire. Voici la liste entière,
`RelaisDelai` ; il n'en existe aucune autre sur le chemin d'une dictée :

| Délai | Durée | Ce qu'il prouve | Pourquoi il reste | Dépassé |
|---|---|---|---|---|
| `micro` | 8 s | le bouton micro existe | la page s'est dite connectée : un bouton qui ne vient pas est un repère faux, pas un ChatGPT lent | `introuvable(.micro)` |
| `ecoute` | 5 s | après le clic, la page capte | un clic qui n'a pas pris ; un micro que WebKit tenait déjà avant ne le prouve pas, seul l'enregistrement le fait alors | `ecouteNonOuverte` |
| `arret` | 15 s | le bouton d'arrêt existe pendant l'écoute | un repère, pas une réponse | `introuvable(.stop)` |
| `consigne` | 6 s | la consigne écrite se relit dans la zone | ce qu'on écrit se relit aussitôt, ou n'a pas pris | `consigneNonPosee` |
| `envoi` | 10 s | le bouton d'envoi existe, la zone remplie | un repère | `introuvable(.envoi)` |
| `depart` | 10 s | après le clic, le message a quitté la zone, ou une réponse commence | ChatGPT vide la zone à l'instant du clic, sans attendre le réseau : un clic sans effet est un échec dit, pas une attente sans fin | `envoiSansEffet` |
| `copie` | 10 s | le presse-papiers change après le clic « copier » | la réponse est finie quand on clique : la copie atterrit dans l'instant | `pasDeReponse` |
| `lecture` | 5 s | « Lire à haute voix » paraît sous une réponse finie | la barre d'actions suit de peu la fin de la génération | avertissement |
| `ecouteApresAbandon`, `arretApresAbandon` | 3 s, 5 s | abandonnée juste après le clic du micro, la page qui se met à écouter est arrêtée | l'utilisateur est déjà sorti ; ChatGPT ne doit jamais écouter hors champ | — |

Hors de la liste, des durées qui ne mettent fin à aucune attente : la pause
qui laisse s'ouvrir le menu de la lecture à haute voix, la seconde qu'un
abandon accorde à une copie déjà partie pour rendre le presse-papiers, et la
seconde du retour au premier plan (`Relais.seRetirer`, `Livraison.ramener`),
délais de geste eux aussi.

Tenu par `RelaisDicteeTests` (cinq minutes de transcription attendues sans
erreur ; un relevé qui ne revient jamais, abandonné en moins de 200 ms ; la
réponse la plus longue attendue sans fin ; chaque délai de geste) et
`AppelAnnulableTests`.

## La page au repos

C'est **la fin d'une dictée qui prépare la suivante** (`finirLeCycle`, puis
`preparerLaProchaine`). La décision est pure,
`RelaisPreparation.decision(enDiscussion:page:)`, et porte sur ce qu'est la
page au repos :

| La page | Ce qu'on en fait |
|---|---|
| répond, en discussion | on garde le fil |
| répond, et porte une conversation (`/c/<id>`, `/g/<projet>/c/<id>`) | conversation neuve : la page de départ est rechargée |
| répond, sans conversation | la zone est vidée, le brouillon oublié |
| se charge | on attend ce chargement, au lieu de recharger par-dessus |
| est morte, son rechargement retenu | on la recharge |
| ne répond pas | on la **reconstruit** |

Une page **morte** — WebKit a tué son processus — se recharge tout de suite,
sauf si elle meurt encore dans les cinq minutes : elle reste alors morte, et
revit au premier appel au pont. Une page **muette** — un fil JavaScript
bloqué — ne se recharge pas : `reload()` et `load()` n'y aboutissent jamais
(mesuré). On la remplace par une vue neuve, qui charge en une fraction de
seconde avec la session intacte ; l'ancienne est détruite, ses appels en
suspens rendus, son micro rendu en une seconde au plus.

Au repos, et là seulement, un silence se constate : chaque étape de la
préparation est bornée (`sonder`, cinq secondes ; un chargement, trente),
parce que l'appui l'attend avant même d'ouvrir l'écoute. Cet appui, lui,
n'attend pas sans issue : la barre dit « ChatGPT se prépare… » et, d'emblée,
le chrono et comment en sortir — les autres phases attendent dix secondes
pour le dire —, la touche interrompt l'attente sur-le-champ, et la préparation
continue pour l'appui suivant. Une zone qui refuse de se vider sur une page
qui répond n'est pas une page à jeter : c'est souvent une transcription
encore en cours, et l'ouverture de l'écoute vide la zone de toute façon.

Tenu par `RelaisDicteeTests` (« La préparation de la dictée suivante, cas par
cas »).

## Le pont

- **Le JavaScript vit dans `CasprCore`** (`RelaisScripts`), sous tests :
  chaque script passe `JSCheckScriptSyntax`, ses règles pures s'évaluent dans
  JavaScriptCore, et un test vérifie que le pont expose exactement les
  fonctions que la façade appelle (`RelaisScripts.Fonction`).
- **Un monde à lui** : `WKContentWorld.world(name: "caspr")`, une constante
  (`RelaisPage.monde`). Le pont y agit sur le DOM de chatgpt.com, mais
  `window.__relais` y est invisible et intouchable pour la page — éprouvé
  fonction par fonction contre le monde de la page, mêmes résultats. Revenir
  au monde de la page tient en une ligne. Seul l'écho tourne aussi dans le
  monde de la page, parce qu'il doit envelopper `getUserMedia`.
- **Un seul point d'appel**, `pont<T>(fonction, args…)` : le nom et les
  arguments passent en arguments, jamais dans le corps — aucun texte dicté
  n'est interprété comme du code. Un pont absent d'une page **chargée** — ni
  `charger()` en cours, ni `isLoading`, qui couvre « Recharger » et les
  redirections — est un échec prouvé (`pontAbsent`) : rien ne l'y installera.
- **Un seul relevé par tour.** `marquer()` relève ce qui est déjà là — les
  alertes et échecs affichés, le nombre de réponses —, et Caspr garde la
  marque (`RelaisPage.marque`), qu'un rechargement de la page n'efface donc
  pas. `instantane` rend en un aller-retour la conversation,
  l'authentification, la zone de saisie et son texte, le micro, l'arrêt,
  l'enregistrement, et sur demande la réponse nouvelle (`nouvelles`,
  `enCours`, `longueur`, `copierPret`) et le premier échec apparu depuis la
  marque.
- **Sans forcer la mise en page** : la longueur d'une réponse se lit par
  `textContent`, son texte par `innerText` une seule fois, à la fin ; les
  invites de connexion se cherchent par des sélecteurs, jamais dans les
  messages ; un échec écrit, par un parcours qui saute les messages et la zone
  de saisie.

## L'écho

Un seul micro : celui de la page. Le micro que Caspr ouvrirait pendant
qu'elle capte ne recevrait que du silence (mesuré : crête 0,072 avant,
0,000 après). Caspr reçoit donc la **copie** du flux que la page capte déjà.

```
monde de la page, au début du document          monde « caspr »            Swift
getUserMedia enveloppé : la page reçoit
  LA promesse d'origine, et l'écho retient
  le flux rendu ──(armé)──► AudioContext 16 kHz
                            source sur le même flux
                            ScriptProcessor → gain 0 → sortie
                            Int16 petit-boutiste, en base64
                            CustomEvent au nom tiré au hasard ──► relais ──► casprEcho ──► RelaisEcho
                                                                                        [Float] en mémoire vive
```

- La page reçoit le même flux, sans altération ni retard : jamais `clone()`
  (qui garderait le micro ouvert), ni `applyConstraints`, ni `stop` ; tout est
  sous `try/catch`. `AudioWorklet` est exclu (la CSP de chatgpt.com refuse
  `blob:` et `data:`), d'où le `ScriptProcessor`.
  `mediaTypesRequiringUserActionForPlayback = []` laisse le contexte démarrer.
- Armé juste avant le clic du micro, désarmé à l'arrêt, à l'abandon, à la mort
  de la page. Les noms d'événements sont tirés au hasard pour chaque page :
  elle ne peut ni les deviner, ni émettre à la place de l'écho.
- `RelaisEcho` n'accepte que : armé, cadre principal, sa vue, hôte chatgpt.com
  (`RelaisPage.estChatGPT`), un message de taille bornée. Son gestionnaire est
  retiré par `detruire()` : sans cela la page — et le micro — survivraient au
  passage à macOS.
- **Rien sur disque.** Un tableau en mémoire, gardé après le désarmement —
  c'est pendant qu'on attend ChatGPT qu'on peut y renoncer —, puis pris par le
  repli, ou libéré à la fin de la dictée, ou quand on renonce au recours du
  menu.
- **Une ligne de journal par dictée**, écrite au désarmement, qui prouve à
  l'exécution que le son arrive :
  `relais : écho — 12,4 s reçues pour 12,6 s d'écoute, piste 48000 Hz, contexte running à 16000 Hz, crête 0,213, 1 appel à getUserMedia`,
  ou `relais : écho — rien reçu (crête 0,000, 0 appel à getUserMedia, contexte …)`.
  S'il ne reçoit rien, la dictée se déroule comme avant l'écho : le repli n'a
  rien à transcrire, l'aperçu le dit dans la barre au bout de deux secondes,
  et c'est tout. Un contexte qui n'a pas tourné à 16 kHz rend un son
  inutilisable par macOS : il est écarté, et le journal le dit.

Tenu par `RelaisScriptsTests` (la page reçoit la promesse d'origine et rien
d'autre ne change pour elle ; hors de chatgpt.com, l'écho ne touche à rien ;
sans `AudioContext`, rien ne lève ; armé avant le clic, le son part en Int16).

## Le repli

Renoncer à ChatGPT ne doit rien perdre de ce qui a été dit. Le propriétaire,
le 24 septembre 2026 : « si c'est l'utilisateur qui décide de quitter, si
c'était possible de récupérer quand même le texte via Apple Intelligence ».

| Situation | Ce qui est livré | Ce que dit la barre |
|---|---|---|
| Touche ou échec prouvé, brut déjà lu (envoi, réponse) | le brut, à la destination figée à l'arrêt | « Transcription brute insérée — ChatGPT abandonné », ou la raison de ChatGPT |
| Touche ou échec prouvé, brut pas lu, son reçu (0,3 s au moins) | la transcription du son par macOS | « Transcrit par macOS — ChatGPT abandonné », ou la raison ; « (N s de son sur M s) » quand le son ne couvre pas toute la dictée |
| Ni brut ni son utilisable, mais un aperçu écrit | l'aperçu | « Aperçu de macOS inséré — … » |
| Module qui n'écrit nulle part (Discuter) | rien ; ce qu'on a va au menu | « Gardé dans le menu de Caspr » |
| La zone revient vide alors que la page entendait une voix (crête de l'écho de 0,03 au moins, ou un aperçu écrit) | comme un échec prouvé : le son transcrit par macOS, sinon l'aperçu, sinon le menu | « ChatGPT n'a rien transcrit — transcrit par macOS » |
| Rien du tout | le chemin d'échec, ou d'abandon, d'avant l'écho | inchangé |

L'ordre est celui de `RelaisRepli.choisir` : le brut, puis le son entier,
puis l'aperçu — la transcription de macOS relit toute la phrase, l'aperçu l'a
écrite en l'entendant. Les échecs prouvés qui replient sont ceux après
lesquels ChatGPT ne rendra plus rien : un refus, la session fermée, la page
morte, le pont absent (`RelaisCycle.replie`). Un arrêt introuvable, non : la
page a peut-être encore le texte, elle s'ouvre pour qu'on l'y prenne.

Une zone revenue vide se juge sur l'écho (`RelaisRepli.parole`). Sans voix
entendue, la dictée finit sur « Rien n'a été entendu », rien au menu :
appuyer sans parler est un geste ordinaire. Avec une voix, ce n'est pas un
silence mais une dictée que ChatGPT a perdue — un toast d'erreur déjà
effacé, une panne qu'il n'affiche pas —, et elle replie. Le seuil est bas,
délibérément : un bruit pris pour une voix ne coûte qu'un passage de macOS
sur ce bruit, une voix prise pour un bruit coûtait la dictée. La ligne de
l'écho donne la crête de chaque dictée, de quoi l'éprouver.

Si macOS échoue à son tour, la raison de ChatGPT reste lisible : le menu garde
les deux (« <raison>. Repli par macOS : <échec> »), et « Réessayer » reste
possible sur le son. La dictée figée garde la voie ChatGPT, pour que la
livraison rende le clavier que la fenêtre du relais a pu prendre ; un repli
qui a livré n'ouvre pas la grande fenêtre.

Tenu par `RelaisRepliTests`.

## La croix n'est pas la touche

La **touche de dictée** est un geste délibéré, propre à Caspr : pendant
l'attente, elle renonce à ChatGPT **en livrant** le meilleur texte en main.
La **croix** de la barre annule tout, à n'importe quelle phase, **sans rien
insérer** ; ce qui est en main va au menu de Caspr, sans message : « Insérer
l'aperçu de macOS », « Insérer la transcription brute de ChatGPT » (ou la
réponse obtenue), « Réessayer avec le moteur » sur le son de la page.

**Échap** vaut la croix pendant l'écoute, et nulle part ailleurs hors d'une
discussion affichée : c'est un raccourci global, et le tenir pendant des
minutes l'avalerait dans toutes les autres applications. Mesuré : un Échap
global pendant l'attente a annulé deux réorganisations que personne ne
voulait annuler.

## Réessayer et l'aperçu, sur la voie ChatGPT

L'écho donne à la voie ChatGPT ce que seule la voie macOS avait :

- **L'aperçu en direct** : sous le réglage d'aperçu existant, macOS écrit ce
  qu'il entend du son de la page pendant que ChatGPT écoute
  (`ApercuEnDirect`, nourri par `RelaisEcho`). Sa langue se choisit dans le
  menu que la barre montre à côté du badge « ChatGPT », qui, lui, détecte la
  sienne. Quand le son est inutilisable, c'est l'aperçu que le repli insère,
  et lui seul que la croix garde au menu, allongé de ce que l'analyseur écrit
  encore après l'arrêt (`Livraison.prolongerLApercu`).
- **Réessayer** : le son reste au menu après une croix, ou quand le repli par
  macOS échoue, et « Réessayer avec le moteur » le transcrit comme un
  enregistrement de la voie macOS.

**Pas encore éprouvé dans l'app installée.** L'écho a été vérifié dans un
harnais — 440 Hz restitués par un contexte à 16 kHz sur un flux à 48 kHz, le
relais entre les deux mondes, la CSP —, pas encore par une ligne
« relais : écho — N s reçues » du journal d'une vraie dictée. Tant qu'elle
manque, la carte de la voie, le README et le site continuent de dire que la
voie ChatGPT n'a pas d'aperçu ; la première dictée qui la montre les rend
fausses. Sans elle, rien ne casse : un écho muet ramène la dictée à ce
qu'elle était avant lui. Les essais 26 à 30 d'`ESSAIS.md` sont ceux qui le
prouvent, ou non ; le repli, la croix et l'aperçu en dépendent.

## Ce qu'on montre pendant la dictée

Trois niveaux, réglables par module : rien, la barre seule, la page entière.
Le troisième existe pour rendre un défaut diagnosticable sans lire un journal
— on y voit le texte envoyé, la réponse, une erreur de ChatGPT. Changer de
module pendant l'écoute fait suivre l'affichage aussitôt ; le module retenu
est celui du moment de l'arrêt.

Les trois passent par la **fenêtre de la barre**, jamais par celle des
réglages, quelle que soit leur taille. Une fenêtre capable de devenir clé
ferait écrire la dictée dans la page au lieu de l'éditeur. « Rien » pose quand
même la barre à l'écran, transparente et sourde à la souris : la page reste
rendue, et la capture continue.

### Les deux fenêtres

Leurs exigences sont opposées, et une seule fenêtre qui change de costume ne
peut pas les satisfaire toutes deux.

| | Grande fenêtre | Barre |
|---|---|---|
| Sert à | se connecter, calibrer, récupérer un texte, discuter | regarder une dictée |
| Clavier | oui — sans quoi ni saisie ni copier-coller | jamais |
| Active l'application | oui | jamais |
| Suit les bureaux | non | oui |
| Niveau | normal | `.statusBar`, sous la barre de Caspr |

`.nonactivatingPanel`, nécessaire à la barre, rend le copier-coller impossible
dans l'autre rôle : cliquer une telle fenêtre n'active pas l'application, et ⌘C
part vers celle qui l'est. La vue web passe de l'une à l'autre ; elle vit dans
la barre par défaut, rangée hors champ — jamais retirée de l'écran par
`orderOut`, le système suspendant une fenêtre qu'il croit cachée. Rangée, elle
le reste quand on branche ou débranche un écran : AppKit ramène sur un écran
visible toute fenêtre qui n'est sur aucun, et la barre surgissait seule,
sourde à Échap (`BarreRelais.rangee`). Seul `poser` la montre. Fermer la
grande fenêtre la range, sans détruire ni la page ni la session.

## Les modules

Ce que Caspr fait d'une dictée est un **module** : un envoi (`RelaisEnvoi` —
rien, écrire la dictée ; remplacer, écrire la réponse de ChatGPT ; discuter,
la réponse reste à l'écran), une consigne autour de ce qui est dit, un
affichage, et la lecture à haute voix. Un seul choix plutôt que des actions et
des sorties à combiner : une combinaison invalide ne s'écrit pas, et `ecrit`
est le seul prédicat de destination, que la barre, la fenêtre, la fin d'une
dictée et la carte lisent tous. Ceux que l'application livre ne sont que des
modules pré-remplis :

| Module | Ta voix est… | Sortie |
|---|---|---|
| **Brut** | le texte lui-même | au curseur ou en note, rien n'est envoyé |
| **Réorganiser** | la matière à remettre en ordre | au curseur ou en note, après la réponse de ChatGPT |
| **Discuter** | une question | nulle part : la page reste ouverte et prend le clavier |

« Nouveau module… », sous la liste, ouvre la carte d'un module qui n'existe
pas encore : son nom, ce qu'il écrit (la réponse, par défaut), sa consigne,
son affichage et la lecture s'y règlent, et rien n'est rangé avant « Créer » —
un module rangé au premier clic rejoignait la barre sans nom ni consigne.
Créé, il rejoint la barre dès que ses capacités sont acquises, **sans qu'une
ligne du tuyau de dictée ne change** : celui-ci ne lit d'un module que son
envoi, `ecrit`, sa consigne, son affichage effectif et la lecture. Un module
de l'utilisateur se supprime ; un livré, non.

Un module déclare les **capacités** dont il a besoin, et une capacité ne se
choisit pas : elle s'acquiert, par calibration ou par autorisation système.
Brut n'exige que « dicter » ; Réorganiser, envoyer et récupérer ; Discuter,
envoyer ; la lecture ajoute « faire lire ». La barre ne propose que les
modules dont les capacités sont acquises, et la barre comme la dictée lisent
le même module retenu : le choisi s'il est utilisable, sinon « Brut »
(`RelaisCatalogue.retenu`).

Le format rangé se relit dans les deux sens : un module écrit avant l'envoi le
retrouve dans ses anciennes actions et sa sortie, et chaque module réécrit ces
anciennes clés à côté de `envoi`, pour qu'une version antérieure réinstallée
relise « Discuter » comme tel. Un module illisible n'emporte que lui-même.

La consigne se **dit**, elle ne se configure pas : « traduis ça en anglais » ne
tient pas dans un réglage. Caspr n'ajoute qu'un emballage, dont le seul rôle
est d'obtenir un résultat utilisable sans « Bien sûr ! Voici… » devant. Elle
est ajoutée aux deux bouts de la transcription déjà dans la zone, sans la
réécrire, et l'envoi n'est cliqué qu'après l'avoir relue ; si elle ne tient
pas, rien ne part, et le brut s'insère avec un avertissement.

Chaque passe qui écrit ouvre une **conversation neuve**, par rechargement de
la page de départ ; « Discuter » seul garde son fil. Sans cela, la note
précédente oriente la suivante — et le contexte finirait par déborder. Cette
page de départ est réglable : pointée sur un projet ChatGPT dédié, elle y
range toutes les conversations créées par Caspr, à l'écart des vraies. C'est
une URL et non un sélecteur, donc rien qui casse au prochain remaniement de la
page ; seule une adresse de chatgpt.com est acceptée, et elle est revérifiée à
chaque lecture.

La réponse se récupère par le bouton « copier » de son tour — la paire bloc et
bouton, ou le repère seul autour de la dernière réponse —, jamais par un
libellé, et seulement pour une réponse **nouvelle**, postérieure à l'envoi, et
finie. Une copie qui contient l'empreinte de la consigne — la dernière
ligne de l'un ou l'autre de ses bouts, « Avant » et « Après » — est rejetée :
c'est la demande. Ces empreintes sont aussi ce qui se relit dans la zone avant
le clic d'envoi : un module qui n'a que « Après » en a une, comme les autres. Le presse-papiers est sauvegardé tout entier juste avant le clic
et rendu tel quel, abandon compris : une copie faite par l'utilisateur pendant
l'attente n'est ni insérée ni écrasée.

Une transformation qui échoue rend la **transcription brute**. Une dictée de
dix minutes ne se perd pas parce que la seconde passe n'a pas abouti. Et ce
brut est gardé **dès qu'il est lu**, avant la seconde passe
(`Livraison.garderLeBrut`) : si la suite échoue, « Insérer la transcription
brute de ChatGPT », dans le menu, le rend. Une livraison réussie l'oublie.
Quand un module a remanié le texte, l'historique garde le brut à côté (sous ⌥
dans le menu, « Brut » dans les réglages).

## La calibration

Deux parcours, qui apprennent les mêmes repères. **L'automatique** essaie
lui-même les boutons de la page et ne retient que ceux dont il a vu l'effet ;
**le manuel** les fait montrer, clic par clic. Le second reste toujours à un
bouton : c'est le repli d'une page que l'automate ne sait pas lire. La
calibration n'est pas une dictée : ses attentes gardent leurs bornes — dix
minutes laissées à une main humaine pour se connecter, trente secondes à une
page qui ne dit rien.

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
sélecteur retrouve l'élément qu'on a trouvé par lui ne vérifierait rien. Aucun
repère n'est tiré d'un identifiant engendré.

« Copier » y compris quand aucun bloc ne le porte sans ambiguïté : son repère
doit alors être seul autour de la dernière réponse, selon la règle même de la
dictée. Ni l'essai ni la dictée ne retombent sur les libellés : un repère qui
ne trouve rien veut dire que le bouton n'est pas encore là. Ce repli existait,
et il cliquait en pleine génération le « Copier le code » d'un bloc de code —
une copie non vide, étrangère au message envoyé, qui s'insérait à la place de
la réponse.

La main suit la même règle. Un « copier » désigné n'est retenu que s'il est
celui du tour de la dernière réponse, et par un repère que la dictée ramènera
à ce seul bouton. La page en pose un sous chaque message, celui de
l'utilisateur compris : appris là, il copiait la demande à chaque dictée. Et
le clic doit avoir **copié**. Le guetteur ne retient qu'un clic réel
(`isTrusted`) du bon genre ; abandonné, il est retiré de la page, et le clic
suivant de l'utilisateur n'est appris nulle part.

Ce que l'automate s'interdit, et pourquoi :

- **Se connecter.** C'est le compte de l'utilisateur : sans session, la
  fenêtre s'ouvre, et le parcours attend qu'il s'y connecte — dix minutes au
  plus ; fermer la fenêtre l'arrête en silence — avant de demander, comme
  toujours, la permission d'envoyer le message d'essai. « Sans session » veut
  dire que la page l'a **dit** (un bouton de connexion, une page
  d'authentification), vu par le filet et non par le calibrage peut-être faux.
  Une page qui ne dit rien en trente secondes « ne répond pas » : elle est
  rechargée, puis rangée comme à toute sortie, et personne n'est envoyé
  chercher un mot de passe.
- **Écrire avant la fin.** Un automate qui échouerait à mi-chemin remplacerait
  en silence la moitié d'un calibrage qui marchait. Il travaille donc sur des
  preuves à part (`RelaisPreuves`), et n'écrit que l'aller-retour entier :
  zone, micro, arrêt, envoi, copier. La lecture et la réponse restent telles
  quelles.
- **Envoyer plus d'un message.** Le message d'essai est annoncé avant de
  partir ; s'il quitte la zone de texte, aucun bouton d'envoi ne se retente.
- **Ouvrir un menu.** Le menu « … » de la réponse porte « Régénérer » et
  « Supprimer ». D'où « Lire à haute voix », qui s'y cache parfois : il reste
  à montrer à la main, et le rapport le propose tant que la réponse est à
  l'écran. Non appris, il n'emporte pas les cinq autres repères.
- **Garder le presse-papiers.** Sauvegardé tout entier avant d'essayer
  « copier », rendu après le dernier essai, abandon compris.

## Où le relais touche le reste de l'application

Les endroits où la voie ChatGPT se distingue de la voie macOS, et pourquoi.

- **`CarteVoie.swift`** — la bascule, dans Réglages › Voie : deux lignes de
  même rang, macOS et ChatGPT, et sous elles les réglages de la seule voie
  retenue. Sous macOS, la page n'existe pas : des boutons qui la calibrent
  n'auraient rien à calibrer.
- **`CasprApp.swift`** — la même bascule dans le menu de la barre (« Écrire
  avec ChatGPT ») et sur un raccourci facultatif, vide par défaut. Vers
  ChatGPT, seulement si la page sait dicter — connectée et calibrée — ;
  sinon ces deux chemins ouvrent Réglages › Voie au lieu de basculer. Vers
  macOS, toujours : c'est la porte de sortie. L'icône porte une étincelle
  tant que la voie est ChatGPT, une bulle pendant une discussion. La page est
  chargée au lancement quand la voie est ChatGPT, pour que la première
  dictée ne paie pas l'ouverture de chatgpt.com. Le menu porte les recours :
  « Insérer la transcription brute de ChatGPT », « Insérer l'aperçu de
  macOS », « Réessayer avec le moteur », « Terminer la discussion ChatGPT ».
- **`UninstallWindow.swift`** — la session est effacée par l'API de WebKit
  après destruction de la page, avant le balayage des fichiers. C'est
  l'appelant qui attend, parce qu'il est dans un contexte qui le peut.
- **`Uninstall.swift`** — ramasse ce qui pourrait rester dans
  `~/Library/WebKit/<bundle>`, et **dit** dans la liste qu'une session ChatGPT
  est connectée. Sans cette mention, une case nommée « Réglages et historique »
  décidait en silence d'une session ouverte sur un service tiers.
- **`Dictee/Barre/RecordingOverlay.swift`** — la pastille des modules : le
  choix se fait au moment de parler, pas dans un écran de réglages. L'attente
  s'affiche avec sa phase, son chrono dès dix secondes, et sa sortie
  (« touche de dictée pour abandonner, × pour tout annuler ») ; la croix
  (`onCancel`).
- **`DicteeEnCours.swift`** — le module et la destination, figés à l'arrêt de
  l'écoute et portés jusqu'à la livraison ; la voie et l'application visée
  restent celles de l'appui.
- **`Livraison.swift`** — le retour à l'application où l'on parlait, capturée
  à l'appui : il vaut pour les deux voies, mais c'est pour ChatGPT qu'il
  compte, parce que trente secondes à plusieurs minutes séparent la parole de
  l'insertion. Elle ne distingue les voies qu'une fois, pour rendre le
  clavier, que seule une dictée ChatGPT a pu donner à la fenêtre du relais.
- **`Accueil/`** — le choix de la voie, juste après la bienvenue. Choisir
  ChatGPT y lance la connexion puis la calibration, et l'écran du premier
  essai montre `RelaisSession` au lieu du moteur de macOS ; la dictée d'essai
  s'écrit dans la zone d'essai.
- **`SetupRecoveryGuard.swift`** — le socle minimal de la voie ChatGPT : le
  raccourci, et une page connectée et calibrée (`RelaisSession.isValid`).

## Les règles

Chacune a coûté une dictée perdue, ou pire, chez quelqu'un. Les six premières
gardent leur rang : le code les cite par lui.

**1. Un repère appris doit dire de quel genre il est** — zone de saisie,
bouton — et ce genre sert trois fois : pour retrouver l'élément, pour juger le
repère au moment où on l'apprend, et pour écarter les clics hors sujet pendant
la calibration. Tenue par la table `GENRE` du pont (`RelaisScripts`) et
`RelaisScriptsTests` (« La calibration ne retient qu'un clic de la main »).

**2. Un sélecteur n'est pas une adresse** : c'est une question posée à la
page, et plusieurs éléments peuvent y répondre. ChatGPT pose le même libellé
d'accessibilité sur la zone de saisie et sur le bloc qui l'entoure ;
`querySelector` rendait le bloc, dont on ne peut rien lire. Toutes les dictées
partaient bien dans ChatGPT et revenaient vides — « rien n'a été entendu » — et
la calibration annonçait « le message d'essai n'a pas pu être écrit » devant
une zone où il était pourtant écrit. Le pont cherche l'élément **du bon
genre** qui répond (`trouver`) ; la présence suffit, la visibilité n'est pas
exigée — une page jamais affichée n'a pas de rectangle.

**3. Un repère appris qui ne trouve rien veut dire absent**, et non
« cherchons quelque chose qui lui ressemble ». Les heuristiques du pont sont le
filet de qui n'a pas encore calibré, et rien d'autre ; seul un sélecteur
syntaxiquement invalide y retombe. Pendant l'enregistrement, ChatGPT retire la
zone de saisie de la page : se rabattre sur « une zone éditable » trouvait
alors le document que ChatGPT avait produit à la réorganisation précédente, et
chaque dictée rendait ce document au lieu de ce qu'on venait de dire — en une
seconde et demie, au caractère près, sans que rien ne le signale. Tenue par
`trouver` et `RelaisScriptsTests` (« Un repère devenu invalide ne désigne
rien »).

**4. C'est la fin d'une dictée qui prépare la suivante.** Au repos, la page
est toujours prête : le fil ouvert quand on discute, une conversation neuve
quand un message est parti, une zone de saisie vidée sinon. Rien ne se décide
à l'appui — ni fil neuf, ni nettoyage — donc changer de module en pleine
phrase n'a aucun état à rattraper, et l'on ne paie jamais un rechargement
pendant qu'on parle. Une seule exception : un échec qui laisse la
transcription dans la fenêtre remet la préparation à plus tard
(`Repos.recuperation`), pour ne pas détruire sous les yeux le texte à
récupérer ; elle se fait à la fermeture de cette fenêtre ou à l'appui suivant.
Tenue par `Relais.finirLeCycle` et `RelaisPreparation` (testée).

**5. Tout champ ajouté à `RelaisSelecteurs` doit être décodé avec
`decodeIfPresent`.** Le décodage synthétisé par Swift échoue sur une clé
absente — il n'utilise pas les valeurs par défaut des propriétés — et une
structure enrichie rend d'un coup illisibles tous les calibrages déjà
enregistrés. La sanction n'est pas une erreur visible : c'est un réglage
effacé chez chaque utilisateur à la mise à jour, et un écran qui annonce
« configuration inachevée » à qui vient de la terminer. C'est arrivé en
0.13.0. Le calibrage persisté se relit à l'identique, sous des clés
(`relais.selecteurs`, `relais.modules`, `relais.mode`) qui ne changent pas de
nom. Tenue par `RelaisSelecteursTests` (les calibrages de la 0.12, de la 0.13
et de la 0.14 se relisent ; l'aller-retour ; les noms de clés) et
`RelaisModuleTests`.

**6. Aucune attente de ChatGPT ne finit parce que le temps passe.** Sur le
chemin d'une dictée, une attente ne finit que par un geste de l'utilisateur —
la touche de dictée, la croix de la barre, Échap pendant l'écoute — ou par un
échec que la page **prouve** : une alerte de refus apparue depuis la demande,
le processus WebKit mort, l'écran d'authentification montré, le pont de Caspr
absent d'une page chargée. Le propriétaire, le 24 septembre 2026 : « Des fois
ça prend dix, vingt, trente secondes, parce que si je parle plusieurs
minutes, ChatGPT prend beaucoup de temps. Donc non, il n'y a pas de limite. »
Une échéance a existé, sur la durée parlée, et un délai de cinq secondes sur
chaque appel au pont : ils jetaient des dictées qui aboutissaient, sous
« ChatGPT n'a pas répondu en 3 min ». En contrepartie, la sortie est
instantanée — l'annulation tranche l'attente même quand un appel JavaScript
ne revient jamais —, et la barre dit laquelle dès dix secondes. Restent les
délais de geste, tous dans `RelaisDelai` (cf. « L'attente unique ») ; dans le
doute, pas de délai. Au repos, en revanche, un silence se constate (`sonder`),
et ne mène qu'à reconstruire la page. Tenue par `observer`, `AppelAnnulable`,
`RelaisDicteeTests` et `AppelAnnulableTests`.

**7. Deux fenêtres, et jamais `orderOut`.** Leurs exigences sont opposées (cf.
« Les deux fenêtres ») ; la vue web rangée vit hors champ dans la barre, que
le système suspendrait s'il la croyait cachée. Tenue par `RelaisFenetres`
(`ranger`, `poser`, `BarreRelais.rangee`).

**8. L'attente observe.** Elle ne devine pas une issue d'après le temps : elle
relève l'état de la page et le juge. La transcription n'est rendue qu'après
environ une seconde sans changement — un texte encore en mouvement n'est
jamais rendu coupé — ; une zone revenue et restée vide quatre secondes dit
« rien n'a été entendu », jugement sur un état prouvé et non échéance — sauf
si la page entendait une voix : ChatGPT l'a perdue, et elle replie ; une
réponse est finie quand elle est nouvelle, plus en cours, et de même longueur
d'un relevé à l'autre. Une alerte déjà là à la marque n'interrompt jamais ;
une alerte inconnue n'interrompt pas tant que ChatGPT répond, et compte au
troisième relevé sans réponse ; « réessayer » ou « try again » dans une
réponse ou dans la dictée ne sont pas un refus. Tenue par `RelaisVeille`,
`RelaisRepli.parole` et leurs tests.

**9. Le repli rend le brut.** Une seconde passe qui échoue — refus, réponse
vide, consigne non posée, page morte après l'envoi — insère la transcription
brute, et la barre dit « Transcription brute insérée » avec la raison. Un
abandon n'est pas un échec : il suit la table de la machine. Tenue par
`VoieChatGPT.transformer` et `RelaisRepliTests`.

**10. La touche de dictée interrompt.** À toute phase, un appui rend la main
sur-le-champ — pendant une préparation de page, pendant un appel au pont qui
ne revient pas, pendant l'attente de la lecture —, et décide selon la table.
Aucun appui ne reste bloqué sur une préparation : la barre dit « ChatGPT se
prépare… » et comment en sortir. Tenue par `RelaisCycle.decider`,
`Relais.attendreLaPreparation` et `RelaisDicteeTests`.

## Les règles tenues par la structure

**Ce qui est pur vit dans `CasprCore`, et y est testé.** La règle inverse —
rien n'y entrait — protégeait la possibilité de retirer le relais, abandonnée
depuis que ChatGPT est l'une des deux voies du produit.

**La voie vit dans `Preferences`, et nulle part ailleurs.** Qui écoute le
micro est `Preferences.voie` (`caspr.voie`, un `VoieDeDictee`), relu à
chaque fois et figé au début de chaque dictée : basculer en pleine phrase
vaut pour la suivante. L'ancien interrupteur `relais.actif` n'est plus lu que
par la migration, qui en déduit la voie une fois, et il reste sur le disque.

**Rien n'existe tant que la voie n'est pas ChatGPT.** La `WKWebView` et la
session ChatGPT ne sont construites que sur cette voie, et détruites quand on
choisit macOS — à la fin de la dictée ChatGPT en cours s'il y en a une, qui va
au bout sur la page qu'elle a prise. Si cette dictée échoue en laissant son
texte dans la page, la fenêtre ouverte pour qu'on l'y copie survit à la fin
du cycle : la page part quand on la ferme, ou à l'appui de la dictée macOS
suivante, avant que le magnétophone n'écoute — en rendant alors le premier
plan que sa fenêtre tenait (`Relais.libererLaPageGardee`). Dans l'autre sens,
choisir ChatGPT pendant une dictée macOS ne construit la page qu'une fois le
magnétophone arrêté (`Relais.ecouteMacOS`) : née plus tôt, elle aurait réduit
au silence le reste de l'enregistrement. Détruite, la page rend le micro, le
gestionnaire de l'écho est retiré, la discussion et la préparation sont
oubliées, et Échap est rendu.

**Les deux voies se rejoignent à la livraison, pas en amont.** Le relais s'est
d'abord conformé au protocole des moteurs de macOS pour hériter de
l'insertion, de l'historique et des échecs. Il ne pouvait le faire qu'en
mentant : il recevait un enregistrement vide par construction. Chaque voie a
son chemin — `VoieApple`, `VoieChatGPT` —, et ils se rejoignent dans
`Livraison`. Les autres différences sont écrites là où elles se produisent :
un son qui n'est pas le nôtre, mais la copie de celui de la page ; une page à
rendre et à préparer à la fin de chaque dictée.

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
n'ouvre jamais le micro, donc la page peut rester ouverte entre deux dictées
et le raccourci reste instantané. Et le son dont la voie ChatGPT a besoin pour
son repli et son aperçu, elle le prend à la page, sans second micro.

## Ce qu'il ne fait délibérément pas

**Aucun second micro, même pour l'aperçu.** Il casserait tout (cf. plus haut) :
l'aperçu et le repli lisent la copie du flux de la page.

**Aucun banc d'essai contre ChatGPT.** Le relais n'accepte pas d'audio
enregistré : la page veut un micro en direct. Rejouer des dictées enregistrées
contre ChatGPT supposerait de les diffuser en temps réel : une heure de
parole, une heure d'horloge, pour une seule série. Le scénario, lui, se rejoue
sans WebKit (`RelaisDicteeTests`) : c'est le filet des gardes de la page.

## La mesure

La taille du relais se mesure toujours de la même façon, JavaScript compris
(il vit dans des chaînes Swift), commentaires exclus — le « pourquoi » reste :

```sh
find app/Sources/Caspr/Relais app/Sources/CasprCore/Relais -name '*.swift' \
  -exec cat {} + | grep -v -E '^\s*$|^\s*//' | wc -l
```

Le chiffre de chaque étape, et ce qui l'explique fichier par fichier, sont
dans les messages de commit.

À la fin de la refonte : **3 445**, pour 3 464 avant elle (2e95724) et un
plafond visé de 2 900 ; le chemin ChatGPT avec `VoieChatGPT` (441, contre
187) : 3 886 pour 3 651 avant elle et 3 250 visés. Le relais est sous son
point de départ, pas « nettement » : **sur la taille, E3 n'est pas tenu.**
Il a gagné l'écho, le repli, la machine, les preuves et les modules qu'on
crée, et perdu ses copies — la dernière passe a mis toutes les attentes sur
une seule boucle et le relevé de la page sur son type. Ce qui reste ne se
retire plus qu'en retirant une fonction : une décision du propriétaire, pas
un nettoyage. Les ordres de grandeur, en lignes mesurées :

| Retirer… | ≈ lignes | Ce qu'on perd |
|---|---|---|
| le parcours automatique de la calibration | 350 | six clics par calibration, accueil compris |
| ou le parcours manuel des cinq repères | 150 | le repli quand l'automate ne sait pas lire la page |
| la lecture à haute voix | 125 | les modules qui parlent (+ ≈ 12 dans `VoieChatGPT`) |
| le point de départ (projet dédié) | 45 | les conversations de Caspr rangées à part |
| la migration des formats d'avant la 0.15 | 45 | la mise à jour depuis la 0.14 et avant |
| le diagnostic | 23 | « sur quoi as-tu cliqué ? » sans recalibrer |

Sous 2 900, il faut par exemple l'automatique, la lecture, le point de
départ, la migration et le diagnostic (≈ 590, vers 2 875). Avec le manuel à
la place de l'automatique, on reste vers 3 075.
