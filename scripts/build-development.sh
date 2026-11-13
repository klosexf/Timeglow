#!/bin/bash
set -euo pipefail
TIMEGLOW_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMEGLOW_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TIMEGLOW_DERIVED_DIR="${TMPDIR:-/tmp}/timeglow-build"
TIMEGLOW_OUTPUT_DIR="$TIMEGLOW_PROJECT_DIR/../outputs/native"
"$TIMEGLOW_DEVELOPER_DIR/usr/bin/xcodebuild" -project "$TIMEGLOW_PROJECT_DIR/Timeglow.xcodeproj" -scheme Timeglow -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$TIMEGLOW_DERIVED_DIR" build
mkdir -p "$TIMEGLOW_OUTPUT_DIR"
ditto "$TIMEGLOW_DERIVED_DIR/Build/Products/Debug/Timeglow.app" "$TIMEGLOW_OUTPUT_DIR/Timeglow.app"
codesign --verify --deep --strict "$TIMEGLOW_OUTPUT_DIR/Timeglow.app"
printf 'Built: %s\n' "$TIMEGLOW_OUTPUT_DIR/Timeglow.app"
