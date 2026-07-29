#!/bin/bash
# Publie une version : build → DMG → signature EdDSA → release + appcast.
# Les versions se changent dans Scripts/make-app.sh (SHORT_VERSION / BUILD).
# Usage : ./Scripts/release.sh
#
# Le code source vit dans un dépôt privé ; la distribution doit rester publique
# (une app installée n'a pas les identifiants GitHub de son auteur). Les DMG et
# l'appcast partent donc dans DIST_REPO, qui ne contient rien de confidentiel.
set -euo pipefail

cd "$(dirname "$0")/.."

DIST_REPO="rimodev74/today-dist"
DIST_DIR=".dist"                  # clone local de DIST_REPO, gitignoré
DMG="Today-release.dmg"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"

# Source unique de vérité : make-app.sh
SHORT_VERSION=$(sed -n 's/^SHORT_VERSION="\(.*\)"$/\1/p' Scripts/make-app.sh)
BUILD=$(sed -n 's/^BUILD="\(.*\)"$/\1/p' Scripts/make-app.sh)
TAG="v${SHORT_VERSION}"

[[ -n "${SHORT_VERSION}" && -n "${BUILD}" ]] || { echo "✗ versions illisibles dans Scripts/make-app.sh"; exit 1; }

if gh release view "${TAG}" -R "${DIST_REPO}" &>/dev/null; then
  echo "✗ La release ${TAG} existe déjà dans ${DIST_REPO}."
  echo "  Incrémente SHORT_VERSION et BUILD dans Scripts/make-app.sh."
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

echo "→ Préparation de ${DIST_REPO}…"
if [[ -d "${DIST_DIR}/.git" ]]; then
  git -C "${DIST_DIR}" fetch -q origin
  git -C "${DIST_DIR}" reset -q --hard origin/main 2>/dev/null || true
else
  rm -rf "${DIST_DIR}"
  git clone -q "https://github.com/${DIST_REPO}.git" "${DIST_DIR}"
fi

# GitHub refuse de créer une release sur un dépôt sans aucun commit.
if ! git -C "${DIST_DIR}" rev-parse HEAD &>/dev/null; then
  cat > "${DIST_DIR}/README.md" <<'MD'
# Today — distribution

Ce dépôt public ne sert qu'à distribuer l'application **Today** :

- `appcast.xml` — le flux que l'app interroge pour détecter les mises à jour ;
- les *releases* — les `.dmg` téléchargeables, signés avec une clé EdDSA.

Le code source est privé. Tout ici est généré par `Scripts/release.sh`.

## Installation

Télécharge le `.dmg` de la [dernière release](../../releases/latest), ouvre-le
et glisse **Today** dans Applications. Les mises à jour suivantes s'installent
depuis l'app : *Réglages → Général → Rechercher une mise à jour*.
MD
  git -C "${DIST_DIR}" add README.md
  git -C "${DIST_DIR}" commit -q -m "Dépôt de distribution de Today"
  git -C "${DIST_DIR}" push -q origin HEAD:main
  git -C "${DIST_DIR}" branch -q -u origin/main 2>/dev/null || true
fi

echo "→ Publication du DMG dans ${DIST_REPO} (avant l'appcast, sinon 404)…"
# L'app est signée ad-hoc, pas notarisée : Gatekeeper bloque la PREMIÈRE
# installation. Les mises à jour suivantes passent, Sparkle levant lui-même la
# quarantaine. Ces instructions disparaîtront le jour d'un certificat Developer ID.
gh release create "${TAG}" "${DMG}" -R "${DIST_REPO}" \
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

echo "→ Publication de l'appcast dans ${DIST_REPO}…"
cat > "${DIST_DIR}/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Today Updates</title>
    <link>https://raw.githubusercontent.com/${DIST_REPO}/main/appcast.xml</link>
    <description>Auto-updates for Today app</description>
    <!-- Généré par Scripts/release.sh — ne pas éditer à la main.
         sparkle:version = l'entier CFBundleVersion : c'est lui que Sparkle compare. -->
    <item>
      <title>Version ${SHORT_VERSION}</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/${DIST_REPO}/releases/tag/${TAG}</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/${DIST_REPO}/releases/download/${TAG}/${DMG}"
        length="${LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIG}" />
    </item>
  </channel>
</rss>
XML

git -C "${DIST_DIR}" add appcast.xml
git -C "${DIST_DIR}" commit -q -m "appcast ${TAG} (build ${BUILD})"
git -C "${DIST_DIR}" push -q origin HEAD:main

echo
echo "✓ ${TAG} publiée : DMG + appcast en ligne dans ${DIST_REPO}."
