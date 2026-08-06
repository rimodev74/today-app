#!/bin/bash
# Hook Stop : refuse de rendre la main tant que le projet ne compile pas ET ne passe pas ses tests.
#
# Sur Stop plutôt que sur chaque édition : une seule compilation par tour (~0,2 s incrémental)
# au lieu d'une par fichier touché, et aucune erreur parasite sur les états intermédiaires
# d'un refactor multi-fichiers.
#
# Les tests sont ici et pas seulement dans les scripts de publication parce que les deux cliquets
# qui protègent la VRAIE base (SchemaFingerprintTests, StoreFixtureTests) ne valent que s'ils
# tournent AVANT qu'on lance l'app — cf. « Rouge ⇒ ne pas lancer l'app » dans CLAUDE.md. Tant
# qu'ils dépendaient de la mémoire de celui qui code, la garantie la plus forte du projet était
# la seule sans exécution derrière. Coût mesuré : 1,9 s à chaud pour 239 tests.
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

# `swift build` seul ne construit pas la cible de tests : les deux commandes sont distinctes.
if ! out=$(swift test 2>&1); then
    {
        echo "swift test échoue — à corriger avant de conclure :"
        # Les deux frameworks coexistent ici et ne signalent pas pareil : XCTest écrit « error: »,
        # swift-testing écrit « recorded an issue » précédé d'un GLYPHE SF Symbols de la zone privée
        # Unicode (􀢄), pas d'un « ✘ ». Filtrer sur ce glyphe a été essayé : le hook sortait bien en
        # échec, mais avec un rapport VIDE — une panne muette pire que pas de test du tout. D'où le
        # filtre sur le TEXTE, et le repli ci-dessous : un rapport vide n'est jamais une réponse.
        report=$(printf '%s\n' "$out" | grep -E 'error:|recorded an issue|Test run .* failed')
        printf '%s\n' "${report:-$(printf '%s\n' "$out" | tail -15)}" | head -15
    } >&2
    exit 2
fi
