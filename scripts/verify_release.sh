#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build
swift build -c release
scripts/build_app_bundle.sh >/dev/null

if lsof -nP -tiTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port 8765 is already in use" >&2
  lsof -nP -iTCP:8765 -sTCP:LISTEN >&2
  exit 1
fi

plutil -extract CFBundleExecutable raw dist/Peek.app/Contents/Info.plist | rg "^Peek$" >/dev/null
plutil -p dist/Peek.app/Contents/Info.plist >/dev/null
codesign -dv dist/Peek.app 2>/dev/null
codesign -d --entitlements :- dist/Peek.app 2>&1 | rg "com.apple.security.device.camera"
/usr/bin/open -n -W dist/Peek.app --args --help

".build/debug/Peek" --start-server &
PEEK_PID=$!
cleanup() {
  kill "$PEEK_PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1
LISTENER_PID="$(lsof -nP -tiTCP:8765 -sTCP:LISTEN)"
if [[ "$LISTENER_PID" != "$PEEK_PID" ]]; then
  echo "expected Peek PID $PEEK_PID to own port 8765, got $LISTENER_PID" >&2
  lsof -nP -iTCP:8765 -sTCP:LISTEN >&2
  exit 1
fi
lsof -nP -iTCP:8765 -sTCP:LISTEN
python3 test/test_mcp.py

echo "release verification passed"
