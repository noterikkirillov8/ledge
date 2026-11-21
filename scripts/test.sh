#!/usr/bin/env bash
# Builds Debug and runs the logic tests (`Ledge -selftest`).
set -euo pipefail
if [[ ${CODEX_SANDBOX:-} == seatbelt ]]; then
    exec bash "$(dirname "$0")/debug-build.sh" -selftest -isolated-trash
fi
exec bash "$(dirname "$0")/debug-build.sh" -selftest
