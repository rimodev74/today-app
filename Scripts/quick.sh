#!/bin/bash
# Publie tout en une commande : commit → version → release GitHub → appcast → push.
# L'app détecte la nouvelle version au prochain contrôle Sparkle (toutes les heures)
# ou immédiatement via Réglages → Général → Rechercher une mise à jour.
#
# Usage : git quick "message du commit" [version]
#   git quick "corrige le tri"        → 0.3 devient 0.4, build +1
#   git quick "refonte majeure" 1.0   → force 1.0, build +1
#
# Le message est aussi ce que lit la fenêtre de mise à jour : sa PREMIÈRE ligne résume,
# les suivantes deviennent des points. Les commits faits depuis la publication précédente
# s'y ajoutent tout seuls — mais le travail en cours n'est commis qu'après, donc lui n'est
# décrit que par ce message.
#   git quick "Sous-tâches et couleurs
#   Palette de 12 couleurs pour les projets
#   Sous-tâches réordonnables au glisser"
#
# Auto-test de la logique de version : ./Scripts/quick.sh --self-test
set -euo pipefail

cd "$(dirname "$0")/.."

MAKE_APP="Scripts/make-app.sh"

# Incrémente le dernier composant : 0.3 → 0.4, 1.0.2 → 1.0.3
bump_short() { awk -F. -v OFS=. '{ $NF += 1; print }' <<<"$1"; }

if [[ "${1:-}" == "--self-test" ]]; then
  # ponytail: un seul check, celui de la logique qui peut silencieusement déraper
  [[ "$(bump_short 0.3)"   == "0.4"   ]] || { echo "✗ 0.3 → $(bump_short 0.3)"; exit 1; }
  [[ "$(bump_short 0.9)"   == "0.10"  ]] || { echo "✗ 0.9 → $(bump_short 0.9)"; exit 1; }
  [[ "$(bump_short 1.0.2)" == "1.0.3" ]] || { echo "✗ 1.0.2 → $(bump_short 1.0.2)"; exit 1; }
  [[ "$(bump_short 2)"     == "3"     ]] || { echo "✗ 2 → $(bump_short 2)"; exit 1; }
  echo "✓ bump_short OK"
  exit 0
fi

MESSAGE="${1:-}"
FORCED_VERSION="${2:-}"

[[ -n "${MESSAGE}" ]] || {
  echo "✗ Message de commit manquant."
  echo "  Usage : git quick \"message du commit\" [version]"
  exit 1
}

# --- Garde-fous : échouer avant de toucher à quoi que ce soit ---------------
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ Pas un dépôt git."; exit 1; }

[[ -z "$(git ls-files --unmerged)" ]] || {
  echo "✗ Conflit de fusion en cours. Résous-le d'abord."
  exit 1
}

gh auth status >/dev/null 2>&1 || {
  echo "✗ gh n'est pas authentifié. Lance : gh auth login"
  exit 1
}

# Le DROIT d'écrire, pas seulement d'être connecté : `gh` a plusieurs comptes et
# un seul est actif. Actif sur le mauvais, tout le build passe (2 min) et c'est
# la création de la release qui échoue — sur un message trompeur parlant du scope
# « workflow », alors que c'est un 403 de permission.
gh api repos/rimodev74/today-dist -q '.permissions.push' 2>/dev/null | grep -qx true || {
  echo "✗ Le compte gh actif ($(gh api user -q .login 2>/dev/null || echo '?')) ne peut pas écrire"
  echo "  dans rimodev74/today-dist. Bascule dessus :"
  echo "      gh auth switch -u rimodev74 -h github.com"
  exit 1
}

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "${BRANCH}" != "HEAD" ]] || { echo "✗ HEAD détachée : place-toi sur une branche."; exit 1; }

CURRENT_SHORT=$(sed -n 's/^SHORT_VERSION="\(.*\)"$/\1/p' "${MAKE_APP}")
CURRENT_BUILD=$(sed -n 's/^BUILD="\(.*\)"$/\1/p' "${MAKE_APP}")
[[ -n "${CURRENT_SHORT}" && -n "${CURRENT_BUILD}" ]] || {
  echo "✗ Versions illisibles dans ${MAKE_APP}."
  exit 1
}

NEW_SHORT="${FORCED_VERSION:-$(bump_short "${CURRENT_SHORT}")}"
NEW_BUILD=$((CURRENT_BUILD + 1))

if gh release view "v${NEW_SHORT}" -R rimodev74/today-dist &>/dev/null; then
  echo "✗ La release v${NEW_SHORT} existe déjà. Passe une version explicite :"
  echo "    git quick \"${MESSAGE}\" 1.0"
  exit 1
fi

echo "→ ${CURRENT_SHORT} (build ${CURRENT_BUILD})  ⇒  ${NEW_SHORT} (build ${NEW_BUILD})"
echo

# --- Bump, avec restauration si la suite échoue -----------------------------
# La release GitHub est créée avant le commit : en cas d'échec, mieux vaut un
# dépôt intact qu'un numéro de version fantôme.
BACKUP=$(mktemp)
cp "${MAKE_APP}" "${BACKUP}"
restore_on_failure() {
  local code=$?
  if (( code != 0 )); then
    cp "${BACKUP}" "${MAKE_APP}"
    echo
    echo "✗ Échec — ${MAKE_APP} restauré (versions inchangées)."
    echo "  Si la release v${NEW_SHORT} a été créée, supprime-la :"
    echo "      gh release delete v${NEW_SHORT} -R rimodev74/today-dist --cleanup-tag"
  fi
  rm -f "${BACKUP}"
  exit $code
}
trap restore_on_failure EXIT

sed -i '' "s/^SHORT_VERSION=\".*\"$/SHORT_VERSION=\"${NEW_SHORT}\"/" "${MAKE_APP}"
sed -i '' "s/^BUILD=\".*\"$/BUILD=\"${NEW_BUILD}\"/" "${MAKE_APP}"

# Build, signature EdDSA, release GitHub et régénération de l'appcast. Le message sert aussi
# de résumé en tête des notes : sans lui, la fenêtre de mise à jour ne dit rien de ce qui change.
./Scripts/release.sh "${MESSAGE}"

# --- Un seul commit : tes modifs + le bump + l'apperçu signé ----------------
echo "→ Commit et push…"
git add -A
git commit -q -m "${MESSAGE}

Version ${NEW_SHORT} (build ${NEW_BUILD})."

# Le code seulement : le flux et les DMG vivent dans le dépôt de distribution,
# release.sh les y a déjà poussés.
git push -q origin "HEAD:${BRANCH}"

trap - EXIT
rm -f "${BACKUP}"

echo
echo "✓ v${NEW_SHORT} publiée (today-dist) et code poussé (${BRANCH})."
echo "  L'app la proposera au prochain contrôle (≤ 1 h), ou tout de suite via"
echo "  Réglages → Général → Rechercher une mise à jour."
