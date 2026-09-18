#!/bin/bash
#
# Builds SidecarReconnect.app and the sidecarctl CLI, then installs both.
# Re-running is safe: it rebuilds and replaces in place.

set -euo pipefail

APP_NAME="SidecarReconnect"
BUNDLE_ID="io.github.sidecarreconnect"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$HERE/build"
APP="$BUILD_DIR/$APP_NAME.app"
APP_DEST="${APP_DEST:-$HOME/Applications}"
CLI_DEST="${CLI_DEST:-$HOME/.local/bin}"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31m==>\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this only makes sense on macOS"
command -v swiftc >/dev/null 2>&1 || die "swiftc not found — run: xcode-select --install"

SHARED=("$HERE"/Sources/Shared/*.swift)

say "Building $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -framework AppKit \
    "${SHARED[@]}" "$HERE/Sources/App/main.swift" \
    -o "$APP/Contents/MacOS/$APP_NAME"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/scripts/sidecar-connect-ui.applescript" "$APP/Contents/Resources/"
# Regenerate the icon if it's missing, so a fresh clone still gets one.
[[ -f "$HERE/Resources/AppIcon.icns" ]] \
    || swift "$HERE/scripts/make-icon.swift" >/dev/null 2>&1 \
    || warn "could not generate the app icon — the app runs without one"
[[ -f "$HERE/Resources/AppIcon.icns" ]] \
    && cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Ad-hoc signature. Not a real identity, but macOS is markedly happier about
# login items and permission grants for a signed bundle than an unsigned one.
say "Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null \
    || warn "codesign failed — the app still runs, but Open at Login may not stick"

say "Building sidecarctl"
mkdir -p "$BUILD_DIR"
swiftc -O "${SHARED[@]}" "$HERE/Sources/CLI/main.swift" -o "$BUILD_DIR/sidecarctl"

say "Installing"
mkdir -p "$APP_DEST" "$CLI_DEST"
# Quit a running copy first, or we'd be writing over a live binary.
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1
rm -rf "${APP_DEST:?}/$APP_NAME.app"
cp -R "$APP" "$APP_DEST/"
install -m 0755 "$BUILD_DIR/sidecarctl" "$CLI_DEST/sidecarctl"

say "Launching"
open "$APP_DEST/$APP_NAME.app"

echo
say "Done — look for the mirroring icon in your menu bar."
echo
"$CLI_DEST/sidecarctl" list 2>&1 | sed 's/^/    /' || true
echo
case ":$PATH:" in
    *":$CLI_DEST:"*) ;;
    *) warn "$CLI_DEST is not on your PATH — add this to ~/.zshrc if you want the CLI:"
       echo "       export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
cat <<NEXT

From the menu bar icon you can:
  • Reconnect Now          — run the recovery ladder by hand
  • Reconnect Automatically After Wake — on by default
  • Open at Login          — turn this on so it's always there
  • Copy Diagnostics       — paste this into a bug report

The CLI does the same thing for hotkeys and scripts:
  sidecarctl fix
NEXT
