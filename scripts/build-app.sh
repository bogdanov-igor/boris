#!/bin/bash
# Builds and signs build/Boris.app. The first argument is the configuration, release by default.
# BORIS_SIGN_IDENTITY overrides the signing identity.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Boris.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" --product Boris
swift build -c "$CONFIG" --product boris-hook
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/Boris" "$BIN/boris-hook" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/app.boris.Boris.agent.plist "$APP/Contents/Library/LaunchAgents/"

mkdir -p build
python3 scripts/build-strings.py build/Localizable.xcstrings
xcrun xcstringstool compile build/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_LICENSES.txt "$APP/Contents/Resources/"
if [ -d Resources/Sounds ]; then
    cp -R Resources/Sounds/. "$APP/Contents/Resources/"
fi
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

IDENTITY="${BORIS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
    # Ad-hoc signing still runs, but autostart and permissions may reset on every build.
    echo "warning: no Apple Development identity, signing ad-hoc" >&2
    IDENTITY="-"
fi

echo "==> Signing"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/boris-hook"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Done: $APP"
