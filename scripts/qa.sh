#!/usr/bin/env bash
# Builds Debug and renders every screen to qa/*.png with fake data.
set -euo pipefail
cd "$(dirname "$0")/.."
exec bash scripts/debug-build.sh -selftest -render-proofs "$PWD/qa" -perf
