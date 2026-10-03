# Essais à la main, avant de publier la 0.15

Sur `main`, dans `~/Desktop/projet-perso/CrispType`, où la refonte est
fusionnée. Ce que `swift test` ne peut pas voir : la vraie page ChatGPT, le
micro, les fenêtres, le presse-papiers, la migration de ta machine. Repris de
la liste du 23 septembre (112 essais), et mis à jour pour ce que la refonte du
relais a changé :

- **E1 — aucune limite de temps.** Plus aucune attente de ChatGPT ne finit
  parce que le temps passe : seuls toi (la touche, la croix, Échap pendant
  l'écoute) et un échec que la page **montre** (une alerte de refus, le
  processus WebKit mort, l'écran de connexion) y mettent fin. Dès dix
  secondes, la barre montre la phase, le chrono et la sortie. Plus aucun
  message « ChatGPT n'a pas répondu en N min ».
- **E2 — l'écho.** Caspr reçoit une copie du son que la page capte, en
  mémoire vive seulement. Il sert au **repli** (la touche pendant l'attente,
  ou un échec prouvé : le texte arrive quand même, par macOS), à la **croix**
  (rien n'est inséré, le son reste au menu pour « Réessayer ») et à
  l'**aperçu en direct** sous ChatGPT. Rien de tout cela n'a encore tourné
  dans l'app installée : les essais 26 à 30 le prouvent ou non, et le reste
  de la liste en dépend.
- **La touche n'est pas la croix.** Touche pendant l'attente : renoncer à
  ChatGPT **sans rien perdre** (le meilleur texte s'insère). Croix : tout
  annuler **sans rien insérer** (le texte va au menu). Échap n'est plus pris
  pendant l'attente : seulement pendant l'écoute, et devant une discussion
  affichée.

**Règle** : suis les essais dans l'ordre et arrête-toi au premier échec. Note
son numéro et ce que tu as vu. Les premiers vérifient ce qui est irréversible
(migration, réglages), les derniers envoient de vrais messages ou remettent
l'app à zéro.

**Le journal** : garde un Terminal ouvert pendant tous les essais avec
`/usr/bin/log stream --predicate 'subsystem == "fr.lyriastudio.caspr"' --level info`. Le chemin complet n'est pas un détail : dans zsh, `log` tout court est une commande interne du shell, qui répond « too many arguments ».
Quand un essai dit « dans le journal », c'est là qu'il faut regarder. Après
coup : `/usr/bin/log show --last 15m --info --predicate 'subsystem == "fr.lyriastudio.caspr"' | grep -E "relais|écho"`.

---

## 1. Avant d'installer (relevés sur ta machine telle qu'elle est aujourd'hui)

1. Sauvegarde les réglages actuels :
   `defaults export fr.lyriastudio.caspr ~/Desktop/caspr-avant-refonte.plist`
   Attendu : le fichier existe. Il contient le calibrage, l'historique, le
   raccourci et les langues. C'est ton filet si la migration en perd une partie.

2. La migration va mettre le corpus (tes 129 dictées) à la Corbeille, puis tu la
   videras en section 8. Si tu veux le garder hors du dépôt, copie-le maintenant :
   `cp -R ~/Library/Application\ Support/Caspr/corpus ~/Desktop/corpus-archive`.
   Sinon, ne fais rien.
   Attendu : rien à vérifier, c'est un choix.

3. `launchctl list | grep caspr`
   Attendu aujourd'hui : une seule ligne, `application.fr.lyriastudio.caspr.…`
   (l'app elle-même). Aucune ligne `fr.lyriastudio.caspr.engine`. Le démon n'est
   pas chargé, mais son fichier est encore là (essai suivant).

4. `ls ~/Library/LaunchAgents | grep -i -E 'caspr|sofler'`
   Attendu aujourd'hui : `fr.lyriastudio.caspr.engine.plist`.

5. `ls -A ~/Library/Application\ Support/Caspr`
   Attendu aujourd'hui : `.DS_Store backups corpus engine engine.json tools`.

6. `ls -A ~/.cache/huggingface/hub ; ls ~/Library/Logs/Caspr`
   Attendu aujourd'hui : `CACHEDIR.TAG models--nyralabs--CrisperWhisper2.0_turbo`,
   puis `engine.log`.

7. Note les réglages qui doivent survivre :
   ```
   for k in relais.actif relais.mode relais.affichage caspr.dictation.destination \
            caspr.notes.file caspr.languages.selected caspr.onboarding.step caspr.engine.final; do
     printf "%s = " $k; defaults read fr.lyriastudio.caspr $k | tr '\n' ' '; echo; done
   ```
   Attendu aujourd'hui : `relais.actif = 1`, `destination = caret`,
   `languages = fr-FR, en-US`, `onboarding.step = 4`, `engine.final = crisperwhisper`,
   `notes.file = …/CrispType/test-sofler.md`. Ce dernier fichier est déjà dans la
   Corbeille (rangé par nettoyage-machine.sh), voir l'essai 21.
   Fais aussi une capture de Réglages › l'onglet du relais (capacités acquises,
   liste des modules avec leur affichage et ta consigne perso) et une capture du
   menu de Caspr (raccourci, 3 premières entrées de l'historique).

8. Ta machine n'a plus ni lexique ni restes de Sofler (relevé du 23 septembre) :
   la migration n'aurait rien à en faire. Recrée-les pour qu'elle les traite.
   Quitte Caspr, puis :
   ```
   defaults write fr.lyriastudio.caspr caspr.lexicon -array Caspr Lyria Voxtral
   defaults write fr.lyriastudio.sofler essai -bool true
   mkdir -p ~/Library/Caches/fr.lyriastudio.sofler ~/Library/HTTPStorages/fr.lyriastudio.sofler
   ```
   Attendu : `defaults read fr.lyriastudio.caspr caspr.lexicon` rend les trois
   mots. `ls -d ~/Library/Preferences/fr.lyriastudio.sofler.plist ~/Library/Caches/fr.lyriastudio.sofler ~/Library/HTTPStorages/fr.lyriastudio.sofler`
   trouve les trois. `ls ~/Library/WebKit/fr.lyriastudio.caspr` existe (c'est ta
   session ChatGPT, qui ne doit pas bouger).

---

## 2. Installer

9. Caspr quitté, lance :
   `cd ~/Desktop/projet-perso/CrispType && ./scripts/install.sh`
   Attendu : la compilation passe, `/Applications/Caspr.app` est remplacée et
   relancée, et l'icône apparaît dans la barre des menus. Aucune alerte ne parle
   de moteur local, de service ou de CrisperWhisper. macOS ne redemande pas
   l'accessibilité (c'est le même certificat de développement) : le menu ne
   propose ni « Ouvrir les réglages Micro… » ni « Ouvrir les réglages
   Accessibilité… ». L'accueil ne s'ouvre pas.

---

## 3. La migration

10. `/usr/bin/log show --last 10m --info --predicate 'subsystem == "fr.lyriastudio.caspr"' | grep migration`
    Attendu, entre autres :
    - « agent fr.lyriastudio.caspr.engine mis à la corbeille » (son plist). Pas
      de ligne « sorti de launchd » : le démon n'était pas chargé (essai 3), et
      Caspr tait un label absent ;
    - « étape d'accueil : 4 → completion » ;
    - « réglage effacé : » pour `caspr.onboarding.step`, `caspr.engine.final`,
      `caspr.engine.apple`, `caspr.engine.live`, `caspr.engine.lastValid`,
      `caspr.crisper.model.chosen`, `caspr.schema.migrated` et `caspr.lexicon` ;
    - « voie de dictée posée — chatgpt » ;
    - « affichage du relais (…) repris par les modules livrés », puisque
      `relais.affichage` existait (essai 7) ;
    - « mis à la corbeille » pour : ancien lexique, moteur Python, outil uv de
      Caspr, modèle CrisperWhisper turbo, journaux du moteur, corpus,
      sauvegardes de réglages, déclaration du moteur, cache système de Sofler,
      stockage HTTP de Sofler, réglages de Sofler, puis dossier de Caspr.
    Aucune ligne « non retiré, retenté au prochain lancement », ni « peut-être
    encore chargé ».

11. Refais les relevés 3 à 6, puis ceux de l'essai 8.
    Attendu :
    - `launchctl list | grep caspr` : seulement la ligne `application.fr.lyriastudio.caspr.…` ;
    - LaunchAgents : rien ;
    - `~/Library/Application Support/Caspr` : « No such file or directory » ;
    - `~/.cache/huggingface/hub` : plus de `models--nyralabs--…`, seulement
      `CACHEDIR.TAG` ;
    - `~/Library/Logs/Caspr` : « No such file or directory » ;
    - les trois chemins `fr.lyriastudio.sofler` : « No such file or directory » ;
    - `~/Library/WebKit/fr.lyriastudio.caspr` est toujours là. Rien sous
      `fr.lyriastudio.caspr` n'a bougé.

12. Ouvre la Corbeille dans le Finder.
    Attendu : on y trouve `fr.lyriastudio.caspr.engine.plist`, `engine`, `tools`,
    `engine.json`, `corpus`, `backups`, `models--nyralabs--CrisperWhisper2.0_turbo`,
    le dossier `Caspr` (vide) et le dossier de journaux `Caspr`. On y trouve aussi
    `Caspr — ancien lexique.txt`, qui contient Caspr, Lyria et Voxtral, un mot
    par ligne, ainsi que `fr.lyriastudio.sofler.plist` et deux dossiers
    `fr.lyriastudio.sofler`. Un nom peut porter un suffixe si la Corbeille en
    avait déjà un pareil.

13. Vérifie les réglages dans le Terminal :
    `defaults read fr.lyriastudio.caspr caspr.voie` → `chatgpt`
    `defaults read fr.lyriastudio.caspr caspr.onboarding.screen` → `completion`
    `defaults read fr.lyriastudio.caspr caspr.onboarding.step` → « does not exist »
    `defaults read fr.lyriastudio.caspr caspr.engine.final` → « does not exist »
    `defaults read fr.lyriastudio.caspr caspr.lexicon` → « does not exist »
    `defaults read fr.lyriastudio.caspr relais.selecteurs` → identique à la même
    clé dans `~/Desktop/caspr-avant-refonte.plist` (compare avec
    `plutil -p ~/Desktop/caspr-avant-refonte.plist | grep -A3 relais.selecteurs`, ou à l'œil).
    Attendu : les cinq premières réponses comme indiqué, et le calibrage inchangé.

14. Quitte Caspr puis relance-le depuis /Applications.
    Attendu : dans le journal, aucune nouvelle ligne « mis à la corbeille »,
    « réglage effacé » ni « sorti de launchd ». La migration repasse sans rien
    trouver à faire.

15. Un démon resté chargé alors que son plist a disparu. Charge un faux démon
    sous le même nom, depuis le Bureau (donc absent de LaunchAgents) :
    ```
    cat > ~/Desktop/faux-demon.plist <<'EOF'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>fr.lyriastudio.caspr.engine</string>
      <key>ProgramArguments</key><array><string>/bin/sleep</string><string>86400</string></array>
      <key>RunAtLoad</key><true/>
    </dict></plist>
    EOF
    launchctl bootstrap gui/$UID ~/Desktop/faux-demon.plist
    launchctl print gui/$UID/fr.lyriastudio.caspr.engine | head -3
    ```
    La dernière commande doit trouver le service. Quitte Caspr et relance-le.
    Attendu : le journal dit « migration : agent fr.lyriastudio.caspr.engine
    sorti de launchd ». `launchctl print gui/$UID/fr.lyriastudio.caspr.engine`
    répond « Could not find service ». Relance Caspr une fois encore : plus
    aucune ligne sur l'agent (un `bootout` sur un label absent rend le statut 3,
    que Caspr tait). Supprime ensuite `~/Desktop/faux-demon.plist`.

16. Ouvre le menu de Caspr.
    Attendu : sous « Dicter », « Écrire avec ChatGPT » est coché. Le raccourci,
    les langues et les transcriptions récentes sont les mêmes que sur ta capture.
    Clique une ancienne entrée avec le curseur dans TextEdit : elle s'y insère.

17. Ouvre Réglages.
    Attendu : quatre onglets, Général, Dictée, Voie, Historique. Pas de Lexique,
    Collecte ni Moteur IA. La barre d'onglets est propre à l'œil (4 boutons plus
    larges qu'avant).

18. Onglet Voie.
    Attendu : deux lignes, macOS et ChatGPT. ChatGPT a la pastille pleine, et
    seuls ses réglages s'affichent en dessous. La carte dit « Connecté à ChatGPT »
    en tête, sans « Configuration inachevée ». Les capacités apprises (Dicter,
    Envoyer, Récupérer la réponse, Faire lire à haute voix) sont cochées. Les
    boutons « Calibrer automatiquement… », « Montrer à la main… », « Ouvrir la
    fenêtre… », « Diagnostic… » et « Se déconnecter… » sont là. Dessous, les
    modules Brut, Réorganiser et Discuter gardent l'affichage et la consigne de
    ta capture, puis le bouton « Nouveau module… ».

19. Onglet Historique.
    Attendu : les entrées d'avant la mise à jour sont toutes là.

20. Onglet Général › Mises à jour.
    Attendu : le texte dit « Vos réglages, votre historique et les autorisations
    restent en place ». Nulle part « Dictées archivées » ni CrisperWhisper.

21. Onglet Général, carte de la destination.
    Attendu : le fichier de notes est toujours `test-sofler.md`, puisque le
    réglage a survécu. Ce fichier est dans la Corbeille, donc Caspr le signale
    comme introuvable. Choisis un nouveau fichier, par exemple
    `~/Desktop/notes-caspr.md`, pour les essais Notes plus bas.

22. Menu › Désinstaller Caspr…, puis ferme la fenêtre sans valider.
    Attendu : aucune case « Dictées archivées » ni moteur. La ligne « Fichiers
    temporaires » n'apparaît que si l'un de ses dossiers existe, et sa taille
    compte `~/Library/Caches/fr.lyriastudio.caspr` (le cache de la page
    ChatGPT). « Restes de l'ancien moteur local » n'apparaît que si la
    migration a laissé quelque chose (journal : « non retiré »). Les tailles
    arrivent un instant après la fenêtre. Rien n'est désinstallé.

---

## 4. La voie ChatGPT (celle de tous les jours)

Pour chaque essai, place le curseur dans TextEdit sauf indication contraire.
Laisse l'aperçu en direct activé (Réglages › Dictée), sauf quand un essai dit
de le couper.

### Brut

23. Appuie une fois sur la touche de dictée, choisis Brut sur la pastille, dis
    « Bonjour, ceci est un essai », puis appuie de nouveau. (Ne la maintiens
    pas : tenue une seconde, elle ouvre les Réglages au lieu de dicter.)
    Attendu : pendant l'écoute, la pastille des modules est en haut à droite de
    la barre, sur le module en cours. La phrase s'écrit au curseur et arrive en
    tête des transcriptions récentes. Caspr n'ouvre pas son propre micro : le
    voyant de macOS ne montre que l'usage du relais. Aucune langue n'est grisée
    dans le sélecteur de langue de la barre. Dans le journal : « relais :
    demarrage → ecoute », puis « ecoute → transcription », et jamais
    « relais : micro … sans effet ».

24. Pendant l'écoute, clique un autre module sur la pastille.
    Attendu : la surbrillance change, et l'affichage de la barre ChatGPT suit le
    module choisi. Le résultat correspond au module cliqué.

25. Les trois affichages. Dans Réglages › Voie, règle tour à tour l'affichage
    de Brut sur « Barre », « Page » et « Rien », et dicte une phrase à chaque
    fois.
    Attendu : « Barre » montre une petite bande ChatGPT (la seule pastille
    d'enregistrement, sans colonne ni en-tête) au-dessus de la barre de Caspr,
    sans la recouvrir : la pastille des modules reste cliquable. « Page » montre
    la page en grand au milieu de l'écran, qui ne prend pas le clavier : la
    phrase s'écrit dans TextEdit, jamais dans ChatGPT. « Rien » ne montre rien
    de ChatGPT, et la phrase s'écrit quand même. Après chaque dictée, rien de
    ChatGPT ne reste à l'écran. Remets Brut sur son affichage d'origine.

### L'écho : le son de la page (E2 — à prouver ici)

26. Après l'essai 23, regarde la ligne de l'écho dans le journal :
    `/usr/bin/log show --last 5m --info --predicate 'subsystem == "fr.lyriastudio.caspr"' | grep "écho"`
    Attendu : une ligne par dictée, du genre « relais : écho — 2,4 s reçues
    pour 2,6 s d'écoute, piste 48000 Hz, contexte running à 16000 Hz, crête
    0,1xx, 1 appel à getUserMedia ». Les secondes reçues sont proches des
    secondes d'écoute, la crête n'est pas nulle, et le contexte tourne à 16000 Hz.
    **Si la ligne dit « rien reçu », « aucun statut de la page » ou un autre
    contexte que 16000 Hz, arrête-toi ici et note-la entière** : le repli par
    macOS, la croix qui garde le son et l'aperçu sous ChatGPT n'ont alors rien
    pour travailler. La dictée elle-même doit quand même avoir marché.

27. Dicte une phrase plus longue (une vingtaine de secondes) avec Brut, et
    écoute-la : relis le texte inséré.
    Attendu : la transcription de ChatGPT est aussi bonne qu'avant la refonte
    (l'écho ne touche pas au son qu'il reçoit, ne le retarde pas). La ligne de
    l'écho dit une vingtaine de secondes reçues.

28. Pendant la dictée de l'essai 27, regarde sous la barre.
    Attendu : l'aperçu de macOS s'écrit pendant que tu parles, comme sur la
    voie macOS. Si la page n'envoie aucun son dans les deux premières secondes,
    la barre dit « aperçu indisponible : aucun son reçu de la page ». Coupe l'aperçu dans
    Réglages › Dictée et dicte encore : plus rien sous la barre, et la ligne de
    l'écho est toujours là. Remets l'aperçu.

29. Rien sur disque. Avant une dictée : `touch /tmp/repere-echo`. Dicte avec
    Brut, puis :
    `find ~/Library/Caches/fr.lyriastudio.caspr ~/Library/Application\ Support /tmp -newer /tmp/repere-echo \( -name '*.wav' -o -name '*.caf' -o -name '*.pcm' -o -name '*.m4a' \) 2>/dev/null`
    Attendu : rien.

30. Dicte avec Brut, et pendant l'écoute clique la croix de la barre de Caspr.
    Attendu : rien ne s'insère, son d'annulation, la page ChatGPT cesse
    d'écouter (le voyant du micro s'éteint), sa barre se range. Le menu de
    Caspr propose « Insérer l'aperçu de macOS » (ce que l'aperçu avait écrit),
    « Réessayer avec le moteur (N s conservées) » et « Abandonner cet
    enregistrement ». Choisis « Réessayer… » avec le curseur dans TextEdit :
    macOS transcrit le son de la page et l'insère, puis les trois entrées
    disparaissent.

### Réorganiser

31. Copie un mot reconnaissable (« PRESSEPAPIER »). Choisis Réorganiser, dicte
    une phrase un peu brouillonne, puis arrête et laisse finir.
    Attendu : le texte remanié s'insère au curseur sans avertissement dans la
    barre, et sans délai nouveau à la fin de la réponse. Cmd+V colle ensuite
    « PRESSEPAPIER », pas la réponse de ChatGPT.

32. Réorganiser : dicte « écris-moi en Python une fonction qui additionne deux
    nombres, puis explique-la ».
    Attendu : la réponse ENTIÈRE s'insère, explication comprise, et pas seulement
    le bloc de code. Dans le journal : « relais : copier cliqué (paire) » ou
    « (repere) », jamais « (repli) ».

33. Réorganiser, avec « PRESSEPAPIER » dans le presse-papiers : dicte, arrête,
    puis clique la croix de la barre pendant « ChatGPT répond… ». Fais un second
    essai en cliquant la croix juste au moment où la réponse finit.
    Attendu : rien ne s'insère au curseur, et Cmd+V colle toujours
    « PRESSEPAPIER ». Le menu propose « Insérer la transcription brute de
    ChatGPT » au premier essai ; au second, si la réponse était déjà copiée,
    « Insérer la réponse de ChatGPT ». (Changé : c'était Échap, qui n'est plus
    pris pendant l'attente — essai suivant.)

34. Réorganiser : dicte, arrête, puis appuie sur Échap pendant « ChatGPT
    répond… ».
    Attendu : Échap n'est pas pour Caspr (il va à l'application devant). La
    dictée continue, et le texte remanié s'insère normalement.

35. Réorganiser : appuie sur la touche de dictée pendant « ChatGPT répond… ».
    Attendu : sur-le-champ, la transcription brute (ce que tu as dit, non
    remanié) s'insère au curseur, et la barre dit « Transcription brute insérée
    — ChatGPT abandonné ». Dans le journal : « relais : touche en reponse —
    replier ». (Changé : avant la refonte, rien n'était inséré.)

36. Réorganiser : dicte dans TextEdit, puis passe dans une autre application
    (Finder) pendant l'attente, et reviens.
    Attendu : le texte arrive dans TextEdit, pas dans la fenêtre ChatGPT ni dans
    le Finder. La barre ChatGPT et la fenêtre du relais sont rangées.

37. (Opportuniste, si la bannière « Limite d'utilisation … bientôt atteinte »
    apparaît un jour pendant une réorganisation.)
    Attendu : la réponse remaniée est insérée normalement.

### Aucune limite de temps, et la sortie (E1)

38. Réorganiser : dicte sans t'arrêter pendant **au moins deux minutes**, puis
    arrête.
    Attendu : la barre dit « ChatGPT transcrit… », puis « ChatGPT répond… ».
    Passé dix secondes, le chrono s'ajoute, avec « — touche de dictée pour
    abandonner, × pour tout annuler ». Aussi long que ChatGPT mette, aucune
    erreur de temps : le texte remanié finit par s'insérer, entier. Dans le
    journal, aucune ligne « n'a pas répondu » ni « sans effet en ».

39. Même dictée longue, mais appuie sur la touche pendant « ChatGPT
    transcrit… » (avant que la zone ne revienne).
    Attendu : la barre dit aussitôt « ChatGPT abandonné — transcription par
    macOS… », puis le texte de macOS (tiré du son de la page) s'insère au
    curseur, et la barre dit « Transcrit par macOS — ChatGPT abandonné ». S'il
    manque une partie du son, elle ajoute « (N s de son sur M s) ». La page
    ChatGPT cesse d'écouter tout de suite, pas une fois macOS fini. Dans le
    journal : « relais : touche en transcription — replier », puis « relais :
    repli après la touche — … ».

40. Même chose avec la croix pendant « ChatGPT transcrit… ».
    Attendu : rien ne s'insère, son d'annulation, la barre disparaît. Le menu
    propose « Réessayer avec le moteur (N s conservées) » (et « Insérer
    l'aperçu de macOS ») : la croix annule, elle ne perd rien.

41. La sortie est instantanée. Pendant une longue attente (« ChatGPT
    répond… » d'une dictée d'une minute), appuie sur la touche.
    Attendu : la barre réagit dans l'instant (moins d'un quart de seconde à
    l'œil), quelle que soit l'activité de la page.

### Discuter

42. Règle Discuter avec « Lire la réponse » activé et l'affichage « Page ».
    Dicte une question qui demande une réponse d'une dizaine de secondes.
    Attendu : après l'envoi, la barre affiche « Lecture à haute voix… », puis,
    passé dix secondes depuis l'arrêt, le chrono et « — touche de dictée pour
    ne plus attendre ». La réponse s'affiche et elle est lue à haute voix
    environ 2 s après la fin de son écriture. Pendant la discussion, l'icône de
    la barre des menus est la bulle, et le menu propose « Terminer la
    discussion ChatGPT ».

43. Refais une question, et appuie sur la touche de dictée pendant « Lecture à
    haute voix… », avant que la voix ne parte.
    Attendu : la barre Caspr disparaît sans son d'annulation. La fenêtre du
    relais s'ouvre sur la conversation avec la réponse en cours. La page ne se
    recharge pas, et aucune lecture à haute voix ne part.

44. Juste après, rappuie sur la touche et pose une question de suivi.
    Attendu : elle arrive dans la MÊME conversation.

45. Appuie sur Échap.
    Attendu : la discussion se ferme (Caspr se cache), l'icône redevient le
    fantôme, et la question suivante part d'une conversation neuve.

46. Refais l'essai 43, discussion fermée, avec la croix de la barre Caspr à la
    place de la touche.
    Attendu (changé : la croix annule toujours) : son d'annulation, la barre
    disparaît, aucune voix ne part, et **aucune discussion ne s'ouvre** (pas de
    bulle, pas de « Terminer la discussion ChatGPT »). Le message était parti :
    la réponse est dans l'historique de ChatGPT, et la dictée suivante part
    d'une conversation neuve. Le menu propose « Insérer la transcription brute
    de ChatGPT » (ta question).

47. Discuter : appuie sur la touche pendant « ChatGPT transcrit… », avant
    l'envoi.
    Attendu : rien n'est envoyé, aucune discussion ne s'ouvre, la page
    s'arrête. La barre dit « Gardé dans le menu de Caspr », et le menu propose
    « Réessayer avec le moteur (N s conservées) » : un module qui n'écrit nulle
    part n'insère rien, même quand on renonce à ChatGPT.

48. Discuter en « Page » : pendant l'écoute, appuie sur Échap, puis tape
    quelques lettres.
    Attendu : la fenêtre se ferme, Caspr rend le premier plan, et les lettres
    arrivent dans TextEdit. Le menu garde le son (« Réessayer avec le moteur »).

49. Discuter : pose une question pour que la grande fenêtre s'ouvre et prenne le
    clavier. Sans cliquer ailleurs, appuie sur la touche, choisis Brut sur la
    pastille en parlant, puis arrête.
    Attendu : le texte s'écrit dans l'application d'avant la discussion
    (TextEdit), jamais dans Caspr. La fenêtre ChatGPT disparaît.

50. Même geste que l'essai 49, mais avec la fenêtre Réglages de Caspr ouverte
    DERRIÈRE la fenêtre de discussion.
    Attendu : le texte ne part pas dans les Réglages. Caspr se cache et le texte
    va dans TextEdit.

51. Discuter : une réponse reste ouverte dans la fenêtre du relais. Passe à
    Réorganiser sur la pastille, clique dans TextEdit, puis dicte.
    Attendu : le texte va dans TextEdit, pas dans le composeur de ChatGPT.

52. Dans la fenêtre du relais, renomme une conversation de la barre latérale en
    « Connexion SSH au serveur » (menu « … » de la conversation › Renommer).
    Ferme la fenêtre, puis dicte une question avec Discuter en « Page ».
    Attendu : la dictée démarre normalement, avec ce titre visible dans la barre
    latérale. Pas d'alerte « D'abord, se connecter à ChatGPT », et Réglages ›
    Voie dit toujours « Connecté à ChatGPT ». Le mot « Connexion » n'est plus
    cherché que sur les boutons de la page.

53. Discuter en « Page » ou « Barre » : ouvre une discussion, puis Réglages ›
    Voie › « Se déconnecter… » et confirme.
    Attendu : la fenêtre ou la barre disparaît. L'icône n'est plus la bulle et
    « Terminer la discussion ChatGPT » n'est plus dans le menu. Échap refonctionne
    ailleurs (il ferme par exemple Spotlight). Avant de te reconnecter, la carte
    de Réglages › Voie ne dit plus « Connecté à ChatGPT » : la page déconnectée
    est toujours reconnue comme telle (bouton de connexion et liens
    `/auth/login`). Reconnecte-toi ensuite par « Ouvrir la fenêtre… », dicte avec
    Brut et vérifie que ça marche encore (aucune alerte « configuration
    inachevée »).

### Destination Notes

54. Sur la barre, choisis « Notes » (fichier réglé à l'essai 21), puis dicte avec
    Brut en laissant le curseur dans TextEdit.
    Attendu : le texte s'ajoute à `~/Desktop/notes-caspr.md`, et rien ne s'écrit
    dans TextEdit. Remets ensuite la destination sur « Curseur ».

### Les échecs

55. Réorganiser : dicte, arrête, puis coupe le Wi-Fi dès que « ChatGPT répond… »
    s'affiche.
    Attendu, l'une des deux issues — **jamais un message de temps écoulé** :
    - ChatGPT affiche une erreur : en quelques secondes, la transcription brute
      s'insère, et la barre dit « Transcription brute insérée » avec la raison
      de ChatGPT en seconde ligne ;
    - la page ne dit rien : la barre continue « ChatGPT répond… m:ss — touche
      de dictée pour abandonner, × pour tout annuler », sans fin. Appuie alors
      sur la touche : la transcription brute s'insère avec « Transcription
      brute insérée — ChatGPT abandonné ».
    Note laquelle tu as vue. Rallume le Wi-Fi.

56. Discuter : pose une question, puis une question de suivi, et coupe le Wi-Fi
    juste après l'appui d'arrêt de la suite.
    Attendu, l'une de ces issues, sans minuteur :
    - ChatGPT affiche une erreur : la barre dit « ChatGPT : <son message> —
      gardé dans le menu de Caspr » ;
    - la page ne dit rien : « ChatGPT transcrit… m:ss — touche de dictée pour
      abandonner… ». Appuie sur la touche : « Gardé dans le menu de Caspr » ;
    - la zone revient vide, sans message : la page t'entendait, ce n'est donc
      pas un silence, et la barre dit « ChatGPT n'a rien transcrit — gardé
      dans le menu de Caspr » (« Rien n'a été entendu » ici est un défaut :
      note la crête de la ligne « relais : écho » du journal).
    Dans les trois cas, le menu propose « Réessayer avec le moteur (N s
    conservées) ». Rallume le Wi-Fi, mets le curseur dans TextEdit et choisis
    « Réessayer… » : ta question, transcrite par macOS, s'y insère. Termine la
    discussion par le menu.

57. Dicte sans rien dire, pendant au moins une demi-seconde.
    Attendu : la barre dit « Rien n'a été entendu », sans attente longue, et
    le menu ne propose ni « Réessayer » ni « Insérer l'aperçu ». Sur la voie
    ChatGPT, la barre peut d'abord dire « ChatGPT n'a rien transcrit —
    transcription par macOS… » : la crête a dépassé 0,03, et macOS vérifie.
    Refais-le sous Discuter, puis (si tu en as un) sur un Mac sans Apple
    Intelligence ou sans droit de reconnaissance vocale : macOS n'y vérifie
    pas, et si la crête dépasse 0,03, la barre dit « Rien n'a été entendu ?
    Le son est gardé dans le menu de Caspr », sans icône d'erreur — jamais
    « ChatGPT n'a rien transcrit » —, et le menu propose alors « Réessayer ».
    Dans tous les cas, note la crête de la ligne « relais : écho » du journal
    (fais-le trois fois, dont une en appuyant fort sur la touche) : c'est la
    mesure qui manque pour fixer `RelaisRepli.creteDeParole` au-dessus du
    bruit d'un appui muet.

58. Réglages › Historique : décoche « Conserver l'historique des dictées ».
    Rends le fichier de notes illisible : `chmod 000 ~/Desktop/notes-caspr.md`.
    Sur la barre, choisis « Notes », puis dicte avec Réorganiser.
    Attendu : la barre dit « Insertion impossible — Le texte est dans la
    fenêtre de ChatGPT. » La fenêtre du relais s'ouvre sur la réponse remaniée.
    La page ne se recharge pas tant que tu ne l'as pas quittée : la réponse y
    reste lisible. Dans cette fenêtre, Échap ne la ferme PAS et ne recharge PAS
    la page, et la réponse se copie avec ⌘C. Le menu propose toujours
    « Insérer la transcription brute de ChatGPT ». Ferme la fenêtre : la page
    est alors préparée pour la suite.

59. Même geste, historique réactivé (recoche « Conserver l'historique des dictées »).
    Attendu : aucune fenêtre ne s'ouvre. La barre dit « Insertion impossible —
    Le texte est dans l'historique, menu de Caspr. », et le texte remanié est en
    tête des transcriptions récentes. La page est préparée pour la suite : une
    dictée lancée juste après démarre normalement.

60. Historique à nouveau décoché, fichier toujours illisible : dicte avec Brut
    (pas de seconde passe, le texte est le brut).
    Attendu : aucune fenêtre ne s'ouvre. La barre dit « Insertion impossible —
    La transcription brute est dans le menu de Caspr. », et le menu la propose.
    Remets ensuite tout en place : `chmod 644 ~/Desktop/notes-caspr.md`, recoche
    l'historique, et remets la destination sur « Curseur ».

61. Discuter avec « Lire la réponse » : demande « Réponds seulement par le mot
    réessayer ». Dans la même discussion, dicte ensuite « try again ».
    Attendu : la réponse « Réessayer » s'affiche et elle est lue à voix haute.
    Dans les deux cas, aucun refus n'est signalé. Le texte d'un message de la
    conversation n'est jamais pris pour une alerte de la page.

62. (Opportuniste, le jour où un quota ChatGPT est atteint ou qu'une alerte de
    refus est visible.) Dicte avec Réorganiser, puis avec Discuter + lecture.
    Attendu : Réorganiser insère la transcription brute en quelques secondes,
    avec « Transcription brute insérée » et « ChatGPT : <texte de l'alerte> »
    dans la barre. Discuter affiche « ChatGPT : <texte de l'alerte> », au lieu
    d'attendre. Un vrai « Something went wrong… Try again » doit encore être
    reconnu. Une alerte que Caspr ne reconnaît pas n'arrête l'attente qu'après
    l'envoi, et seulement si ChatGPT ne répond pas ; sinon l'attente continue,
    et la touche en sort. Note ce que tu vois.

63. (Opportuniste, le jour où ta session ChatGPT expire pendant une dictée.)
    Attendu : la barre dit « ChatGPT : session déconnectée ». Si c'était
    pendant l'écoute ou la transcription, le texte de macOS s'insère quand même
    (« ChatGPT : session déconnectée — transcrit par macOS »). Réglages › Voie
    ne dit plus « Connecté à ChatGPT ».

### La page qui se charge ou qui meurt

64. Quitte Caspr, relance-le sur la voie ChatGPT et appuie tout de suite sur la
    touche de dictée (dans la seconde, Brut).
    Attendu : la barre dit « ChatGPT se prépare… », d'emblée avec le chrono et
    « touche de dictée pour abandonner, × pour tout annuler », puis l'écoute
    démarre dès que la page est prête. Pas d'alerte
    « D'abord, se connecter à ChatGPT » ni « La page ChatGPT ne répond pas »,
    et pas besoin d'un second appui.

65. Même chose, mais appuie une seconde fois sur la touche pendant « ChatGPT se
    prépare… ».
    Attendu : la barre disparaît sur-le-champ, rien n'écoute, et l'appui
    suivant (quelques secondes plus tard) démarre normalement, sans recharger
    la page une seconde fois.

66. Discuter : ouvre une discussion, termine-la par Échap (la page repart sur
    une conversation neuve), puis rappuie aussitôt sur la touche.
    Attendu : la dictée attend la fin du chargement (« ChatGPT se prépare… »)
    au lieu de recharger la page une seconde fois, puis part dans une
    conversation neuve. Si la page n'est toujours pas prête au bout de 30 s, la
    préparation reprend son chemin normal, sans alerte.

67. Moniteur d'activité : cherche le processus Web Content de Caspr (« Caspr
    Web Content », ou le nom du site chatgpt.com), force-le à quitter, puis
    appuie tout de suite sur la touche (Brut).
    Attendu : le journal dit « relais : WebKit a arrêté le processus de la page
    — rechargement ». La dictée attend la page rechargée puis démarre. Elle
    n'est pas annoncée perdue.

68. WebKit tué **pendant l'écoute**. Dicte avec Brut et, en parlant, force le
    processus Web Content à quitter.
    Attendu : l'écoute s'arrête aussitôt. La barre dit « La page ChatGPT s'est
    fermée — transcription par macOS… », puis ce que tu avais dit jusque-là
    s'insère, et la barre dit « La page ChatGPT s'est fermée — transcrit par
    macOS ». Aucune discussion ne reste ouverte. Si l'écho n'avait rien reçu
    (essai 26), la barre dit « La page ChatGPT s'est fermée — dictée perdue ».

69. WebKit tué **pendant la transcription**. Dicte une minute avec Brut,
    arrête, et force le processus à quitter pendant « ChatGPT transcrit… ».
    Attendu : même issue que l'essai 68 — le texte de macOS s'insère, avec
    « La page ChatGPT s'est fermée — transcrit par macOS ». La dictée suivante
    démarre normalement.

70. Force ce processus à quitter deux fois à moins de 5 minutes d'intervalle
    (laisse la page se recharger entre les deux), puis appuie sur la touche.
    Attendu : après la seconde mort, le journal dit « relais : WebKit a encore
    arrêté le processus de la page — rechargement au prochain usage », et rien
    ne se recharge tout seul. À l'appui, la page se recharge et la dictée
    démarre, sans conclure « pas connecté ».

### Les modules

71. Réglages › Voie › « Nouveau module… ». Nomme-le « Anglais », laisse
    « Ce qu'il écrit » sur « Écrire la réponse », écris dans le champ « Avant »
    (déjà ouvert) : « Traduis en anglais : », puis « Créer ».
    Attendu : rien n'apparaît sur la barre avant « Créer ». Après, le module est
    dans la liste et sur la pastille de la barre. Dicte une phrase en français
    avec lui : sa traduction s'insère. Puis « Supprimer… » et confirme : il
    quitte la liste et la pastille (choisi, il cède la place à Brut).

71 bis. Même chose avec un module « Anglais après », dont seul le champ
    « Après » est rempli : « Traduis ce qui précède en anglais. » (« Avant »
    vide). La carte dit « personnalisée », et non « aucune ».
    Attendu : sa traduction s'insère — et non ta phrase en français, ni ta
    phrase suivie de la consigne. Dans le journal, aucune ligne « copie de la
    demande au lieu de la réponse ».

---

## 5. La bascule, puis la voie macOS

### La bascule

72. Regarde l'icône de la barre des menus en voie ChatGPT et survole-la.
    Attendu : le fantôme porte une petite étincelle à quatre branches en haut à
    droite, au repos comme pendant l'écoute. L'infobulle finit par « · voie
    ChatGPT ». Juge à l'œil si l'étincelle se lit bien à cette taille.

73. Réglages › Voie ouvert à côté, décoche « Écrire avec ChatGPT » dans le menu.
    Attendu : l'étincelle disparaît aussitôt, et la ligne macOS est choisie dans
    Réglages › Voie. Seule la section « macOS » s'affiche (état du modèle), sans
    CrisperWhisper ni « Conseillé pour vous ». Le texte d'en-tête de la carte
    macOS a été raccourci : il se lit d'un trait, sans phrase coupée. Dans le
    journal : « relais : page libérée ».

74. Réglages › Dictée : sous le déclencheur, la ligne « Changer de voie : »
    affiche « Aucun ». Clique dessus et tape ⌃⌥⌘V.
    Attendu : le raccourci s'affiche avec un bouton « Retirer ». Depuis TextEdit,
    ⌃⌥⌘V fait apparaître ou disparaître l'étincelle, et la coche du menu suit.
    Laisse le raccourci en place.

75. Dans ce même champ, tape ⌃⌥⌘H.
    Attendu : une note orange dit que la combinaison ouvre déjà l'historique.
    Si ton déclencheur est un « Raccourci clavier », tape aussi sa combinaison :
    la note dit qu'elle déclenche déjà la dictée, et la dictée marche toujours.
    Remets ⌃⌥⌘V.

76. Dans ce même champ, tape la combinaison de ton déclencheur (s'il est un
    « Raccourci clavier »), puis une combinaison qu'une autre application a déjà
    prise (celle de Raycast, d'Alfred ou d'un autre utilitaire que tu utilises).
    Ouvre le menu après chacune.
    Attendu : dans les deux cas, le menu affiche « Écrire avec ChatGPT » sans
    raccourci à côté. Remets ⌃⌥⌘V : il réapparaît dans le menu.

77. Quitte puis relance Caspr.
    Attendu : ⌃⌥⌘V est toujours là et marche, et la voie est celle d'avant le
    redémarrage. Finis cet essai sur la voie macOS.

### La voie macOS

78. Voie macOS, curseur dans TextEdit : dicte « Bonjour, ceci est un essai ».
    Attendu : l'aperçu en direct est visible sous la barre. Aucune pastille de
    modules, seulement les langues et Curseur/Notes. Pas de pastille COLLECTE.
    La phrase s'écrit au curseur, et l'historique montre une entrée macOS
    (Apple Intelligence). Réglages › Voie garde ses boutons actifs.

79. Pendant une dictée macOS, survole l'aperçu sous la barre.
    Attendu : l'infobulle dit « Le texte inséré peut différer », et non plus
    « Sans le lexique ».

80. Voie macOS, destination Notes : dicte.
    Attendu : le texte est ajouté au fichier de notes, et le curseur de TextEdit
    n'est pas touché. Remets « Curseur ».

81. Voie macOS : déclenche puis arrête sans parler (plus d'une demi-seconde).
    Attendu : la barre dit « Rien n'a été entendu » ou « Le moteur a répondu sans
    rien transcrire… ». Le menu propose « Réessayer avec le moteur (… s
    conservées) » et « Abandonner cet enregistrement ». Abandonner fait
    disparaître ces entrées.

82. Voie macOS, dictée en cours : appuie sur Échap.
    Attendu : la dictée est annulée. Coche ensuite « Écrire avec ChatGPT » : la
    page ChatGPT se charge bien (dans le journal, pas de verrou resté levé), et
    une dictée Brut marche. Repasse en macOS.

83. Voie macOS, relais calibré, en mode bascule : lance une dictée et parle
    5 s. Coche « Écrire avec ChatGPT » dans le menu (ou ouvre Réglages › Voie :
    les boutons de la carte ChatGPT sont grisés avec « Une dictée macOS est en
    cours. »). Parle encore 10 s, puis arrête.
    Attendu : tout le texte, fin comprise, est transcrit par macOS et s'insère.
    Le journal montre une crête non nulle (≈0,07, pas 0,000). La page ChatGPT ne
    se charge qu'après l'arrêt, et la dictée suivante part par ChatGPT (étincelle
    présente).

84. L'inverse. Voie ChatGPT, Réorganiser, curseur dans TextEdit : lance une
    dictée et, pendant l'écoute, décoche « Écrire avec ChatGPT » (voie macOS).
    Arrête et laisse finir.
    Attendu : la dictée va au bout par ChatGPT (le texte remanié s'insère), puis
    la page est détruite (journal : « relais : page libérée »). La dictée
    suivante part par macOS, avec une crête non nulle.

85. Pour garder la page d'un échec sur la voie macOS : refais l'essai 58
    (historique décoché, notes illisibles, Réorganiser) en décochant « Écrire
    avec ChatGPT » pendant l'écoute. La fenêtre du relais s'ouvre sur le texte à
    récupérer. Sans cliquer ailleurs, appuie sur la touche de dictée, remets
    « Curseur » sur la barre de Caspr en parlant, et dicte une phrase.
    Attendu : la fenêtre disparaît, TextEdit revient devant, et la phrase s'y
    écrit par macOS. Dans le journal : « insertion vers com.apple.TextEdit »,
    jamais Caspr. Remets ensuite le fichier de notes et l'historique en place.

86. Même scénario que l'essai 85, mais clique d'abord dans un autre éditeur
    (Notes, par exemple) avant de rappuyer sur la touche.
    Attendu : la fenêtre du relais part, la phrase s'écrit dans cet éditeur-là
    (journal : « insertion vers » son bundle), et Caspr n'est pas caché à tort.

87. Repasse en macOS, en français (modèle Apple Intelligence présent), et ouvre
    Réglages › Voie. La version n'est plus un réglage : Caspr la choisit seul.
    Attendu : la carte affiche « macOS · Apple Intelligence », et la ligne
    « Reconnaissance Vocale Apple » n'y est pas demandée, aperçu en direct
    allumé ou non (il tourne sur la même version). Elle ne l'est que sous la
    Dictée : c'est l'essai 88.

88. Voie macOS : choisis comme langue principale une langue dont le modèle Apple
    Intelligence n'est pas téléchargé, Wi-Fi coupé.
    Attendu : sous « Télécharger », une note propose la Dictée avec la ligne
    « Reconnaissance Vocale Apple » (sans « (Requis) »). Si le droit est déjà
    accordé, la carte affiche directement « macOS · Dictée ». Une dictée dans
    cette langue transcrit quand même, par la Dictée. Si elle échoue, « Insérer
    l'aperçu de macOS » dans le menu insère l'aperçu dans TextEdit, l'ajoute à
    l'historique, puis les entrées de recours disparaissent. Remets le français
    et le Wi-Fi.

89. Voie macOS, Réglages › Général : choisis comme langue active la langue de
    l'essai 88 (modèle Apple Intelligence absent).
    Attendu : une note sous le sélecteur dit soit que la Dictée écrit en
    attendant, soit ce qui manque (en avertissement), avec un renvoi à l'onglet
    Voie. Passe sur la voie ChatGPT : la note disparaît. Remets le français et la
    voie macOS.

90. Voie ChatGPT, fenêtre Réglages ouverte sur un autre onglet que Voie :
    Réglages › Voie › ChatGPT › « Se déconnecter… », confirme, puis choisis la
    ligne macOS. Coche maintenant « Écrire avec ChatGPT » dans le menu.
    Attendu : la voie ne bascule pas. Réglages s'ouvre sur l'onglet Voie. Clique
    la ligne ChatGPT : la fenêtre de connexion s'ouvre. Reconnecte-toi, puis
    vérifie qu'une dictée ChatGPT marche avec le calibrage existant.
    (Si la calibration démarre d'elle-même, c'est le cas de l'essai 92. Ne
    l'interromps pas, mais sache qu'elle envoie un message d'essai.)

91. Voie macOS, relais non calibré. Fais cet essai seulement après la section 6,
    ou saute-le. Pendant une dictée macOS, passe la voie à ChatGPT.
    Attendu : aucune fenêtre de calibration ne s'ouvre pendant la dictée. À
    l'arrêt, le texte s'insère, puis la fenêtre de calibration qui s'ouvre n'est
    pas cachée par l'insertion.

### Le reste de l'application (contrôle du 2 octobre)

91a. Voie macOS : dicte deux à trois minutes, arrête, et pendant
     « Transcription… » appuie sur la touche de dictée (ou ouvre le menu :
     « Interrompre la transcription » y est).
     Attendu : la barre disparaît, rien ne s'écrit, l'icône passe en erreur
     avec « Transcription interrompue — audio conservé ». Le menu propose
     « Réessayer avec le moteur », qui écrit le texte. Refais-le avec la croix
     de la barre, puis avec Échap : même chose, sans message d'erreur.
     Puis une dictée de quelques mots dans un champ de texte, Échap appuyé
     dès que la barre disparaît : le texte s'écrit, et Échap arrive au champ
     (Caspr ne le garde que tant que la barre est là).

91b. Voie macOS : pendant une dictée, connecte des AirPods (ou débranche un
     casque), puis continue de parler et arrête.
     Attendu : dans le journal, « micro changé (… → …), capture reprise », et
     la fin de la phrase est dans le texte. Si la capture n'a pas pu reprendre :
     le début s'écrit, et la barre dit « Micro changé : capture interrompue à
     m:ss ».

91c. Pendant l'attente d'une dictée ChatGPT (dès « ChatGPT transcrit… »),
     branche ou débranche un écran.
     Attendu : la barre revient telle qu'elle était, avec sa phase et sa
     sortie, et non en « en écoute… ».

91d. Réglages › Général, déclencheur « raccourci » : enregistre ⌃⌥⌘H.
     Attendu : un avertissement dit qu'il ouvre déjà l'historique. ⌃⌥⌘H
     déclenche la dictée, et le menu l'annonce. Remets ton raccourci.

91e. Ouvre le menu de la barre une heure après une dictée, puis efface
     l'historique depuis Réglages › Historique et rouvre le menu.
     Attendu : l'infobulle de la dernière entrée dit l'âge à jour, puis les
     entrées ont disparu du menu.

---

## 6. Les deux calibrations et l'accueil (en dernier : ils envoient de vrais messages et remettent l'app à zéro)

92. Sauvegarde l'état migré :
    `defaults export fr.lyriastudio.caspr ~/Desktop/caspr-apres-migration.plist`
    L'app n'a pas de bouton pour oublier le calibrage. Quitte donc Caspr, lance
    `defaults delete fr.lyriastudio.caspr relais.selecteurs && killall cfprefsd`,
    relance Caspr (la session ChatGPT reste ouverte), repasse sur macOS, puis
    choisis ChatGPT dans Réglages › Voie.
    Attendu : la fenêtre s'ouvre et la page met quelques secondes à charger.
    Ensuite, la question « Calibrer automatiquement » apparaît. JAMAIS d'alerte
    « D'abord, se connecter à ChatGPT ».

93. Refuse la question, repasse sur macOS, puis choisis ChatGPT dans Réglages ›
    Voie et reclique macOS aussitôt, pendant que la calibration automatique
    charge la page.
    Attendu : la page disparaît. Aucune alerte « ne répond pas » ni
    « inachevée » ne suit, et le relais n'est plus « en calibration » : une
    dictée macOS part normalement. Refais le geste par le menu (coche puis
    décoche « Écrire avec ChatGPT »), puis par le raccourci ⌃⌥⌘V (deux fois).
    Enfin, choisis ChatGPT, refuse la question, lance « Montrer à la main… » et
    repasse sur macOS pendant qu'il attend un repère : même attendu. Termine en
    choisissant ChatGPT pour retrouver la question.

94. Accepte et laisse faire.
    Attendu : le rapport « C'est appris » coche la zone de texte, le micro,
    l'arrêt, l'envoi et « copier » sous la réponse, et dit qu'un message d'essai
    est parti. Choisis « Montrer « Lire à haute voix »… », puis désigne-le sous
    la réponse (ouvre d'abord le menu « … » s'il s'y cache). En fermant, Caspr se
    cache. Cmd+V colle ce que contenait le presse-papiers avant la calibration.
    Refais l'essai 32 (bloc de code) : réponse entière, et « (paire) » ou
    « (repere) » dans le journal.

95. `defaults read fr.lyriastudio.caspr relais.selecteurs`
    Attendu : la zone de texte est `#prompt-textarea`, et le micro, l'arrêt et
    l'envoi sont des sélecteurs `data-testid`. Aucun sélecteur du filet (le
    repli générique) parmi les repères appris.

96. Mets une image (⌃⇧⌘4 sur une zone de l'écran) dans le presse-papiers, lance
    « Calibrer automatiquement… » et laisse aller jusqu'au bout. Fais ensuite
    ⌘V dans un document TextEdit en texte enrichi. Refais le tout avec un texte
    mis en forme copié depuis Safari.
    Attendu : c'est le contenu d'origine qui se colle, jamais « c'est noté ».
    Refais-le en fermant la fenêtre pendant l'essai de « copier » : même attendu.

97. Discuter : pose une question pour ouvrir une discussion. Lance ensuite
    « Calibrer automatiquement… » et clique « Abandonner » à l'annonce.
    Attendu : la discussion est fermée (voulu : la page est rechargée). À
    l'appui suivant, la barre attend « ChatGPT se prépare… », et la dictée part
    dans une conversation neuve, pas dans l'ancien fil.

98. Lance « Calibrer automatiquement… », abandonne pendant l'essai de
    « copier », puis clique « Montrer à la main… » dans les 5 secondes.
    Attendu : pendant tout le parcours manuel, l'occupation reste
    « calibration » : une dictée est refusée, même après ces 5 secondes.

99. « Montrer à la main… » : parcours les étapes (micro, arrêt, zone de texte,
    envoi, « copier »). À l'étape « copier », clique d'abord le « copier » de
    TON message, puis celui de la réponse. Avance jusqu'à l'étape 6 (« Lire à
    haute voix »), puis ne clique rien pendant 3 minutes.
    Attendu : le « copier » de ton message est refusé (« Pas ce bouton-là »),
    celui de la réponse est retenu. À la fin, un seul message, qui dit que
    Caspr sait dicter, envoyer, récupérer et faire lire à haute voix : la
    lecture désignée à l'essai 94 est gardée, et la capacité reste cochée dans
    Réglages › Voie. Une dictée Réorganiser marche ensuite.

100. Déconnecte-toi de ChatGPT DANS la fenêtre du relais, puis relance
     « Calibrer automatiquement… ».
     Attendu : après le chargement, l'alerte « D'abord, se connecter à ChatGPT »,
     qui finit par « La calibration reprendra d'elle-même… ». La fenêtre de
     connexion reste ouverte. Connecte-toi : quelques secondes après l'affichage
     de la conversation, « Calibrer automatiquement » revient tout seul.

101. Wi-Fi coupé, relance « Calibrer automatiquement… ».
     Attendu : au bout d'environ 30 s, l'alerte « La page ChatGPT ne répond pas »,
     et non « se connecter ». Son texte renvoie à Réglages › Voie (l'accueil est
     terminé). Rallume le Wi-Fi.

102. Remise à zéro pour l'accueil : quitte Caspr, puis lance
     `./scripts/reset-state.sh` depuis le worktree, et relance Caspr.
     Attendu : l'accueil s'ouvre sur « Bienvenue dans Caspr », avec « 1 / 5 ».
     Les trois principes sont « Écrivez au son de votre voix », « Deux façons de
     dicter » et « Aucun serveur Caspr ». Nulle part « 100 % sur votre puce
     Apple », CrisperWhisper ou « Rien à installer ».

103. « Commencer la configuration ».
     Attendu : « Votre Façon de Dicter », avec les lignes macOS et ChatGPT. Clique
     ChatGPT (non connecté) : la fenêtre ChatGPT s'ouvre, puis l'alerte
     « D'abord, se connecter à ChatGPT… La calibration reprendra d'elle-même… ».

104. Connecte-toi (adresse et mot de passe) dans cette fenêtre.
     Attendu : quelques secondes après la conversation, « Calibrer
     automatiquement » apparaît tout seul. Continue jusqu'à « C'est appris »,
     puis ferme : Caspr se cache et l'accueil revient au premier plan, au même
     écran.

105. Continue. L'écran des langues ne montre que les langues, sans « Vos
     habitudes d'expression ». À l'écran suivant :
     Attendu : titre « ChatGPT & Premier Essai », carte « Votre compte ChatGPT »
     avec « Connecté à ChatGPT » et les capacités cochées, sans carte « Moteur de
     reconnaissance ». Une fois le micro et l'accessibilité accordés, « Continuer »
     s'active. Clique dans la zone d'essai et dicte avec Brut : le texte arrive
     DANS la zone d'essai, et la fenêtre d'accueil ne disparaît pas.

106. Dernier écran.
     Attendu : « Voie : ChatGPT (votre compte, dans la page de Caspr) » et
     l'astuce « Passer de macOS à ChatGPT ». Clique Terminer. La touche écrit
     ensuite par ChatGPT.

107. À l'écran 3 (« Votre Façon de Dicter » ou suivant), quitte Caspr puis
     relance-le. Fais d'abord `./scripts/reset-state.sh` et avance jusque-là.
     Attendu : l'accueil rouvre sur le même écran.
     `defaults read fr.lyriastudio.caspr caspr.onboarding.screen` rend le nom de
     l'écran, et `caspr.onboarding.step` n'existe pas.

108. `./scripts/reset-state.sh`, avance jusqu'à l'écran des langues, puis ferme
     l'accueil au bouton rouge. Choisis « Réglages… » dans le menu.
     Attendu : la garde de configuration rouvre l'accueil à la place des
     Réglages, sur l'écran des langues, et le titre de sa fenêtre correspond à
     cet écran. Avance d'un écran : le titre suit.

109. Continue avec la voie macOS jusqu'à ce que la configuration minimale soit
     remplie (langue, micro, accessibilité, modèle), puis ferme l'accueil au
     bouton rouge. Dans Réglages › Voie, choisis ChatGPT, connecte-toi et laisse
     la calibration automatique aller au bout.
     Attendu : à la fermeture du rapport, l'accueil ne réapparaît pas. (Le cas
     normal est celui de l'essai 104 : lancée depuis l'accueil, la calibration le
     ramène à la fin.)

110. `./scripts/reset-state.sh`, choisis ChatGPT, puis ferme la fenêtre ChatGPT
     pendant l'attente de connexion.
     Attendu : aucune alerte (silence voulu). L'accueil revient. À l'écran du
     premier essai, la carte affiche « Configuration inachevée », et
     « Continuer » reste grisé avec « Caspr doit encore apprendre les boutons de
     la page ChatGPT. » ou « Connectez-vous à ChatGPT… ».

111. `./scripts/reset-state.sh`, choisis ChatGPT et ne te connecte pas : laisse
     l'attente de connexion expirer (10 minutes).
     Attendu : l'alerte « Toujours pas connecté » s'affiche, la fenêtre ChatGPT
     se range, et le texte renvoie à l'étape du premier essai de l'accueil, pas
     à Réglages › Voie. Refais l'essai par « Montrer à la main… » (parcours
     manuel) : même alerte, même renvoi.

112. `./scripts/reset-state.sh`, coupe le Wi-Fi, puis choisis ChatGPT.
     Attendu : au bout d'environ 30 s, l'alerte « La page ChatGPT ne répond pas »
     renvoie à l'accueil, et non à Réglages › Voie (après l'accueil, c'est
     l'essai 101). Rallume le Wi-Fi.

113. `./scripts/reset-state.sh`, puis choisis macOS.
     Attendu : l'écran du premier essai s'intitule « Moteur & Premier Essai »,
     avec la carte macOS seule (sans CrisperWhisper). Son texte d'en-tête,
     raccourci, se lit d'un trait. « Continuer » attend le modèle de la langue.
     Le récapitulatif affiche « macOS · … (hors ligne, rien ne sort du Mac) ».

114. À l'écran du premier essai, voie macOS (aucune page ChatGPT gardée) :
     clique dans la zone d'essai et dicte une phrase.
     Attendu : le texte arrive dans la zone d'essai, et Caspr reste devant.

115. Restauration : quitte Caspr, puis
     `defaults import fr.lyriastudio.caspr ~/Desktop/caspr-apres-migration.plist && killall cfprefsd`,
     et relance Caspr. Réaccorde le micro et l'accessibilité si macOS les
     redemande. Reconnecte-toi à ChatGPT par Réglages › Voie › « Ouvrir la
     fenêtre… ».
     Attendu : l'historique, le raccourci ⌃⌥⌘V, les langues et les modules sont
     revenus. La carte ChatGPT est calibrée, et une dictée ChatGPT (Brut) comme
     une dictée macOS marchent. Fais maintenant l'essai 91 si tu l'avais sauté.

---

## 7. Avant de publier : le site, le README

116. Ouvre `website/index.html` et `website/en.html` dans un navigateur.
     Attendu : la section « Deux voies » (tableau comparatif) est là. En largeur
     de téléphone, le tableau passe en blocs. Le texte animé du titre ne pousse
     pas la page. L'étape 8 du guide (bouton Télécharger) affiche l'icône de
     l'app. Plus aucun « 100 % local » ni CrisperWhisper. Les étapes 2 et 7 du
     guide, en FR comme en EN, ont un texte d'en-tête raccourci : relis-les.
     Reste à faire : une vraie capture du nouvel accueil pour l'étape 8.
     **Si les essais 26 à 30 ont prouvé l'écho**, trois phrases deviennent
     fausses et sont à corriger avant de publier : « The ChatGPT path has no
     preview » (`website/en.html` et `website/en/index.html`, ligne 274), la
     ligne « Aperçu en direct » du tableau de `website/index.html`, et « il n'y
     a pas d'aperçu en direct » dans la carte de la voie
     (`app/Sources/Caspr/Reglages/CarteVoie.swift`). Sinon, elles restent
     justes.

117. Relis le README et `app/RELAIS.md`.
     Attendu : ils décrivent deux voies, macOS et ChatGPT, et plus aucun moteur
     local, corpus, lexique ni mode. La mesure « 129 dictées, ~44 % de mots
     perdus par la Dictée » est citée : confirme qu'elle est juste, elle n'a pas
     été refaite. Vérifie aussi que le README ne dit nulle part que la voix reste
     sur le Mac en voie ChatGPT. RELAIS.md dit « Pas encore éprouvé dans l'app
     installée » de l'écho : si les essais 26 à 30 ont passé, c'est à retirer.

118. `./scripts/package-dmg.sh` (il réinstalle d'abord la build release dans
     /Applications, sans la lancer). Ouvre `dist/Caspr.dmg`, puis double-clique
     Caspr dans la fenêtre du volume.
     Attendu : le script passe. Il n'avait pas été exécuté depuis que son
     commentaire de la ligne 54 dit « avant de le lancer ». Le volume ne montre
     qu'une icône. Comme /Applications/Caspr.app existe, à la même version,
     la fenêtre propose « Ouvrir la copie installée », et ce bouton relance
     la copie de /Applications, pas celle du DMG. Une copie installée plus
     ancienne (une 0.14) donne « Ancienne version installée » et
     « Remplacer par la 0.15.0 », qui la remplace et rouvre la nouvelle.
     Quitte d'abord la copie installée : si elle tourne encore, `open` ne
     fait que la ramener au premier plan.

119. Quitte Caspr, mets l'app installée de côté (`mv /Applications/Caspr.app ~/Desktop/`),
     puis double-clique Caspr dans le DMG.
     Attendu : la fenêtre dit « Caspr peut s'installer dans Applications » avec
     « Applications » en gras, et non « **Applications » avec les astérisques,
     comme sur `website/images/07-Popup-souvre-installer-dans-application.png`.
     Les textes passent par `LocalizedStringKey` depuis ce correctif ; si
     les astérisques s'affichent encore, c'est un défaut. Ferme la
     fenêtre sans installer, éjecte le DMG, puis
     `mv ~/Desktop/Caspr.app /Applications/`.

120. Relis la section Gatekeeper du README (« The one-line equivalent… »).
     Attendu : la commande vise le fichier téléchargé,
     `xattr -d com.apple.quarantine ~/Downloads/Caspr.dmg`, à lancer **avant**
     de l'ouvrir — et non plus `/Applications/Caspr.app`, qui n'existe pas
     encore au premier refus. Sur un Mac qui n'a jamais eu Caspr, après cette
     commande, le DMG puis Caspr s'ouvrent sur la fenêtre d'installation, sans
     le refus de Gatekeeper.

121. Relis `release-notes/v0.15.0.md`.
     Attendu : il dit à qui met à jour ce qui disparaît (CrisperWhisper, corpus,
     lexique, modes), ce qui part à la Corbeille au premier lancement, et ce qui
     est gardé (calibrage, historique, raccourci, langues). Le paragraphe « Le
     lexique n'agit plus » dit où retrouver les mots (« Caspr — ancien
     lexique.txt », dans la Corbeille). Il dit aussi que ChatGPT prend le temps
     qu'il lui faut, que la touche renonce sans rien perdre et que la croix
     annule tout. Il ne promet pas encore l'aperçu sous ChatGPT : à ajouter si
     l'écho est prouvé. Ces notes s'affichent dans l'app après la release.

122. *Déjà fait* : la refonte est fusionnée dans `main`.

123. Après `./scripts/install.sh release`, refais une dictée Brut et une dictée
     Réorganiser sur la voie ChatGPT, puis une dictée macOS.
     Attendu : les trois s'écrivent au curseur, et la ligne de l'écho est là
     (essai 26).

124. Réseaux sociaux : les anciennes images de prévisualisation restent en cache
     à la même URL.
     Attendu : un lien partagé montre la nouvelle image. Sinon, force le
     rafraîchissement dans les outils de débogage de chaque réseau.

---

## 8. Après tout le reste : nettoyer la machine (à faire toi-même)

125. Vide la Corbeille. Elle contient ce que la migration y a mis (essais 10 à 12)
     et `Caspr-nettoyage-2026-09-23`, avec `Sofler.app`, `Caret.app` et les
     anciens .dmg.
     Attendu : la Corbeille est vide. C'est définitif : pense à l'essai 2 pour le
     corpus.

126. Supprime les restes d'app hors /Applications :
     `rm -rf ~/Desktop/projet-perso/CrispType/app/build/Caspr.app`
     (une vieille build dans le dépôt, encore enregistrée auprès de macOS), et
     `/Applications/Relais.app` si le prototype ne sert plus.
     Attendu : seul `/Applications/Caspr.app` reste.

127. Désinscris de Launch Services ce qui n'existe plus (c'est la source du
     « Sofler » dans Spotlight) :
     ```
     LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
     for v in "Sofler 0.1.2" "Sofler 0.1.2 1" "Sofler 0.1.3" "Sofler 0.1.7" "Sofler 0.1.8" \
              "Sofler 0.2.0" "Sofler 0.2.1" "Sofler 0.3.0" "Sofler 0.3.2" \
              "Caspr 0.9.1" "Caspr 0.10.0" "Caspr 0.11.0"; do
       app="/Volumes/$v/${v%% *}.app"; $LSR -u "$app"; $LSR -u "/Volumes/$v"
     done
     $LSR -u ~/Desktop/projet-perso/CrispType/relais/build/Relais.app
     $LSR -gc
     $LSR -dump | grep -E '^path:' | grep -i -E 'sofler|caret|relais|caspr' | sort -u
     ```
     Attendu : le dernier dump ne montre plus que `/Applications/Caspr.app`
     (ainsi que `/Applications/Relais.app` si tu l'as gardé). Dans Spotlight,
     taper « Sofler » ne propose plus rien. Au besoin, attends quelques minutes
     ou redémarre.

128. *Déjà fait le 23 septembre* : les 945 `caspr.tests.*.plist` laissés par les
     tests de migration sont dans la Corbeille (`caspr-tests-plists-2026-09-23`),
     et les tests n'en créent plus.
     Attendu : `ls ~/Library/Preferences | grep -c caspr.tests` rend 0.

129. Les caches des modèles locaux :
     - `~/.cache/huggingface` ne contient plus que `CACHEDIR.TAG` : si aucun autre
       projet n'utilise Hugging Face, `rm -rf ~/.cache/huggingface`.
     - `~/.cache/uv` pèse ~1,7 Go, surtout les dépendances Python de l'ancien
       moteur (torch…). `uv cache clean` le vide sans risque (tout se
       retélécharge à la demande). Si uv ne sert à aucun autre projet,
       `brew uninstall uv`.
     Attendu : `du -sh ~/.cache/*` ne montre plus rien de lié à CrisperWhisper ou
     Voxtral. Aucun modèle Voxtral ni Mistral n'a été trouvé sur le disque. Ses
     bancs (`poc/bench_voxtral.py`, `poc/probe_voxtral.py`) ne vivent plus que
     dans `main` avant la fusion, et partent avec elle.

130. Dernière vérification :
     `mdfind -name Sofler ; mdfind -name CrisperWhisper ; launchctl list | grep -i -E 'sofler|engine'`
     Attendu : rien de lié à l'app. Seul un fichier de tes notes privées
     (`docs/`, gitignoré) peut rester. Supprime-le si tu n'en veux plus.

---

## Ce que ces essais ne couvrent pas, et qui l'est ailleurs

Un appel JavaScript qui ne rend jamais la main (la touche et la croix
rendent la main en moins de 200 ms), cinq minutes de transcription, une
alerte apparue avant la demande, un relevé qui revient vide : rejoués sans
WebKit par `swift test` (`RelaisDicteeTests`, `RelaisVeilleTests`,
`AppelAnnulableTests`), parce qu'on ne sait pas les provoquer à la main.
