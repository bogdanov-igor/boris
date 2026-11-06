#!/bin/bash
# Makes a release of Boris: signed with a Developer ID, notarized, stapled, with an appcast Sparkle can read.
#
#   scripts/release.sh 0.2.0              everything but the publishing, and prints the command that publishes
#   scripts/release.sh 0.2.0 --publish    and publishes it as a GitHub release
#   scripts/release.sh 0.2.0 --dry-run    what can run on a Mac with no certificate and no key: the build, its hardened signature, the look inside
#
# docs/release.md says what it needs and how to get it. It generates no key and writes nothing to the Keychain.
set -euo pipefail

cd "$(dirname "$0")/.."

REPOSITORY="bogdanov-igor/boris"
APPCAST_URL="https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"
NOTARY_PROFILE="${BORIS_NOTARY_PROFILE:-boris-notary}"
OUT="build/release"
SPARKLE_TOOLS=".build/artifacts/sparkle/Sparkle/bin"

VERSION="${1:-}"
OPTION="${2:-}"
case "$OPTION" in
    "" | --publish | --dry-run) OPTION_IS_KNOWN=1 ;;
    *) OPTION_IS_KNOWN=0 ;;
esac
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "$OPTION_IS_KNOWN" = "0" ]; then
    sed -n '2,8p' "$0"
    exit 2
fi

stop() {
    echo "error: $1" >&2
    echo "docs/release.md has the steps." >&2
    exit 1
}

# Sparkle compares this number, not the version. Commits only ever add up, so a later release always has a larger one.
BUILD="$(git rev-list --count HEAD)"

if [ "$OPTION" = "--dry-run" ]; then
    IDENTITY="${BORIS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}"
    [ -n "$IDENTITY" ] || IDENTITY="-"
    # Thirty-two zero bytes, which no real key is. The app built here is looked at and never started.
    PUBLIC_KEY="$(head -c 32 /dev/zero | base64)"
else
    echo "==> Is everything in place?"
    [ -z "$(git status --porcelain)" ] || stop "the working tree has changes, and a release must be something that can be found again"
    if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
        stop "the tag v$VERSION already exists"
    fi
    IDENTITY="${BORIS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
    [ -n "$IDENTITY" ] || stop "no Developer ID Application certificate in the Keychain"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || stop "no notary profile named $NOTARY_PROFILE, or Apple does not accept it"
    swift package resolve
    # Only reads: -p prints the public key of the key already in the Keychain, and never makes one.
    PUBLIC_KEY="$("$SPARKLE_TOOLS/generate_keys" -p 2>/dev/null)" || stop "no Sparkle signing key in the Keychain"
    [ -n "$PUBLIC_KEY" ] || stop "no Sparkle signing key in the Keychain"
    if [ "$OPTION" = "--publish" ]; then
        gh auth status >/dev/null 2>&1 || stop "gh is not signed in, so there is nowhere to publish"
    fi

    echo "==> Checks"
    python3 scripts/check-strings.py
    swift test
    python3 scripts/measure.py app
    python3 scripts/check-network.py
fi

echo "==> Building $VERSION ($BUILD)"
export BORIS_SIGN_IDENTITY="$IDENTITY" BORIS_HARDENED=1 BORIS_VERSION="$VERSION" BORIS_BUILD="$BUILD"
export BORIS_APPCAST_URL="$APPCAST_URL" BORIS_SPARKLE_PUBLIC_KEY="$PUBLIC_KEY"
if [ "$OPTION" = "--dry-run" ]; then
    export BORIS_NO_TIMESTAMP=1
fi
scripts/build-app.sh release

rm -rf "$OUT"
mkdir -p "$OUT/archives"
ARCHIVE="$OUT/archives/Boris-$VERSION.zip"

if [ "$OPTION" = "--dry-run" ]; then
    scripts/check-bundle.sh --hardened
    ditto -c -k --sequesterRsrc --keepParent build/Boris.app "$ARCHIVE"
    echo "==> Dry run done: $ARCHIVE. Skipped: the checks, Developer ID, notarization, stapling, the appcast, publishing."
    exit 0
fi

scripts/check-bundle.sh --release

echo "==> Notarizing, which takes a few minutes"
ditto -c -k --keepParent build/Boris.app "$OUT/notarize.zip"
SUBMISSION="$OUT/notary.json"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$SUBMISSION"
STATUS="$(plutil -extract status raw -o - "$SUBMISSION")"
if [ "$STATUS" != "Accepted" ]; then
    xcrun notarytool log "$(plutil -extract id raw -o - "$SUBMISSION")" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    stop "Apple answered: $STATUS"
fi
xcrun stapler staple build/Boris.app
xcrun stapler validate build/Boris.app
spctl --assess --type execute --verbose=2 build/Boris.app
rm -f "$OUT/notarize.zip"

echo "==> The update archive and the appcast"
ditto -c -k --sequesterRsrc --keepParent build/Boris.app "$ARCHIVE"
# What is already out stays on offer to those who skipped it. On the very first release there is nothing to fetch.
curl -fsSL "$APPCAST_URL" -o "$OUT/archives/appcast.xml" || rm -f "$OUT/archives/appcast.xml"
NOTES="docs/release-notes/$VERSION.md"
if [ -f "$NOTES" ]; then
    cp "$NOTES" "$OUT/archives/Boris-$VERSION.md"
fi
"$SPARKLE_TOOLS/generate_appcast" \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
    --full-release-notes-url "https://github.com/$REPOSITORY/releases" \
    --link "https://github.com/$REPOSITORY" \
    --embed-release-notes \
    --maximum-deltas 0 \
    "$OUT/archives"
grep -q "sparkle:edSignature" "$OUT/archives/appcast.xml" || stop "the appcast has no signature for the update"

if [ -f "$NOTES" ]; then
    NOTES_OPTION=(--notes-file "$NOTES")
else
    NOTES_OPTION=(--generate-notes)
fi
PUBLISH=(gh release create "v$VERSION" "$ARCHIVE" "$OUT/archives/appcast.xml" --repo "$REPOSITORY" --title "Boris $VERSION" "${NOTES_OPTION[@]}")
if [ "$OPTION" = "--publish" ]; then
    echo "==> Publishing"
    "${PUBLISH[@]}"
    echo "==> Done: https://github.com/$REPOSITORY/releases/tag/v$VERSION"
else
    echo "==> Ready in $OUT/archives. To publish:"
    printf '%q ' "${PUBLISH[@]}"
    echo
fi
