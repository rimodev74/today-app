#!/bin/bash
# Lance l'app : compile → empaquette en .app → ouvre. Usage : ./run.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

# Deux raisons de ne pas tuer l'ancienne instance, toutes deux silencieuses avec un
# simple `killall … || true` : SIGTERM est intercepté par le debugger Xcode (le process
# se fige au lieu de mourir), et `kill` renvoie EPERM quand ce script tourne dans un bac
# à sable (agent, CI). Dans les deux cas `open` empile une 2e instance sur le même store
# SwiftData → fenêtre figée. On refuse de lancer plutôt que d'empiler.
pkill -9 -x Today 2>/dev/null || true
for _ in $(seq 20); do pgrep -x Today >/dev/null || break; sleep 0.1; done
if pgrep -x Today >/dev/null; then
    echo "✗ ThingsClone (PID $(pgrep -x Today | tr '\n' ' ')) survit au SIGKILL — rien n'a été lancé." >&2
    echo "  Stoppe-le depuis Xcode (⌘.), ou relance ce script hors bac à sable." >&2
    exit 1
fi

# RELEASE par défaut, et pas debug. Ce script est le seul moyen de voir l'app pour de vrai : juger
# sa fluidité sur un binaire non optimisé, alors que ce qu'on livre est optimisé, c'est juger autre
# chose. Tout ce que ce projet écrit lui-même — tris, `Reorder`, `TaskPageBlock`, construction des
# pages — tourne à chaque image d'un glissement et n'est pas optimisé en debug. `./run.sh debug`
# reste là pour le pas-à-pas.
./Scripts/make-app.sh "${1:-release}" Today
open Today.app
