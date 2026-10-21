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
# Overridable so CI can stamp a tag's version (e.g. v0.2.0 -> 0.2.0) into
# Info.plist; locally the hard default applies.
APP_VERSION="${APP_VERSION:-0.1.0}"
# UNIVERSAL=1 lipo-merges a native and a cross-compiled slice into a
# universal binary (CI wants this: macos-latest is arm64-only, and Intel
# Macs must still run the released app). Uses two plain SwiftPM builds +
# lipo — NOT `swift build --arch x --arch y`, which needs xcbuild (absent
# under Command Line Tools).
UNIVERSAL="${UNIVERSAL:-0}"
CONFIGURATION="release"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

BIN="$BIN_DIR/$APP_NAME"
if [[ "$UNIVERSAL" == "1" ]]; then
    HOST_ARCH="$(uname -m)"
    OTHER_ARCH="arm64"; [[ "$HOST_ARCH" == "arm64" ]] && OTHER_ARCH="x86_64"
    echo "==> swift build -c $CONFIGURATION --arch $OTHER_ARCH (cross slice)"
    swift build -c "$CONFIGURATION" --arch "$OTHER_ARCH"
    OTHER_BIN="$(swift build -c "$CONFIGURATION" --arch "$OTHER_ARCH" --show-bin-path)/$APP_NAME"
    UNIVERSAL_BIN="$BUILD_DIR/$APP_NAME-universal"
    lipo -create "$BIN" "$OTHER_BIN" -output "$UNIVERSAL_BIN"
    BIN="$UNIVERSAL_BIN"
    echo "==> universal binary: $(lipo -archs "$BIN")"
fi

if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"

# App icon (committed asset; an LSUIElement app, so it only shows in
# Finder/Get Info, but the bundle should still look proper there).
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# Localizations (en + zh-Hans). English is also an explicit lproj: its key ==
# value pins the fallback text outside a localized bundle.
for lproj in "$ROOT"/Resources/*.lproj; do
    cp -R "$lproj" "$CONTENTS/Resources/"
done

# Guard against drift: both .lproj files must carry the same key set.
if ! python3 "$ROOT/scripts/check-localization.py" "$ROOT/Resources"; then
    echo "error: localization key mismatch between en.lproj and zh-Hans.lproj" >&2
    exit 1
fi

# Info.plist is rendered with the version so it stays in one place.
sed "s/@VERSION@/$APP_VERSION/g" "$ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> built $APP"
echo "$APP"
