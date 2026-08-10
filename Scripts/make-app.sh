#!/bin/bash
# Empaquette un exécutable SwiftPM en vrai bundle .app (Info.plist + signature), pour que macOS
# applique la chrome de fenêtre native (coins arrondis Tahoe, etc.).
# Usage : ./Scripts/make-app.sh [debug|release] [NomDuProduit]
set -euo pipefail

# Identité de signature STABLE (certificat local auto-signé, cf. Trousseau d'accès) plutôt
# qu'ad-hoc (`--sign -`) : une signature ad-hoc change à chaque build, donc macOS considère
# l'app comme "nouvelle" et redemande l'accès Rappels/Calendrier à CHAQUE lancement, même déjà
# autorisé. Signer toujours avec la même identité garde l'autorisation d'un build à l'autre.
SIGN_IDENTITY="Today Local Dev"

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
TARGET="${2:-Today}"
APP="${TARGET}.app"
# Le produit SwiftPM s'appelle "Today" quel que soit TARGET (cf. Package.swift, un seul .executable) —
# TARGET ne nomme que le bundle et l'exécutable EMBARQUÉ, copié sous ce nom juste après.
BIN=".build/${CONFIG}/Today"

# Source unique de vérité des versions — Scripts/release.sh les relit ici.
# BUILD est un entier incrémental : c'est lui que Sparkle compare.
SHORT_VERSION="0.34"
BUILD="33"

# Reconstruire par-dessus une instance EN COURS lui retire son Info.plist sous les pieds (le
# `rm -rf` plus bas) : la moindre lecture CFBundle ensuite — AppKit en fait une à chaque réveil de
# l'icône de barre de menus — lève une exception Objective-C et l'app meurt en « Abort trap: 6 »,
# sans le moindre rapport avec le code qu'on vient d'écrire. C'est LE plantage fantôme de la phase
# de dev. `run.sh` tue l'instance avant d'arriver ici ; les appels directs, eux, s'arrêtent net.
if pgrep -x "${TARGET}" >/dev/null 2>&1; then
  echo "✗ ${TARGET} tourne déjà (PID $(pgrep -x "${TARGET}" | tr '\n' ' '))." >&2
  echo "  Ferme-le, ou passe par ./run.sh qui s'en charge — reconstruire sous ses pieds le fait planter." >&2
  exit 1
fi

echo "→ Build ${TARGET} (${CONFIG})…"

# Le build est CAPTURÉ, pas déversé à l'écran, et pour une raison qui n'est pas cosmétique.
#
# Il reste ~40 avertissements, tous le MÊME : `SortDescriptor(\Model.x)` et `#Predicate` veulent un
# chemin de clé `Sendable`, qu'un `@Model` SwiftData ne peut pas être. C'est un trou entre SwiftData
# et Swift 6 — le code d'Apple déclenche l'avertissement d'Apple, via ses propres macros — et le
# taire d'un `@unchecked Sendable` serait un mensonge (ce sont des classes mutables).
#
# En release, chacun s'affiche avec toute son expansion de macro : plusieurs centaines de lignes,
# dans lesquelles un avertissement NEUF passerait parfaitement inaperçu. Or c'est exactement lui
# qu'on veut voir — le cliquet posé dans `Package.swift` porte sur leur NATURE, pas sur leur nombre
# (celui-ci dépend du mode de compilation et de ce qui a été recompilé).
#
# D'où : on résume les connus, et on S'ARRÊTE sur tout ce qui n'en est pas.
#
# ATTENTION, et c'est le piège qui m'a eu en écrivant ce garde-fou : un build INCRÉMENTAL ne
# réaffiche pas les avertissements des fichiers qu'il ne recompile pas. Mesuré ici même — 0
# avertissement vu quand il n'y a rien à refaire, 42 après un `touch` de tout. Un contrôle posé sur
# un build incrémental donne donc un feu vert sans avoir rien regardé, ce qui est pire que pas de
# contrôle du tout. D'où les deux comportements ci-dessous : la publication force un build COMPLET,
# et l'itération rapide dit franchement qu'elle ne peut pas conclure.
BUILD_LOG=$(mktemp)
trap 'rm -f "${BUILD_LOG}"' EXIT

if [[ "${FULL_WARNING_CHECK:-}" == "1" ]]; then
  echo "  (contrôle complet : recompilation de tout le module)"
  find Sources -name '*.swift' -exec touch {} +
fi

