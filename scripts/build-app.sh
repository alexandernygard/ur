#!/usr/bin/env bash
# Builds Ur.app into ./build using Swift Package Manager. Works with just the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 1.0)}"
VERSION="${VERSION#v}"
# DEV=1 builds "Ur Dev", which has its own bundle ID and data folder so it can run
# next to the installed Ur.
if [ "${DEV:-0}" = "1" ]; then
    NAME="Ur Dev"; BUNDLE_ID="no.nygard.ur.dev"
else
    NAME="Ur"; BUNDLE_ID="no.nygard.ur"
fi
APP="build/$NAME.app"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    # One binary for Apple Silicon and Intel. Built per architecture and merged,
    # since `--arch a --arch b` needs full Xcode.
    echo "→ Compiling (release, universal)…"
    BINS=()
    for ARCH in arm64 x86_64; do
        swift build -c release --product Ur --triple "$ARCH-apple-macosx14.0"
        BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)/Ur")
    done
    BIN="build/Ur-universal"
    mkdir -p build
    lipo -create "${BINS[@]}" -output "$BIN"
else
    echo "→ Compiling (release)…"
    swift build -c release --product Ur
    BIN="$(swift build -c release --show-bin-path)/Ur"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ur"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Ur</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally.
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ Built $APP"
