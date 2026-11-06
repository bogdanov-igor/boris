#!/bin/bash
# Builds and signs build/Boris.app. The first argument is the configuration, release by default.
# BORIS_SIGN_IDENTITY overrides the signing identity.
#
# scripts/release.sh sets the rest, and an ordinary build needs none of it:
#   BORIS_VERSION, BORIS_BUILD            the version written into the app
#   BORIS_APPCAST_URL, BORIS_SPARKLE_PUBLIC_KEY   what makes a release build check for updates. A copy without them never does.
#   BORIS_HARDENED=1                      sign for notarization: hardened runtime and a secure timestamp from Apple
#   BORIS_NO_TIMESTAMP=1                  the same without asking Apple, for a dry run
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/Boris" "$BIN/boris-hook" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/app.boris.Boris.agent.plist "$APP/Contents/Library/LaunchAgents/"

# Debug links it too, because a package cannot leave a library out by configuration, so every build carries it. Only a released one uses it.
# ditto keeps the framework's symlinks, which its signature covers.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Boris"

if [ -n "${BORIS_VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$BORIS_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BORIS_BUILD:-}" ]; then
    plutil -replace CFBundleVersion -string "$BORIS_BUILD" "$APP/Contents/Info.plist"
fi
if [ -n "${BORIS_APPCAST_URL:-}" ] || [ -n "${BORIS_SPARKLE_PUBLIC_KEY:-}" ]; then
    if [ "$CONFIG" != "release" ] || [ -z "${BORIS_APPCAST_URL:-}" ] || [ -z "${BORIS_SPARKLE_PUBLIC_KEY:-}" ]; then
        echo "error: the appcast and the public key go together, and only into a release build" >&2
        exit 1
    fi
    plutil -replace SUFeedURL -string "$BORIS_APPCAST_URL" "$APP/Contents/Info.plist"
    plutil -replace SUPublicEDKey -string "$BORIS_SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi

mkdir -p build
python3 scripts/build-strings.py build/Localizable.xcstrings
xcrun xcstringstool compile build/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp docs/remote-ssh.md "$APP/Contents/Resources/"
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

# From the inside out, as Sparkle's documentation lays it down, which also says Downloader.xpc keeps the entitlements it came with.
if [ "${BORIS_HARDENED:-}" = "1" ] && [ "${BORIS_NO_TIMESTAMP:-}" = "1" ]; then
    SIGN=(codesign --force --options runtime --timestamp=none --sign "$IDENTITY")
elif [ "${BORIS_HARDENED:-}" = "1" ]; then
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
else
    SIGN=(codesign --force --timestamp=none --sign "$IDENTITY")
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

echo "==> Signing"
"${SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" "$APP/Contents/MacOS/boris-hook"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Done: $APP"
