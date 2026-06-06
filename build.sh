#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Codex Usage.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
MODULE_CACHE="$ROOT/build/module-cache"

rm -rf "$APP"
mkdir -p "$MACOS" "$MODULE_CACHE"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
swiftc "$ROOT/CodexUsageMenu.swift" \
  -O \
  -target arm64-apple-macos13.0 \
  -module-cache-path "$MODULE_CACHE" \
  -framework Cocoa \
  -o "$MACOS/CodexUsageMenu"

echo "Built: $APP"
