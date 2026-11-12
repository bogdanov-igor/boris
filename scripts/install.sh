#!/bin/bash
# Builds Boris, replaces ~/Applications/Boris.app and starts it.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh

DEST="$HOME/Applications/Boris.app"

# A normal quit exits with code 0, so launchd does not restart the old copy.
osascript -e 'tell application id "app.boris.Boris" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Boris >/dev/null || break
    sleep 0.3
done

mkdir -p "$HOME/Applications"
# A copy that Apple notarized is protected: macOS lets nothing delete files inside it, so a half-replaced app would be left.
# The whole folder can still be moved, so the old copy goes to the Trash in one piece.
if [ -e "$DEST" ]; then
    mv "$DEST" "$HOME/.Trash/Boris-replaced-$(date +%Y%m%d-%H%M%S).app"
fi
ditto build/Boris.app "$DEST"

open "$DEST"

echo "==> Installed: $DEST"
