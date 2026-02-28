#!/bin/bash
set -e
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
  echo "Usage: $0 [debug|release]"
  exit 1
fi

swift build -c "$CONFIG"

APP="AutoPair.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/AutoPair" "$APP/Contents/MacOS/AutoPair"

if [[ "$CONFIG" == "release" ]]; then
  strip "$APP/Contents/MacOS/AutoPair"
fi

cp Info.plist "$APP/Contents/Info.plist"

mkdir -p "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Built $APP ($CONFIG)"
echo "Run with: open AutoPair.app"
