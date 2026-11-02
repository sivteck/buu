#!/usr/bin/env bash
#
# Builds BUU.app (a self contained macOS application bundle) from the SwiftPM
# executable target. Run it on macOS with Xcode's command line tools installed.
#
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/build/BUU.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/BUU" "$APP/Contents/MacOS/BUU"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    echo "==> Signing (ad-hoc)"
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
        echo "    (ad-hoc signing failed – the app still runs locally)"
fi

echo "==> Done: $APP"
echo "    open '$APP'"
