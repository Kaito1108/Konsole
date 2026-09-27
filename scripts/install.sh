#!/bin/sh
# Builds Konsole in Release and installs it to /Applications, so it can be
# launched from Spotlight / Launchpad / login items without Xcode.
# Also run by the app's 「最新のソースで更新」 button.
set -eu

cd "$(dirname "$0")/.."
# Kept between runs so updates are incremental builds, not full rebuilds.
BUILD_DIR="${KONSOLE_BUILD_DIR:-$HOME/Library/Caches/Konsole/Build}"
mkdir -p "$BUILD_DIR"

echo "Building Konsole (Release)..."
xcodebuild -project Konsole.xcodeproj -scheme Konsole -configuration Release \
    -derivedDataPath "$BUILD_DIR" build -quiet

# Quit the running copy (Xcode build or a previous install) before replacing it.
osascript -e 'tell application id "kanna.Konsole" to quit' >/dev/null 2>&1 || true
pkill -x Konsole >/dev/null 2>&1 || true
sleep 1

rm -rf /Applications/Konsole.app
ditto "$BUILD_DIR/Build/Products/Release/Konsole.app" /Applications/Konsole.app
echo "Installed to /Applications/Konsole.app"

open /Applications/Konsole.app
