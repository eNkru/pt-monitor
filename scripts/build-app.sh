#!/usr/bin/env bash
#
# Assembles build/PTMonitor.app from the release build (design §8).
#
# Command Line Tools only: no xcodebuild, no .xcodeproj, no asset catalog, no
# automatic signing. The bundle is assembled by hand and ad-hoc signed.
#
# Idempotent: each run removes and recreates build/PTMonitor.app.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="PTMonitor"
APP_VERSION="0.1.0"
CONFIGURATION="release"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"

# Info.plist is rendered with the version so it stays in one place.
sed "s/@VERSION@/$APP_VERSION/g" "$ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> built $APP"
echo "$APP"
