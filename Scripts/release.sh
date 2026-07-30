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

# `--dry-run` : imprime l'appcast qui SERAIT publié, sans rien construire ni pousser. Même
# esprit que `quick.sh --self-test` — c'est la seule partie de ce script qu'on peut vérifier
# sans créer une release publique.
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi

# Résumé de la version, en tête des notes (fenêtre Sparkle ET release GitHub). `quick.sh` y
# passe son message de commit ; en appel direct, un libellé neutre.
HEADLINE="${1:-Corrections et améliorations.}"

DIST_REPO="rimodev74/today-dist"
DIST_DIR=".dist"                  # clone local de DIST_REPO, gitignoré
DMG="Today-release.dmg"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"

# Source unique de vérité : make-app.sh
SHORT_VERSION=$(sed -n 's/^SHORT_VERSION="\(.*\)"$/\1/p' Scripts/make-app.sh)
BUILD=$(sed -n 's/^BUILD="\(.*\)"$/\1/p' Scripts/make-app.sh)
TAG="v${SHORT_VERSION}"

[[ -n "${SHORT_VERSION}" && -n "${BUILD}" ]] || { echo "✗ versions illisibles dans Scripts/make-app.sh"; exit 1; }

# Notes de version en HTML, source UNIQUE : Sparkle les rend telles quelles dans sa fenêtre
# (`<description>`) et GitHub accepte ce même sous-ensemble HTML dans le corps d'une release.
# Deux rédactions séparées auraient divergé au premier ajustement.
#
# Surtout PAS de `<sparkle:releaseNotesLink>` : Sparkle charge ce lien dans une WebView, et
# pointer la page d'une release GitHub affichait TOUTE la page (en-tête, navigation, pied)
# dans la petite fenêtre de mise à jour.
HEADLINE_HTML=$(printf '%s' "${HEADLINE}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

# `color-scheme` fait suivre au rendu l'apparence système : c'est la seule ligne nécessaire
# pour que ces notes ne soient pas un rectangle blanc en mode sombre. GitHub, lui, retire les
# `<style>` de ses corps de release — la balise y disparaît sans rien casser.
notes_html() {
  cat <<HTML
<style>
  :root { color-scheme: light dark; }
  body { font: -apple-system-body, -apple-system, system-ui; margin: 0; }
  h2 { margin: 0 0 .2em; font-size: 1.15em; }
  h3 { margin: 1.1em 0 .3em; font-size: 1em; }
  p, li { line-height: 1.45; }
  ol { padding-left: 1.2em; }
</style>
<h2>Today ${SHORT_VERSION}</h2>
<p>${HEADLINE_HTML}</p>
<h3>Première installation</h3>
<ol>
  <li>Ouvre le <code>.dmg</code> et glisse <strong>Today</strong> dans Applications.</li>
  <li>macOS affiche « Apple n'a pas pu vérifier que <em>Today</em> ne contient pas de logiciel
      malveillant » : l'app n'est pas notarisée. Va dans <strong>Réglages Système →
      Confidentialité et sécurité</strong>, puis <strong>Ouvrir quand même</strong>.</li>
</ol>
<p>À faire une seule fois : les mises à jour suivantes s'installent depuis l'app.</p>
HTML
}

# Le flux, dans une fonction pour que `--dry-run` puisse l'imprimer sans rien publier.
# `sparkle:version` = l'entier CFBundleVersion : c'est lui que Sparkle compare.
appcast_xml() {
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Today Updates</title>
    <link>https://raw.githubusercontent.com/${DIST_REPO}/main/appcast.xml</link>
    <description>Auto-updates for Today app</description>
    <!-- Généré par Scripts/release.sh — ne pas éditer à la main. -->
    <item>
      <title>Version ${SHORT_VERSION}</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
$(notes_html)
      ]]></description>
      <enclosure
        url="https://github.com/${DIST_REPO}/releases/download/${TAG}/${DMG}"
        length="${LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIG}" />
    </item>
  </channel>
</rss>
XML
}

if [[ "${DRY_RUN}" == true ]]; then
  ED_SIG="(signature calculée à la publication)"
  LENGTH="0"
  appcast_xml
  exit 0
fi

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
# L'app est signée avec un certificat local (pas notarisée) : Gatekeeper bloque la PREMIÈRE
# installation. Les mises à jour suivantes passent, Sparkle levant lui-même la
# quarantaine. Ces instructions disparaîtront le jour d'un certificat Developer ID.
gh release create "${TAG}" "${DMG}" -R "${DIST_REPO}" \
  --title "Today ${SHORT_VERSION}" \
  --notes "$(notes_html)"

echo "→ Publication de l'appcast dans ${DIST_REPO}…"
appcast_xml > "${DIST_DIR}/appcast.xml"

git -C "${DIST_DIR}" add appcast.xml
git -C "${DIST_DIR}" commit -q -m "appcast ${TAG} (build ${BUILD})"
git -C "${DIST_DIR}" push -q origin HEAD:main

echo
echo "✓ ${TAG} publiée : DMG + appcast en ligne dans ${DIST_REPO}."
