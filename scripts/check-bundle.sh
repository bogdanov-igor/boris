#!/bin/bash
# Looks inside build/Boris.app without starting it: the licenses, Sparkle, the signature, and that no debug hook got in.
# With --release also what only a real release has: the appcast, the key, hardened runtime and a Developer ID.
# With --hardened the hardened runtime and the appcast, for a dry run on a Mac with no Developer ID.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
APP="build/Boris.app"
MODE="${1:-}"
PLIST="$APP/Contents/Info.plist"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
PROBLEMS=0

check() {
    local what="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok   $what"
    else
        echo "FAIL $what"
        PROBLEMS=$((PROBLEMS + 1))
    fi
}

plist_value() {
    plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null
}

no_plist_key() {
    ! plutil -extract "$1" raw -o - "$PLIST" >/dev/null 2>&1
}

is_https() {
    [[ "$(plist_value SUFeedURL)" == https://* ]]
}

key_is_32_bytes() {
    [ "$(plist_value SUPublicEDKey | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = "32" ]
}

# Not grep -q anywhere here: it stops at the first match, the program before it dies on the closed pipe,
# and with pipefail that reads as "not found". A check for what must be absent would then always pass.
has_rpath() {
    otool -l "$APP/Contents/MacOS/Boris" | grep "@executable_path/../Frameworks" >/dev/null
}

# A Mac without Xcode has only the system's libraries and what the app carries.
needs_only_itself() {
    ! otool -L "$APP/Contents/MacOS/Boris" "$APP/Contents/MacOS/boris-hook" | awk 'NR > 1 && !/:$/ {print $1}' | grep -vE "^(/System/Library/|/usr/lib/|@rpath/Sparkle\.framework/)" >/dev/null
}

hardened() {
    codesign -dv "$1" 2>&1 | grep "flags=.*runtime" >/dev/null
}

all_hardened() {
    local code
    for code in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app" "$SPARKLE" "$APP/Contents/MacOS/boris-hook" "$APP"; do
        hardened "$code" || return 1
    done
}

developer_id() {
    codesign -dvv "$APP" 2>&1 | grep "^Authority=Developer ID Application:" >/dev/null
}

has_timestamp() {
    codesign -dvv "$APP" 2>&1 | grep "^Timestamp=" >/dev/null
}

no_debug_hooks() {
    ! strings "$APP/Contents/MacOS/Boris" | grep -E "BORIS_(SNAPSHOT|ALLOW_UI|APP_MEASURE|UPDATE_CHECK)" >/dev/null
}

no_home_folder() {
    ! strings "$APP/Contents/MacOS/Boris" "$APP/Contents/MacOS/boris-hook" | grep "/Users/" >/dev/null
}

check "LICENSE is inside and the same as in the repository" cmp LICENSE "$APP/Contents/Resources/LICENSE.txt"
check "THIRD_PARTY_LICENSES is inside and the same as in the repository" cmp THIRD_PARTY_LICENSES.txt "$APP/Contents/Resources/THIRD_PARTY_LICENSES.txt"
check "Sparkle is inside" test -x "$SPARKLE/Versions/B/Sparkle"
check "its symlinks survived the copy" test -L "$SPARKLE/Versions/Current"
check "the app can find it" has_rpath
check "it needs nothing outside itself and the system" needs_only_itself
check "the signature holds, inside and out" codesign --verify --deep --strict "$APP"
check "the system profile is not sent" no_plist_key SUEnableSystemProfiling
check "nothing installs without asking" test "$(plist_value SUAllowsAutomaticUpdates)" = "false"

if [ "$MODE" = "--release" ] || [ "$MODE" = "--hardened" ]; then
    check "the appcast is on https" is_https
    check "the public key is 32 bytes" key_is_32_bytes
    check "everything has hardened runtime" all_hardened
    check "no debug hook in the app" no_debug_hooks
    check "no path of this Mac in the programs" no_home_folder
fi
if [ "$MODE" = "--release" ]; then
    check "signed with a Developer ID" developer_id
    check "with a secure timestamp" has_timestamp
fi

if [ "$PROBLEMS" -gt 0 ]; then
    echo "$PROBLEMS problem(s)"
    exit 1
fi
