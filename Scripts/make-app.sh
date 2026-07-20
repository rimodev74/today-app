#!/bin/bash
# Empaquette un exécutable SwiftPM en vrai bundle .app (Info.plist + signature ad-hoc),
# pour que macOS applique la chrome de fenêtre native (coins arrondis Tahoe, etc.).
# Usage : ./Scripts/make-app.sh [debug|release] [NomDuProduit]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
TARGET="${2:-ThingsClone}"
APP="${TARGET}.app"
BIN=".build/${CONFIG}/${TARGET}"

echo "→ Build ${TARGET} (${CONFIG})…"
swift build -c "${CONFIG}" --product "${TARGET}"

echo "→ Bundle ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp "${BIN}" "${APP}/Contents/MacOS/${TARGET}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${TARGET}</string>
    <key>CFBundleDisplayName</key>     <string>${TARGET}</string>
    <key>CFBundleIdentifier</key>      <string>com.ryanmonnier.${TARGET}</string>
    <key>CFBundleExecutable</key>      <string>${TARGET}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleShortVersionString</key>    <string>0.1</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSRemindersFullAccessUsageDescription</key> <string>ThingsClone crée des rappels dans l'app Rappels lorsque vous planifiez une tâche.</string>
</dict>
</plist>
PLIST

echo "→ Signature ad-hoc…"
codesign --force --sign - "${APP}"

echo "✓ ${APP} prêt. Lance-le avec :  open ${APP}"
