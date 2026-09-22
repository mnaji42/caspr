#!/usr/bin/env bash
# Compile Caspr et l'installe dans /Applications.
#
# /Applications est l'emplacement canonique, y compris en développement :
# c'est là que macOS s'attend à trouver une app dans le sélecteur des
# Réglages Système, et ça correspond à ce que fera le .dmg. Le bundle n'est
# jamais laissé dans le dépôt.
#
#   ./scripts/install.sh              compile en debug et installe
#   ./scripts/install.sh release      compile optimisé
#   ./scripts/install.sh --no-launch  installe sans relancer
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/app"
BUNDLE_ID="fr.lyriastudio.caspr"
APP_NAME="Caspr"
INSTALL_PATH="/Applications/$APP_NAME.app"

# VERSION, BUILD, DESCRIBE, IS_RELEASE — dérivés du tag git, jamais recopiés
# à la main : l'app compare sa propre version à celle de la dernière release.
. "$ROOT/scripts/version.sh"

CONFIG="debug"
LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        release|debug) CONFIG="$arg" ;;
        --no-launch)   LAUNCH=0 ;;
        *) echo "argument inconnu : $arg" >&2; exit 2 ;;
    esac
done

# --- 1. certificat stable ------------------------------------------------
# CASPR_SIGN_IDENTITY laisse un appelant imposer une identité déjà présente
# dans un trousseau — c'est ce que fait la CI, qui importe le certificat de
# distribution dans un trousseau temporaire. Sans cette porte, install.sh
# créerait un certificat dans le trousseau de session, qui n'existe pas sur un
# runner, et la release serait signée par une identité différente à chaque
# exécution : les autorisations d'accessibilité sauteraient à chaque mise à
# jour chez tous les utilisateurs.
#   non défini ou vide → certificat de développement local (dev-cert.sh)
#   "-"                → signature ad hoc, sans aucun trousseau
#   une empreinte      → cette identité, déjà importée par l'appelant
#
# Le cas "-" existe pour les machines sans trousseau de session déverrouillé,
# c'est-à-dire les runners d'intégration continue. Sans lui, dev-cert.sh y
# lançait un `security import` qui attendait indéfiniment une saisie que
# personne ne peut donner : le build ne plantait pas, il pendait.
if [ "${CASPR_SIGN_IDENTITY:-}" = "-" ]; then
    CERT_HASH="-"
    echo "▸ signature ad hoc (aucun certificat fourni)"
elif [ -n "${CASPR_SIGN_IDENTITY:-}" ]; then
    CERT_HASH="$CASPR_SIGN_IDENTITY"
else
    CERT_HASH="$("$ROOT/scripts/dev-cert.sh" | tail -1)"
fi

# --- 2. compilation ------------------------------------------------------
echo "▸ compilation ($CONFIG)"
cd "$APP_DIR"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

# --- 3. assemblage du bundle --------------------------------------------
STAGE="$APP_DIR/build/$APP_NAME.app"
echo "▸ assemblage du bundle"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BINARY" "$STAGE/Contents/MacOS/$APP_NAME"

# L'icône. Sans elle macOS affiche le rectangle blanc générique — y compris
# dans Réglages Système › Accessibilité, là où l'utilisateur doit reconnaître
# ce à quoi il accorde le droit de piloter son clavier. Le .icns vit hors de
# $STAGE, que l'on vient d'effacer, pour survivre d'un build à l'autre.
"$ROOT/scripts/make-icon.sh"
cp "$APP_DIR/build/$APP_NAME.icns" "$STAGE/Contents/Resources/$APP_NAME.icns"
# Le catalogue des langues voyage en données, pas en code : il se tient à
# jour sans recompiler.
cp "$APP_DIR/Sources/Caspr/Resources/languages.json" \
   "$STAGE/Contents/Resources/languages.json"
