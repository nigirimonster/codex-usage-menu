#!/usr/bin/env bash
set -euo pipefail

LABELS=(
  "io.github.codexusagemenu.app"
  "local.codex.usage-menu"
)

for label in "${LABELS[@]}"; do
  PLIST="$HOME/Library/LaunchAgents/$label.plist"
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  echo "Removed login item: $PLIST"
done
