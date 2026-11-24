#!/bin/bash
# Regenerates Resources/AppIcon.icns. The icon is drawn by the app itself (Sources/ClipCopy/Paperclip.swift),
# so the menu bar icon and the app icon always match.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN_DIR/ClipCopy" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
