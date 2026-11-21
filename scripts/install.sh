#!/usr/bin/env bash
# Builds Ledge (Release, signed with a local certificate) and
# makes it the only Ledge: installed in /Applications and started.
#
#   ./scripts/install.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData/LedgeRel"
BUILT="${DERIVED}/Build/Products/Release/Ledge.app"
TARGET="/Applications/Ledge.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

# Erik's local identity when present; ad-hoc signing for everyone else.
IDENTITY="Erik Local Signing"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || IDENTITY="-"

echo "Building (Release)..."
cd "${REPO_ROOT}/Ledge"
xcodegen >/dev/null
xcodebuild -scheme Ledge -configuration Release -derivedDataPath "${DERIVED}" CODE_SIGN_IDENTITY="${IDENTITY}" -quiet build

echo "Quitting Ledge..."
osascript -e 'tell application id "com.erikkirillov.Ledge" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x Ledge >/dev/null || break; sleep 1; done
pkill -x Ledge 2>/dev/null || true

echo "Installing in ${TARGET}..."
rm -rf "${TARGET}"
ditto "${BUILT}" "${TARGET}"
"${LSREGISTER}" -u "${BUILT}" >/dev/null 2>&1 || true
"${LSREGISTER}" -f "${TARGET}" >/dev/null 2>&1 || true

if [ -n "${NO_OPEN:-}" ]; then echo "Installed ${TARGET} (NO_OPEN set: not started)."; exit 0; fi
open "${TARGET}"
echo "Ledge is running from ${TARGET}. Press ⌃⌥L, or shake a file while dragging."
