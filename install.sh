#!/usr/bin/env bash
# Builds Ur and installs it into /Applications (or ~/Applications if that isn't writable).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift is required. Install the Command Line Tools with: xcode-select --install"
    exit 1
fi

if command -v brew >/dev/null 2>&1 && brew list --cask ur >/dev/null 2>&1; then
    echo "Ur is installed with Homebrew. Update it with: brew upgrade --cask ur"
    echo "To run your local changes next to it, use: ./scripts/dev.sh"
    exit 1
fi

./scripts/build-app.sh

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

# Quit a running copy so it can be replaced.
osascript -e 'tell application id "no.nygard.ur" to quit' >/dev/null 2>&1 || true
sleep 1

rm -rf "$DEST/Ur.app"
cp -R build/Ur.app "$DEST/Ur.app"
xattr -dr com.apple.quarantine "$DEST/Ur.app" 2>/dev/null || true

echo "✓ Installed to $DEST/Ur.app"
open "$DEST/Ur.app"
