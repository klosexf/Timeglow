#!/bin/bash
set -euo pipefail

TIMEGLOW_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMEGLOW_ICON_SOURCE="$TIMEGLOW_PROJECT_DIR/Branding/Timeglow-Icon-Source.png"
TIMEGLOW_ICON_SET="$TIMEGLOW_PROJECT_DIR/Timeglow/Assets.xcassets/AppIcon.appiconset"

mkdir -p "$TIMEGLOW_ICON_SET"
for TIMEGLOW_ICON_SIZE in 16 32 128 256 512; do
    for TIMEGLOW_ICON_SCALE in 1 2; do
        TIMEGLOW_ICON_PIXELS=$((TIMEGLOW_ICON_SIZE * TIMEGLOW_ICON_SCALE))
        TIMEGLOW_ICON_NAME="icon_${TIMEGLOW_ICON_SIZE}x${TIMEGLOW_ICON_SIZE}"
        if [ "$TIMEGLOW_ICON_SCALE" -eq 2 ]; then
            TIMEGLOW_ICON_NAME="${TIMEGLOW_ICON_NAME}@2x"
        fi
        /usr/bin/sips -s format png -z "$TIMEGLOW_ICON_PIXELS" "$TIMEGLOW_ICON_PIXELS" \
            "$TIMEGLOW_ICON_SOURCE" --out "$TIMEGLOW_ICON_SET/$TIMEGLOW_ICON_NAME.png" >/dev/null
    done
done

printf 'Generated macOS AppIcon assets from %s\n' "$TIMEGLOW_ICON_SOURCE"
