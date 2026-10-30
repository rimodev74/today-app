#!/bin/bash
# Fabrique un DMG distributable pour Today.
# Usage : ./Scripts/make-dmg.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="Today.app"
DMG_TEMP="Today-temp"
DMG_FINAL="Today-${CONFIG}.dmg"

echo "→ Crée le bundle…"
./Scripts/make-app.sh "${CONFIG}" Today

echo "→ Fabrique le DMG…"
rm -rf "${DMG_TEMP}" "${DMG_FINAL}"
mkdir -p "${DMG_TEMP}"
# Le dossier de travail part AUSSI en cas d'échec (hdiutil « ressource occupée », signature
# refusée) : laissé derrière, il bloquait la relance de quick.sh, qui refuse les fichiers non suivis.
trap 'rm -rf "${DMG_TEMP}"' EXIT

# `ditto` et JAMAIS `cp -r` : sur macOS, `cp -r` suit les liens symboliques et aplatit
# Sparkle.framework (plus de `Versions/`) — la signature de l'app devient invérifiable
# (« bundle format is ambiguous »). C'est ce qu'a livré le DMG v0.58 (constaté le 30 octobre
# 2026). Même raison que dans make-app.sh.
ditto "${APP}" "${DMG_TEMP}/${APP}"
# Refuser de fabriquer un DMG dont l'app ne se vérifie pas : c'est elle que Sparkle installe.
codesign --verify --deep --strict "${DMG_TEMP}/${APP}" || {
  echo "✗ La signature de l'app copiée ne se vérifie pas — DMG non créé." >&2
  rm -rf "${DMG_TEMP}"
  exit 1
}
# Lien vers Applications pour le glisser-déposer.
ln -s /Applications "${DMG_TEMP}/Applications"

# Crée l'image disque (500 Mo max, formatée APFS)
hdiutil create -volname "Today" \
               -srcfolder "${DMG_TEMP}" \
               -ov -format UDZO \
               -imagekey zlib-level=9 \
               "${DMG_FINAL}"

# Nettoie
rm -rf "${DMG_TEMP}"

echo "✓ ${DMG_FINAL} créé."
echo "  Distribution : partage ce fichier .dmg"
echo "  Utilisateur : double-clic → glisse Today dans Applications"
