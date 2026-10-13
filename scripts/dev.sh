#!/usr/bin/env bash
# Builds "Ur Dev" from the working copy, installs it in ~/Applications and opens it.
# It runs next to the installed Ur with its own data, in ~/Library/Application Support/Ur Dev.
#   --copy-data   start from a copy of the installed Ur's data (replaces Ur Dev's data)
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=1 VERSION="${VERSION:-dev}" ./scripts/build-app.sh

# Quit a running copy first, so it can't save over copied data on its way out.
osascript -e 'tell application id "no.nygard.ur.dev" to quit' >/dev/null 2>&1 || true
sleep 1

SUPPORT="$HOME/Library/Application Support"
if [ "${1:-}" = "--copy-data" ]; then
    mkdir -p "$SUPPORT/Ur Dev"
    cp "$SUPPORT/Ur/ur.json" "$SUPPORT/Ur Dev/ur.json"
    echo "✓ Copied Ur's data to Ur Dev"
fi


DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/Ur Dev.app"
cp -R "build/Ur Dev.app" "$DEST/Ur Dev.app"
echo "✓ Installed $DEST/Ur Dev.app"
open "$DEST/Ur Dev.app"
