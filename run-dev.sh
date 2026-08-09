#!/bin/bash
# Lance une SECONDE instance de Today, dédiée au dev : bundle "TodayDev.app", process "TodayDev",
# base de données et sauvegardes séparées (TODAY_APP_SUPPORT_DIR → StoreLocation), Sparkle éteint.
# Ne touche jamais à l'instance "Today" du quotidien — c'est tout son intérêt. Usage : ./run-dev.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

TARGET="TodayDev"

# Même raison qu'un `run.sh` : ne pas empiler une 2e instance de TodayDev sur son propre store.
pkill -9 -x "${TARGET}" 2>/dev/null || true
for _ in $(seq 20); do pgrep -x "${TARGET}" >/dev/null || break; sleep 0.1; done
if pgrep -x "${TARGET}" >/dev/null; then
    echo "✗ ${TARGET} (PID $(pgrep -x "${TARGET}" | tr '\n' ' ')) survit au SIGKILL — rien n'a été lancé." >&2
    exit 1
fi

./Scripts/make-app.sh "${1:-release}" "${TARGET}"
open --env "TODAY_APP_SUPPORT_DIR=${TARGET}" "${TARGET}.app"
