#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d ' \n\r' < "$ROOT/VERSION")"
DEV_FLAG=""
SWIFT_CONFIG="release"

# On CLT-only macOS 27 installations without Xcode, MacOSX27.2.sdk requires SwiftUIMacros
# which is not bundled in CLT; MacOSX26.5.sdk compiles SwiftUI cleanly.
if [[ -z "${SDKROOT:-}" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]] && \
   [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi

for arg in "$@"; do
  case "$arg" in
    --dev)
      DEV_FLAG="--dev"
      SWIFT_CONFIG="debug"
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

echo "==> [1/5] Building Rust backend verba-engine (release)..."
cargo build --release --manifest-path "$ROOT/Cargo.toml"
ENGINE_BIN="$ROOT/target/release/verba-engine"
if [[ ! -x "$ENGINE_BIN" ]]; then
  echo "error: missing $ENGINE_BIN" >&2
  exit 1
fi

echo "==> [2/5] Building macOS Swift targets ($SWIFT_CONFIG)..."
swift build -c "$SWIFT_CONFIG" --package-path "$ROOT/macos"
SWIFT_BIN_DIR="$(swift build -c "$SWIFT_CONFIG" --package-path "$ROOT/macos" --show-bin-path)"
VERBA_BIN="$SWIFT_BIN_DIR/Verba"
ICON_BIN="$SWIFT_BIN_DIR/VerbaIcon"

echo "==> [3/5] Generating Verba AppIcon.icns..."
WORK_TMP="$(mktemp -d)"
trap 'rm -rf "$WORK_TMP"' EXIT
ICONSET_DIR="$WORK_TMP/AppIcon.iconset"
"$ICON_BIN" "$ICONSET_DIR" $DEV_FLAG
iconutil -c icns "$ICONSET_DIR" -o "$WORK_TMP/AppIcon.icns"

echo "==> [4/5] Assembling build/Verba.app..."
APP_DIR="$ROOT/build/Verba.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$VERBA_BIN" "$APP_DIR/Contents/MacOS/Verba"
cp "$ENGINE_BIN" "$APP_DIR/Contents/MacOS/verba-engine"
chmod +x "$APP_DIR/Contents/MacOS/Verba" "$APP_DIR/Contents/MacOS/verba-engine"

cp "$WORK_TMP/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT/macos/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"

echo "==> [5/5] Signing bundle..."
codesign --force --sign - --identifier "com.verba.verba-engine" --requirements '=designated => identifier "com.verba.verba-engine"' "$APP_DIR/Contents/MacOS/verba-engine"
codesign --force --sign - --identifier "com.verba.app" --requirements '=designated => identifier "com.verba.app"' "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built: $APP_DIR (v$VERSION)"
