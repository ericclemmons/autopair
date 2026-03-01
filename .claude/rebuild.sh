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
if make run 2>&1; then
  echo "✓ AutoPair relaunched"
else
  echo "✗ Build failed"
  exit 1
fi
