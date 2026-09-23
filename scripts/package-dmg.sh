#!/usr/bin/env bash
# Fabrique le .dmg de distribution : Caspr.app, seule dans la fenêtre.
# Une seule icône, donc un seul geste possible : double-cliquer.
#
# Le fichier s'appelle toujours Caspr.dmg, sans numéro de version. C'est ce
# qui rend l'URL de téléchargement stable — la landing page pointe une fois
# sur .../releases/latest/download/Caspr.dmg et n'est plus jamais à modifier.
# La version reste lisible : elle nomme le volume monté, et elle est dans le
# bundle.
#
# Ce paquet est signé ad hoc, pas avec un certificat Apple Developer. Sur une
# autre machine, macOS refusera de l'ouvrir au premier essai ; l'utilisateur
# devra passer par Réglages Système › Confidentialité et sécurité. C'est
# assumé pour l'instant et documenté dans le README — pas un oubli.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Caspr"
. "$ROOT/scripts/version.sh"
DMG="$ROOT/dist/$APP_NAME.dmg"

"$ROOT/scripts/install.sh" release --no-launch

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "▸ préparation de l'image"
cp -R "$ROOT/app/build/$APP_NAME.app" "$STAGE/"

# Pas de raccourci vers /Applications, et c'est le cœur du sujet.
#
# La disposition habituelle — l'application à côté d'une flèche vers
# Applications — pose deux icônes qui se ressemblent à un centimètre l'une de
# l'autre. On glisse la première, elle reste affichée, et c'est celle-là qu'on
# double-clique ensuite. macOS exécute alors une copie en lecture seule, et
# tout ce qui suit casse sans jamais se nommer : autorisations attachées à un
# chemin temporaire, quarantaine impossible à retirer, mise à jour refusée,
# désinstallation sans rien à retirer. Quatre pannes diagnostiquées une à une
# avant qu'on remonte à ce double-clic.
#
# Depuis que l'application s'installe elle-même au premier lancement — elle se
# copie dans Applications, retire la quarantaine, éjecte l'image et rouvre la
# bonne copie — le glisser-déposer ne sert plus à rien. Retirer le raccourci
# laisse une seule icône dans la fenêtre, donc un seul geste possible, donc
# plus de mauvais choix à faire. C'est plus sûr qu'une flèche dessinée qui
# explique quoi faire : il n'y a plus rien à expliquer.

mkdir -p "$ROOT/dist"
rm -f "$DMG"

echo "▸ création du .dmg"
# Le nom du volume porte la version : c'est ce que l'utilisateur voit dans le
# Finder quand l'image est montée, et le seul endroit où il peut vérifier ce
# qu'il installe avant de le lancer.
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "▸ prêt : $DMG  ($VERSION, build $BUILD)"

if [ "$IS_RELEASE" != 1 ]; then
    cat <<'EOF'

  ⚠ Ce build ne correspond pas exactement à un tag, ou l'arbre a des
    modifications non commitées. Il est bon pour un essai, pas pour une
    release : l'app se signalera comme build de développement et ne
    proposera aucune mise à jour.
EOF
fi

cat <<'EOF'

  Le jour où le compte Apple Developer sera pris, il restera à :
    - codesign --options runtime avec le certificat Developer ID Application
    - xcrun notarytool submit --wait && xcrun stapler staple
  Les deux se branchent dans .github/workflows/release.yml, qui prévoit déjà
  l'emplacement des secrets.
EOF