if ! swift build -c "${CONFIG}" --product Today >"${BUILD_LOG}" 2>&1; then
  cat "${BUILD_LOG}" >&2
  echo "✗ La compilation a échoué." >&2
  exit 1
fi

KNOWN=$(grep -c "warning:.*ReferenceWritableKeyPath" "${BUILD_LOG}" || true)
UNKNOWN=$(grep "warning:" "${BUILD_LOG}" | grep -v "ReferenceWritableKeyPath" || true)

if ! grep -q "Compiling" "${BUILD_LOG}"; then
  # Rien recompilé : le journal est vide de tout diagnostic, y compris de ceux qui existent. Ne PAS
  # afficher un ✓ ici — ce serait exactement le mensonge que ce contrôle est censé empêcher.
  echo "  · Rien à recompiler — contrôle des avertissements non concluant."
elif [[ -n "${UNKNOWN}" ]]; then
  echo >&2
  echo "✗ Avertissement d'une nature INCONNUE — ce n'est pas un chemin de clé :" >&2
  echo "${UNKNOWN}" | sed 's/^/    /' >&2
  echo >&2
  echo "  Le cliquet du projet porte là-dessus : tout ce qui n'est pas" >&2
  echo "  \`SortDescriptor(\\Model.x)\` / \`#Predicate\` est une vraie régression, à corriger" >&2
  echo "  sur-le-champ et non à ajouter au décompte (cf. CLAUDE.md, dette n°3)." >&2
  echo >&2
  echo "  Pour publier quand même (nouvel Xcode, dépréciation externe…) :" >&2
  echo "      ALLOW_NEW_WARNINGS=1 $0 $*" >&2
  [[ "${ALLOW_NEW_WARNINGS:-}" == "1" ]] || exit 1
  echo "  → ALLOW_NEW_WARNINGS=1 : on continue malgré tout." >&2
else
  echo "  ✓ ${KNOWN} avertissements, tous des chemins de clé (connu, cf. CLAUDE.md)"
fi

echo "→ Bundle ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks"
cp "${BIN}" "${APP}/Contents/MacOS/${TARGET}"
cp "Sources/App.icns" "${APP}/Contents/Resources/App.icns"
# `ditto` et PAS `cp -r` : un framework versionné n'est qu'une arborescence de liens symboliques
# (`Sparkle` → `Versions/Current/Sparkle`, idem Autoupdate, Resources, XPCServices). `cp -r` les
# SUIT et copie les cibles — mesuré : 3,0 Mo deviennent 8,9 Mo, chaque binaire présent deux fois,
# et le bundle n'a plus la forme d'un framework versionné. Conséquence : la signature ne se vérifie
# plus (`codesign --verify --deep --strict` sort en erreur, « bundle format is ambiguous »), or
# c'est exactement ce sceau que Sparkle compare entre l'app installée et celle qu'il télécharge
# avant d'installer une mise à jour.
ditto ".build/arm64-apple-macosx/${CONFIG}/Sparkle.framework" \
      "${APP}/Contents/Frameworks/Sparkle.framework"

# Sparkle uniquement sur la vraie app : sinon une build de dev, à jour du feed public, s'auto-
# remplacerait par la release publiée — silencieusement, alors qu'on est en train de la tester.
SPARKLE_KEYS=""
if [[ "${TARGET}" == "Today" ]]; then
  SPARKLE_KEYS='    <key>SUFeedURL</key>               <string>https://raw.githubusercontent.com/rimodev74/today-dist/main/appcast.xml</string>
    <key>SUPublicEDKey</key>           <string>fyuXhkBwVnpJBNSFH2AkeIqyVXCZo9V52foTzkNoZIo=</string>'
fi

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
${SPARKLE_KEYS}
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSRemindersFullAccessUsageDescription</key> <string>Today crée des rappels dans l'app Rappels lorsque vous planifiez une tâche.</string>
    <key>NSCalendarsFullAccessUsageDescription</key> <string>Today affiche les événements de votre calendrier sur la page Aujourd'hui.</string>
    <key>NSAppleEventsUsageDescription</key> <string>Today met votre musique en marche pendant un pomodoro et la fait descendre avant la fin de la phase.</string>
</dict>
</plist>
PLIST

echo "→ Fix rpath…"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP}/Contents/MacOS/${TARGET}"

echo "→ Signature (${SIGN_IDENTITY})…"
codesign --force --sign "${SIGN_IDENTITY}" "${APP}"

echo "✓ ${APP} prêt. Lance-le avec :  open ${APP}"
