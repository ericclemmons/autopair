#!/bin/bash
# PostToolUse hook: rebuild & relaunch AutoPair when source files change.
# Receives tool input JSON on stdin.
INPUT=$(cat)
FILE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('file_path',''))" 2>/dev/null)

# Only rebuild for Swift and Info.plist changes
if [[ "$FILE" != *.swift && "$FILE" != *Info.plist ]]; then
  exit 0
fi

cd "$(dirname "$0")/.."

echo "→ Rebuilding AutoPair..."
pkill -x AutoPair 2>/dev/null || true

if bash build-app.sh debug 2>&1; then
  codesign --force --options runtime \
    --entitlements AutoPair.entitlements \
    --sign - AutoPair.app 2>/dev/null
  open AutoPair.app
  echo "✓ AutoPair relaunched"
else
  echo "✗ Build failed"
  exit 1
fi
