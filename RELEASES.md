# Publier une version

## Le geste

```bash
git tag -a v0.9.0 -m "Caspr 0.9.0"
git push origin main --follow-tags
```

Le tag déclenche `.github/workflows/release.yml`, qui compile, signe, empaquette
le `.dmg`, le vérifie et publie la release. Rien d'autre n'est à faire à la
main : republier le même tag remplace simplement l'image attachée.

C'est un **tag** qui publie, jamais un push sur `main`. L'application compare
des versions publiées, pas des commits : un tag est la déclaration explicite que
cette version-ci est bonne à installer.

## Les notes de version ne sont pas décoratives

Le corps de la release **est lu par l'application**. `UpdateChecker` le
récupère, `ReleaseNotes.lines(from:)` le ramène à une liste de phrases, et
`ReleaseNotesList` l'affiche à deux endroits :

- la fenêtre « Caspr X est disponible », au lancement ;
- la carte « Mises à jour du Logiciel », dans Réglages › Général.

C'est la seule chose qui puisse motiver quelqu'un à remplacer un logiciel qui
lui convient. Une release sans corps affiche un bouton sans raison de le
presser.

### Où les écrire

Un fichier par version, nommé d'après le tag :

```
release-notes/v0.9.0.md
```

Le workflow le passe à `gh release create --notes-file`. **S'il manque**, il
retombe sur `--generate-notes` et laisse un avertissement dans le journal du
build : ça ne fait pas échouer la release — une note oubliée ne doit pas retenir
un correctif — mais les notes engendrées sont en anglais et suffixées de
`by @auteur in https://…`, donc nettement moins bonnes une fois dans la fenêtre.

### Comment les écrire

Une puce par changement, du point de vue de quelqu'un qui utilise Caspr — pas du
point de vue du dépôt.

```markdown
- Supprimer un modèle CrisperWhisper ne change plus la version de macOS retenue.
- Les nouveautés de chaque version s'affichent dans la fenêtre de mise à jour.
- L'icône de l'application apparaît enfin dans la fenêtre d'installation.
```

Ce qui est rendu, et ce qui ne l'est pas :

| Écrit | Affiché |
| :--- | :--- |
| `- Une phrase` | • Une phrase |
| `1. Une phrase` | • Une phrase |
| `Un paragraphe` | • Un paragraphe |
| `**gras**`, `` `code` `` | rendus |
| `## Titre`, `---` | retirés |
| `**Full Changelog**: …` | retiré |
| `… by @qui in https://…` | tronqué avant `by` |

Les règles sont testées dans `ReleaseNotesTests` — modifier le format demande
d'y passer.

Restez court : la liste défile dans une zone de 110 points. Dix puces valent
mieux que quarante, et les quarante lignes de `git log` ne sont pas des notes de
version.

## Le certificat de signature

Deux secrets doivent exister sur le dépôt, dans *Settings › Secrets and
variables › Actions* :

- `SIGNING_CERTIFICATE_P12` — le `.p12` encodé en base64
- `SIGNING_CERTIFICATE_PASSWORD` — son mot de passe

`./scripts/make-signing-cert.sh` les fabrique dans `dist/signing/`.

Sans eux, `codesign` signe **ad hoc** : l'exigence désignée du bundle devient un
`cdhash`, qui change à chaque build. macOS y voit alors une autre application et
**révoque l'autorisation d'accessibilité de tous les utilisateurs à chaque mise
à jour** — et `UpdateInstaller` refuse d'installer, à raison, puisque rien ne
prouve plus que la nouvelle version vient du même auteur. Le build ne casse pas
pour autant : il laisse un avertissement, et c'est tout ce qui distingue une
release utilisable d'une release qui casse les installations existantes.

Le jour d'un compte Apple Developer, on y met le *Developer ID Application* à la
place : rien d'autre ne change dans le workflow.

## Vérifier après coup

Le workflow refuse déjà de publier un paquet qui :

- ne passe pas `codesign --verify --deep --strict` ;
- n'a pas l'entitlement `audio-input` — sans lui le runtime durci refuse le
  micro **sans aucun dialogue**, et l'application paraît simplement muette.

Reste ce qu'aucune vérification automatique ne couvre : installer le `.dmg`
publié à la main, vérifier que l'accessibilité n'a pas sauté, puis publier la
version suivante et l'installer **par le bouton**. Il faut deux releases signées
d'affilée pour éprouver la mise à jour intégrée ; avant ça, on ne peut pas
promettre qu'elle marche.
