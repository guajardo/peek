#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/dist/Peek.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp ".build/release/Peek" "$MACOS/Peek"
cp "Resources/Info.plist" "$CONTENTS/Info.plist"
cp -R "Resources/Assets.xcassets" "$RESOURCES/Assets.xcassets"

chmod +x "$MACOS/Peek"
codesign --force --sign - --entitlements "Resources/Peek.entitlements" "$APP_DIR"

echo "$APP_DIR"
