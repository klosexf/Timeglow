#!/bin/bash
set -euo pipefail
TIMEGLOW_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/timeglow-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/timeglow-module-cache"
xcrun swift test --disable-sandbox --package-path "$TIMEGLOW_PROJECT_DIR" --scratch-path "${TMPDIR:-/tmp}/timeglow-tests" "$@"
