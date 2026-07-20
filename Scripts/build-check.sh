#!/bin/bash
# Hook Stop : refuse de rendre la main tant que le projet ne compile pas.
#
# Sur Stop plutôt que sur chaque édition : une seule compilation par tour (~0,2 s incrémental)
# au lieu d'une par fichier touché, et aucune erreur parasite sur les états intermédiaires
# d'un refactor multi-fichiers.
#
# Sortie 2 + stderr = les erreurs remontent à Claude, qui doit corriger avant de conclure.
set -uo pipefail
cd "$(dirname "$0")/.."

input=$(cat)

# Claude a déjà été relancé une fois par ce hook : on le laisse conclure pour éviter la boucle.
# ponytail: une seule tentative de correction automatique ; suffisant tant que les erreurs sont
# des fautes de frappe. Si des boucles « corrige → recasse » apparaissent, compter les passes.
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0

if ! out=$(swift build 2>&1); then
    {
        echo "swift build échoue — à corriger avant de conclure :"
        printf '%s\n' "$out" | grep -E 'error:' | head -15
    } >&2
    exit 2
fi
