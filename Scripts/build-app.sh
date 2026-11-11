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
swift build -c "$CONFIGURATION" --product BUU
swift build -c "$CONFIGURATION" --product VirtualMacGuest

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/build/BUU.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/BUU" "$APP/Contents/MacOS/BUU"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# The guest helper is the same package, built as a separate executable and
# wrapped in its own .app. It is mounted read-only into the guest as
# /Volumes/My Shared Files/tools.
GUEST="$APP/Contents/Resources/guest-tools/BUUVirtualMacGuest.app"
mkdir -p "$GUEST/Contents/MacOS"
cp "$BIN_PATH/VirtualMacGuest" "$GUEST/Contents/MacOS/VirtualMacGuest"
cp "$ROOT/Resources/VirtualMacGuest-Info.plist" "$GUEST/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    if [[ -z "${SIGN_IDENTITY:-}" ]]; then
        if security find-identity -p codesigning 2>/dev/null | grep -qF '"BUU Code Signing"'; then
            SIGN_IDENTITY="BUU Code Signing"
        else
            SIGN_IDENTITY=-
            echo "    No \"BUU Code Signing\" identity; signing ad-hoc. Run Scripts/create-signing-identity.sh once to keep guest permissions across rebuilds." >&2
        fi
    fi
    IDENTITY="$SIGN_IDENTITY"
    echo "==> Signing ($IDENTITY)"
    codesign --force --sign "$IDENTITY" --timestamp=none "$GUEST" >/dev/null 2>&1 || \
        echo "    (guest helper signing failed)"
    codesign --force --sign "$IDENTITY" --timestamp=none \
        --entitlements "$ROOT/Resources/BUU.entitlements" "$APP" >/dev/null 2>&1 || \
        echo "    (host signing failed – Virtualization requires a signed build)"
fi

echo "==> Done: $APP"
echo "    open '$APP'"
