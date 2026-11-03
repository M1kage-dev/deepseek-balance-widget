#!/usr/bin/env bash
# Собирает и ставит виджет в ~/Applications, включает автозапуск при входе.
#   ./install.sh                  обычная установка
#   ./install.sh --no-login-item  без автозапуска
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DeepSeek Balance"
APP="$HOME/Applications/$APP_NAME.app"
LABEL="io.github.mikage777.deepseekbalance"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$HOME/Library/Application Support/DeepSeekBalance"
LOGIN_ITEM=1

for arg in "$@"; do
  case "$arg" in
    --no-login-item) LOGIN_ITEM=0 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf "%s\n" "$*"; }
die() { printf "error: %s\n" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only"
command -v swiftc >/dev/null 2>&1 || die "Swift compiler not found — run: xcode-select --install"
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$OS_MAJOR" -ge 13 ] || die "macOS 13 (Ventura) or newer required, found $(sw_vers -productVersion)"

say "→ building (needs Xcode Command Line Tools, no Xcode required)"
"$DIR/build.sh"

say "→ installing to $APP"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$DIR/dist/$APP_NAME.app" "$APP"

if [ "$LOGIN_ITEM" -eq 1 ]; then
  say "→ enabling launch at login"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/DeepSeekBalance</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$DATA/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    say "warning: could not load the login item; start the app manually once"
  fi
fi

open "$APP" 2>/dev/null || true

say ""
say "installed:  $APP"
say "config:     $DATA/config.json"
say "log:        $DATA/widget.log"
say ""
say "First run asks for your DeepSeek API key and keeps it in the macOS Keychain."
say "Uninstall:  ./uninstall.sh [--purge]"
