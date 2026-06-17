#!/usr/bin/env bash
# Build Nextpad.app with swiftc (no Xcode needed). Usage: ./build.sh [run|snapshot]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Nextpad.app"
BIN="$APP/Contents/MacOS/Nextpad"

# --- toolchain checks ---
if ! command -v swiftc >/dev/null 2>&1; then
  echo "✗ swiftc not found — install Apple Command Line Tools first:"
  echo "    xcode-select --install"
  exit 1
fi
# (the known CLT modulemap bug breaks all AppKit compiles)
if ! printf 'import AppKit\n' | swiftc -typecheck - >/dev/null 2>&1; then
  echo "✗ Swift can't import AppKit on this toolchain (CLT duplicate-modulemap bug)."
  echo "  Fix once, then re-run ./build.sh — pick ONE:"
  echo "    A) sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap{,.disabled}"
  echo "    B) install full Xcode from the App Store"
  exit 1
fi

echo "→ compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# shellcheck disable=SC2046
swiftc -o "$BIN" $(find "$ROOT/Sources/Nextpad" -name '*.swift')
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/Nextpad.icns" ] && cp "$ROOT/Resources/Nextpad.icns" "$APP/Contents/Resources/Nextpad.icns"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true  # ad-hoc, local dev only
echo "✓ built $APP"

case "${1:-}" in
  run)      open "$APP" ;;
  snapshot) NEXTPAD_SNAPSHOT=1 "$BIN"; echo "  snapshot → /tmp/nextpad-shot.png" ;;
esac
