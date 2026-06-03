#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build
swift build -c release
scripts/build_app_bundle.sh >/dev/null

".build/debug/Peek" --start-server &
PEEK_PID=$!
cleanup() {
  kill "$PEEK_PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1
lsof -nP -iTCP:8765 -sTCP:LISTEN
python3 test/test_mcp.py

plutil -p dist/Peek.app/Contents/Info.plist >/dev/null
codesign -dv dist/Peek.app 2>/dev/null
codesign -d --entitlements :- dist/Peek.app 2>&1 | rg "com.apple.security.device.camera"

echo "release verification passed"
