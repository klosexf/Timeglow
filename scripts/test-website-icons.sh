#!/bin/bash
set -euo pipefail
TIMEGLOW_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TIMEGLOW_ICON_CHECKS_DIR="${TMPDIR:-/tmp}/timeglow-icon-checks"
mkdir -p "$TIMEGLOW_ICON_CHECKS_DIR"
cd "$TIMEGLOW_PROJECT_DIR"
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$TIMEGLOW_ICON_CHECKS_DIR/modules" \
    Timeglow/MonitoringCore/*.swift Timeglow/GraphiteStyle.swift Timeglow/WebsiteIcon.swift \
    Tests/WebsiteIconChecks.swift -lsqlite3 -o "$TIMEGLOW_ICON_CHECKS_DIR/checks"
"$TIMEGLOW_ICON_CHECKS_DIR/checks" "$@"
