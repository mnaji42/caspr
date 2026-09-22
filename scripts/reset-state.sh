#!/usr/bin/env bash
# Remet Caspr dans l'état d'une première installation, pour éprouver l'accueil.
#
#   ./scripts/reset-state.sh          réglages, autorisations, session ChatGPT
#   ./scripts/reset-state.sh --all    + l'application elle-même
#
# On ne juge pas un premier lancement sur la machine qui l'a développé : les
# autorisations y sont déjà accordées, les réglages déjà choisis, ChatGPT déjà
# connecté, et l'accueil ne s'ouvre jamais. Après ce script, il s'ouvre comme
# chez quelqu'un qui installe Caspr pour la première fois.
set -euo pipefail

BUNDLE_ID="fr.lyriastudio.caspr"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ALL=0
case "${1:-}" in
    --all) ALL=1 ;;
    "") ;;
    *) echo "argument inconnu : $1" >&2; exit 2 ;;
esac

# --- Arrêter l'application ------------------------------------------------
# Caspr réécrit ses réglages en quittant, et WebKit sa session : les effacer
# pendant qu'il tourne les verrait réapparaître à la seconde suivante.
if pgrep -x Caspr >/dev/null 2>&1; then
    echo "▸ arrêt de Caspr"
    osascript -e 'quit app "Caspr"' 2>/dev/null || pkill -x Caspr || true
    sleep 1
fi

# --- Réglages et historique ------------------------------------------------
# Sauvegardés d'abord : le calibrage du relais se refait à la main, repère par
# repère, et `defaults delete` ne laisse rien derrière lui. La copie va dans
# `scratch/`, que git ignore — elle contient l'historique des dictées — et non
# dans le dossier de support de Caspr, que l'application vide à son lancement.
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    BACKUP_DIR="$ROOT/scratch/reglages"
    mkdir -p "$BACKUP_DIR"
    BACKUP="$BACKUP_DIR/$(date +%Y-%m-%dT%H-%M-%S).plist"
    defaults export "$BUNDLE_ID" "$BACKUP"
    echo "▸ réglages sauvegardés"
    echo "  $BACKUP"
    echo "  restauration : defaults import $BUNDLE_ID \"\$fichier\""
fi

echo "▸ effacement des réglages et de l'historique"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
# Le cache de préférences garde une copie en mémoire, qui réécrirait le
# fichier qu'on vient de supprimer.
killall cfprefsd 2>/dev/null || true

# --- Session ChatGPT -------------------------------------------------------
# La page du relais garde ses cookies, donc la connexion au compte, là où
# WebKit range les données d'une application : sous son identifiant, hors du
# bundle. Sans ce ménage, l'accueil trouverait ChatGPT déjà connecté.
# Chemins littéraux, jamais construits d'une variable qui pourrait être vide.
echo "▸ effacement de la session ChatGPT"
rm -rf "$HOME/Library/WebKit/fr.lyriastudio.caspr"
rm -rf "$HOME/Library/Caches/fr.lyriastudio.caspr"
# Le dossier, et le fichier de cookies `.binarycookies` posé à côté.
rm -rf "$HOME/Library/HTTPStorages/fr.lyriastudio.caspr"*

# --- Autorisations ---------------------------------------------------------
# Sans ça, l'accueil s'ouvrirait avec le micro et l'accessibilité déjà
# accordés — c'est-à-dire sans montrer ce qu'on cherche justement à vérifier.
# La reconnaissance vocale aussi : la Dictée de macOS la demande.
echo "▸ révocation des autorisations"
for service in Microphone Accessibility SpeechRecognition; do
    tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 \
        || echo "  ($service : rien à révoquer)"
done

if [ "$ALL" -eq 0 ]; then
    cat <<EOF

  Réinitialisé : réglages, historique, calibrage du relais, session ChatGPT
  et autorisations. Relancez Caspr : l'accueil s'ouvrira comme au premier jour.

  Pour retirer aussi l'application : ./scripts/reset-state.sh --all
EOF
    exit 0
fi

# --- L'application ---------------------------------------------------------
if [ -e "/Applications/Caspr.app" ]; then
    echo
    printf "  Supprimer définitivement /Applications/Caspr.app ? Taper « supprimer » : "
    read -r answer
    [ "$answer" = "supprimer" ] || { echo "  annulé — l'application reste."; exit 1; }
    rm -rf "/Applications/Caspr.app"
    echo "▸ application supprimée"
fi

# Ce qui reste est nommé : annoncer « tout est supprimé » serait faux.
cat <<EOF

  Réinitialisé, application comprise. Restent en place :
    - l'ouverture à la connexion, si elle était activée
      (Réglages Système › Général › Ouverture) ;
    - votre fichier de notes, qui est votre document ;
    - les restes d'une version d'avant septembre 2026 (moteur local, modèle,
      corpus) : c'est Caspr qui les met à la corbeille à son lancement, ou
      son désinstalleur.

  Pour réinstaller : ./scripts/install.sh
EOF
