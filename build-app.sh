#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/MapLeads.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MapLeads" "$APP/Contents/MacOS/MapLeads"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '\nBuilt %s\nOpen with: open "%s"\n' "$APP" "$APP"
