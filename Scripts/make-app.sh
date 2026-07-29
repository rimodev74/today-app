#!/bin/bash
# Empaquette un exécutable SwiftPM en vrai bundle .app (Info.plist + signature ad-hoc),
# pour que macOS applique la chrome de fenêtre native (coins arrondis Tahoe, etc.).
# Usage : ./Scripts/make-app.sh [debug|release] [NomDuProduit]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
TARGET="${2:-Today}"
APP="${TARGET}.app"
BIN=".build/${CONFIG}/${TARGET}"

# Source unique de vérité des versions — Scripts/release.sh les relit ici.
# BUILD est un entier incrémental : c'est lui que Sparkle compare.
SHORT_VERSION="0.3"
BUILD="2"

echo "→ Build ${TARGET} (${CONFIG})…"
swift build -c "${CONFIG}" --product "${TARGET}"

echo "→ Bundle ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks"
cp "${BIN}" "${APP}/Contents/MacOS/${TARGET}"
cp "Sources/App.icns" "${APP}/Contents/Resources/App.icns"
cp -r ".build/arm64-apple-macosx/${CONFIG}/Sparkle.framework" "${APP}/Contents/Frameworks/"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${TARGET}</string>
    <key>CFBundleDisplayName</key>     <string>${TARGET}</string>
    <key>CFBundleIdentifier</key>      <string>com.ryanmonnier.${TARGET}</string>
    <key>CFBundleExecutable</key>      <string>${TARGET}</string>
    <key>CFBundleIconFile</key>        <string>App</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleShortVersionString</key>    <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>SUFeedURL</key>               <string>https://raw.githubusercontent.com/rimodev74/today-app/main/appcast.xml</string>
    <key>SUPublicEDKey</key>           <string>fyuXhkBwVnpJBNSFH2AkeIqyVXCZo9V52foTzkNoZIo=</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSRemindersFullAccessUsageDescription</key> <string>Today crée des rappels dans l'app Rappels lorsque vous planifiez une tâche.</string>
</dict>
</plist>
PLIST

echo "→ Fix rpath…"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP}/Contents/MacOS/${TARGET}"

echo "→ Signature ad-hoc…"
codesign --force --sign - "${APP}"

echo "✓ ${APP} prêt. Lance-le avec :  open ${APP}"
