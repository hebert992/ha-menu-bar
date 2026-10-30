#!/usr/bin/env bash
# Builds HAMenuBar in release mode and assembles build/HAMenuBar.app.
# Usage: scripts/bundle.sh [--install]   (--install copies the app to ~/Applications)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="HAMenuBar"
APP_DIR="$ROOT/build/$APP_NAME.app"
INSTALL=false

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    -h|--help) echo "Usage: $0 [--install]"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

cd "$ROOT"

echo "==> Building release binary"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

echo "==> Ad-hoc code signing"
codesign --force --deep -s - "$APP_DIR"
codesign --verify --verbose=1 "$APP_DIR"

if $INSTALL; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  # Quit a running copy so the binary can be replaced.
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP_DIR" "$DEST/"
  echo "==> Installed to $DEST/$APP_NAME.app"
fi

echo "==> Done: $APP_DIR"
