#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in -selftest|-qa|-intro-preview|-perf) ;; *) echo 'Expected a headless mode' >&2; exit 2;; esac
mkdir -p build/{tmp,cache,home}
export TMPDIR="$PWD/build/tmp/" CFFIXED_USER_HOME="$PWD/build/home" CLANG_MODULE_CACHE_PATH="$PWD/build/cache"
flags=()
if [[ ${CODEX_SANDBOX:-} == seatbelt ]]; then flags+=( 'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox' ); fi
xcodebuild -project Ledge/Ledge.xcodeproj -scheme Ledge -configuration Debug -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath ./build -disableAutomaticPackageResolution COMPILER_INDEX_STORE_ENABLE=NO ${flags[@]+"${flags[@]}"} -quiet build
exec ./build/Build/Products/Debug/Ledge.app/Contents/MacOS/Ledge "$@"