# Les icônes vectorielles : barre de menus et fenêtres.
mkdir -p "$STAGE/Contents/Resources/icons"
cp "$APP_DIR"/Sources/Caspr/Resources/icons/*.svg \
   "$STAGE/Contents/Resources/icons/"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>         <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>            <string>$BUILD</string>
    <key>CFBundleIconFile</key>           <string>$APP_NAME</string>
    <!-- 14.0 et non 26.0, alors que le moteur Apple exige macOS 26. C'est
         délibéré : avec 26.0 ici, macOS refuse le lancement lui-même, avec un
         dialogue générique qui ne dit ni pourquoi ni quoi faire. En laissant
         l'app démarrer, l'accueil peut expliquer la situation et proposer une
         issue. Les usages de l'API 26 sont gardés par des tests
         de disponibilité à l'exécution.
         (Pas de backtick dans ce heredoc : il est non quoté, pour que les
         variables s'y développent, donc bash y verrait une substitution.) -->
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <!-- Diagnostic : distingue le bundle d'une release d'un build local, que
         CFBundleShortVersionString seul confond. Lu par les Réglages, et par
         la vérification de mise à jour qui se tait sur un build de dev. -->
    <key>CasprGitDescribe</key>          <string>$DESCRIBE</string>
    <key>CasprIsRelease</key>            <$([ "$IS_RELEASE" = 1 ] && echo true || echo false)/>
    <!-- Barre de menus seule : pas d'icône au Dock, jamais de vol de focus,
         ce qui est indispensable puisque le texte doit atterrir dans l'app
         que l'utilisateur a devant lui. -->
    <key>LSUIElement</key>                <true/>
    <!-- Vrai pour chacune des deux voies : c'est le micro de Caspr que la page
         ChatGPT du relais emprunte, et ce qu'elle entend part chez ChatGPT.
         Promettre « jamais envoyé ailleurs » serait faux dès le relais allumé. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Caspr transcrit votre voix en texte. Avec macOS, l'audio ne quitte pas votre Mac ; avec ChatGPT, il passe par votre propre compte ChatGPT.</string>
    <!-- Seule la Dictée de macOS (SFSpeechRecognizer) demande ce droit :
         quand elle transcrit à la place d'Apple Intelligence, ou quand c'est
         elle qui tient l'aperçu en direct. Elle est forcée sur l'appareil. -->
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Caspr s'en sert quand la Dictée de macOS transcrit à la place d'Apple Intelligence, et pour l'aperçu affiché pendant que vous parlez. La reconnaissance a lieu sur votre Mac.</string>
</dict>
</plist>
PLIST

echo "▸ signature (certificat $CERT_HASH)"
# --options runtime sera exigé par la notarisation ; il impose en retour de
# déclarer explicitement l'accès micro, faute de quoi le runtime le refuse
# sans qu'aucun dialogue n'apparaisse.
codesign --force --sign "$CERT_HASH" --identifier "$BUNDLE_ID" \
         --options runtime --timestamp=none \
         --entitlements "$APP_DIR/Caspr.entitlements" "$STAGE" 2>/dev/null

if ! codesign -d --entitlements - "$STAGE" 2>/dev/null | grep -q "audio-input"; then
    echo "  ✗ entitlement micro absent — le micro serait muet" >&2
    exit 1
fi
echo "  entitlement micro présent"

# --- 4. installation -----------------------------------------------------
# Remplacer le bundle sous une app qui tourne laisse un process orphelin
# pointant sur des fichiers supprimés.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "▸ arrêt de l'instance en cours"
    osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -x "$APP_NAME" || true
    for _ in $(seq 1 20); do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.25
    done
fi

echo "▸ installation dans $INSTALL_PATH"
rm -rf "$INSTALL_PATH"
cp -R "$STAGE" "$INSTALL_PATH"

# Le cache de services de lancement garde une trace de l'ancien bundle ;
# sans ça, les Réglages Système peuvent afficher une entrée périmée.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_PATH" 2>/dev/null || true

echo "▸ vérification"
codesign --verify --deep --strict "$INSTALL_PATH" && echo "  signature valide"
codesign -d -r- "$INSTALL_PATH" 2>&1 | grep -F "designated =>" | sed 's/^/  /'

if [ "$LAUNCH" -eq 1 ]; then
    echo "▸ lancement"
    open "$INSTALL_PATH"
fi

cat <<EOF

  installé : $INSTALL_PATH

  Si l'accessibilité n'est pas encore accordée :
    Réglages Système › Confidentialité et sécurité › Accessibilité → ajouter Caspr

  Grâce au certificat stable, cette autorisation persiste d'un build à l'autre.
  Elle n'est à refaire que si le certificat change (cf. scripts/dev-cert.sh).
EOF
