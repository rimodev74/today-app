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

# Copy l'app et ajoute un lien vers Applications pour le drag & drop
cp -r "${APP}" "${DMG_TEMP}/"
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
