#!/bin/bash
# Builds build/ClipCopy.app for Apple Silicon. Pass --install to replace /Applications/ClipCopy.app.
#
# Code signing: macOS keys the login item to the app's signature, and ad hoc builds get a new one
# every time. To keep one identity across rebuilds, run scripts/make-signing-identity.sh once; the
# build then signs with "ClipCopy Local Signing". To use a different identity, set
# CLIPCOPY_SIGN_IDENTITY, either in the environment or in scripts/local.env (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f scripts/local.env ]]; then
  # shellcheck disable=SC1091
  source scripts/local.env
fi

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="build/ClipCopy.app"

if [[ ! -f Resources/AppIcon.icns ]]; then
  scripts/make-icon.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClipCopy" "$APP/Contents/MacOS/ClipCopy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${CLIPCOPY_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-certificate -c "ClipCopy Local Signing" >/dev/null 2>&1; then
  IDENTITY="ClipCopy Local Signing"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ClipCopy || true
  rm -rf /Applications/ClipCopy.app
  cp -R "$APP" /Applications/ClipCopy.app
  open /Applications/ClipCopy.app
  echo "Installed and started /Applications/ClipCopy.app"
fi
