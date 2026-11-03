#!/usr/bin/env bash
# Убирает приложение и автозапуск. --purge удаляет ещё и историю с настройками.
set -euo pipefail

APP="$HOME/Applications/DeepSeek Balance.app"
LABEL="io.github.mikage777.deepseekbalance"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$HOME/Library/Application Support/DeepSeekBalance"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
pkill -f "DeepSeek Balance.app/Contents/MacOS/DeepSeekBalance" 2>/dev/null || true
rm -rf "$APP"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$DATA"
  echo "removed app, login item and data ($DATA)"
  echo "the API key stays in your Keychain: security delete-generic-password -s deepseek-balance-widget"
else
  echo "removed app and login item; data kept in $DATA (use --purge to delete)"
fi
