#!/bin/bash
# Publie une version : build → DMG → signature EdDSA → appcast → release GitHub.
# Les versions se changent dans Scripts/make-app.sh (SHORT_VERSION / BUILD).
# Usage : ./Scripts/release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

REPO="rimodev74/today-app"
DMG="Today-release.dmg"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"

# Source unique de vérité : make-app.sh
SHORT_VERSION=$(sed -n 's/^SHORT_VERSION="\(.*\)"$/\1/p' Scripts/make-app.sh)
BUILD=$(sed -n 's/^BUILD="\(.*\)"$/\1/p' Scripts/make-app.sh)
TAG="v${SHORT_VERSION}"

[[ -n "${SHORT_VERSION}" && -n "${BUILD}" ]] || { echo "✗ versions illisibles dans Scripts/make-app.sh"; exit 1; }

if gh release view "${TAG}" -R "${REPO}" &>/dev/null; then
  echo "✗ La release ${TAG} existe déjà. Incrémente SHORT_VERSION et BUILD dans Scripts/make-app.sh."
  exit 1
fi

echo "→ Release ${TAG} (build ${BUILD})"
./Scripts/make-dmg.sh release

echo "→ Signature du DMG…"
# sign_update sort : sparkle:edSignature="…" length="…"
SIG_LINE=$("${SIGN_TOOL}" "${DMG}")
ED_SIG=$(echo "${SIG_LINE}" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(echo "${SIG_LINE}" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[[ -n "${ED_SIG}" && -n "${LENGTH}" ]] || { echo "✗ Signature échouée : ${SIG_LINE}"; exit 1; }

echo "→ Publication de la release GitHub (avant l'appcast, sinon le DMG serait en 404)…"
# L'app est signée ad-hoc, pas notarisée : Gatekeeper bloque la PREMIÈRE
# installation. Les mises à jour suivantes passent, Sparkle levant lui-même la
# quarantaine. Ces instructions disparaîtront le jour d'un certificat Developer ID.
gh release create "${TAG}" "${DMG}" -R "${REPO}" \
  --title "Today ${SHORT_VERSION}" \
  --notes "Version ${SHORT_VERSION} (build ${BUILD})

## Installation

1. Ouvre le \`.dmg\` et glisse **Today** dans Applications.
2. Au premier lancement, macOS affiche « Apple n'a pas pu vérifier que
   *Today* ne contient pas de logiciel malveillant ». C'est normal : l'app
   n'est pas notarisée par Apple. Pour l'autoriser :
   **Réglages Système → Confidentialité et sécurité**, puis
   **Ouvrir quand même** en bas de la section Sécurité.

À faire une seule fois : les mises à jour suivantes s'installent
directement depuis l'app (Réglages → Général → Rechercher une mise à jour)."

echo "→ Génération de appcast.xml…"
cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Today Updates</title>
    <link>https://raw.githubusercontent.com/${REPO}/main/appcast.xml</link>
    <description>Auto-updates for Today app</description>
    <!-- Généré par Scripts/release.sh — ne pas éditer à la main.
         sparkle:version = l'entier CFBundleVersion : c'est lui que Sparkle compare. -->
    <item>
      <title>Version ${SHORT_VERSION}</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/${REPO}/releases/tag/${TAG}</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/${REPO}/releases/download/${TAG}/${DMG}"
        length="${LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIG}" />
    </item>
  </channel>
</rss>
XML

echo
echo "✓ Release ${TAG} publiée, appcast.xml régénéré."
echo "  Dernière étape — publier le flux (c'est ce que l'app interroge) :"
echo "      git add appcast.xml && git commit -m \"appcast ${TAG}\""
echo "      git push origin HEAD:main"
