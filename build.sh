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

# --build-only compiles and signs without installing or launching, which is what
# a build machine wants and what you want when you don't intend to replace the
# copy you're currently running.
BUILD_ONLY=0
[[ "${1:-}" == "--build-only" || -n "${CI:-}" ]] && BUILD_ONLY=1

[[ "$(uname -s)" == "Darwin" ]] || die "this only makes sense on macOS"
command -v swiftc >/dev/null 2>&1 || die "swiftc not found — run: xcode-select --install"

SHARED=("$HERE"/Sources/Shared/*.swift)
# The Android second-display engine, vendored from Side Screen. App only — the
# CLI has no use for a video pipeline and shouldn't carry one.
VENDOR=("$HERE"/Sources/Vendor/*.swift "$HERE"/Sources/Vendor/SideScreen/*.swift)
VENDOR_INC="$HERE/Sources/Vendor/SideScreen"
# Our own code that drives the vendored engine. Also app-only.
DISPLAY_SRC=("$HERE"/Sources/Display/*.swift)
# The whole App directory, not just main.swift — adding a file beside it should
# be picked up the way Sources/Shared already is.
APP_SRC=("$HERE"/Sources/App/*.swift)

# Deployment target, not the host's version. Two reasons: the app claims macOS 13
# in Info.plist and a binary built without this demands whatever the build
# machine runs; and the vendored ScreenCapture.swift falls back to CGDisplayStream,
# which the macOS 26 SDK marks unavailable above 13.
TARGET="$(uname -m)-apple-macosx13.0"

say "Building $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -framework AppKit -target "$TARGET" \
    -I "$VENDOR_INC" -Xcc -fmodule-map-file="$VENDOR_INC/module.modulemap" \
    "${SHARED[@]}" "${VENDOR[@]}" "${DISPLAY_SRC[@]}" "${APP_SRC[@]}" \
    -o "$APP/Contents/MacOS/$APP_NAME"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/scripts/sidecar-connect-ui.applescript" "$APP/Contents/Resources/"
# Regenerate the icon if it's missing, so a fresh clone still gets one.
[[ -f "$HERE/Resources/AppIcon.icns" ]] \
    || swift "$HERE/scripts/make-icon.swift" >/dev/null 2>&1 \
    || warn "could not generate the app icon — the app runs without one"
[[ -f "$HERE/Resources/AppIcon.icns" ]] \
    && cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Sign with a real identity when the machine has one. This matters more than it
# looks: TCC keys Screen Recording and Accessibility grants to the signature, and
# an ad-hoc signature changes on every build — so each rebuild would appear to
# macOS as a different app and silently lose both permissions. A stable identity
# means granting once. Override with SIGN_ID=... if you want a specific one.
if [[ -z "${SIGN_ID:-}" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Developer ID Application|Apple Development/ { print $2; exit }')"
fi
if [[ -n "${SIGN_ID:-}" ]]; then
    say "Signing ($(security find-identity -v -p codesigning | grep "$SIGN_ID" | sed 's/.*"\(.*\)"/\1/'))"
else
    say "Signing (ad-hoc — permissions will need re-granting after each build)"
    SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" 2>/dev/null \
    || warn "codesign failed — the app still runs, but Open at Login may not stick"

say "Building sidecarctl"
mkdir -p "$BUILD_DIR"
swiftc -O -target "$TARGET" "${SHARED[@]}" "$HERE/Sources/CLI/main.swift" \
    -o "$BUILD_DIR/sidecarctl"

if [[ "$BUILD_ONLY" == "1" ]]; then
    say "Built (not installed)"
    echo "    $APP"
    echo "    $BUILD_DIR/sidecarctl"
    exit 0
fi

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
