#!/bin/bash
# Removes the app and the CLI. Keeps your settings and log unless --purge.
set -euo pipefail

APP_NAME="SidecarReconnect"
BUNDLE_ID="io.github.sidecarreconnect"
APP_DEST="${APP_DEST:-$HOME/Applications}"
CLI_DEST="${CLI_DEST:-$HOME/.local/bin}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

say "Quitting $APP_NAME"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

say "Removing the app and CLI"
rm -rf "${APP_DEST:?}/$APP_NAME.app" "/Applications/$APP_NAME.app"
rm -f "$CLI_DEST/sidecarctl"

if [[ "${1:-}" == "--purge" ]]; then
    say "Removing settings and log"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Logs/SidecarReconnect.log"
else
    say "Kept your settings and $HOME/Library/Logs/SidecarReconnect.log (pass --purge to remove)"
fi

say "If you turned on Open at Login, check System Settings › General › Login Items."
say "Done."
