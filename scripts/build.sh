#!/bin/bash
# Builds a signed Intent Mode package with the Xcode Command Line Tools.
#
#   scripts/build.sh ["changelog text"]
#
# Output: build/IntentMode-<version>/ and build/IntentMode-<version>.tar.gz
# Nothing is installed; this only builds. Bump the VERSION file before building an update.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VER="$(tr -d ' \n' < VERSION)"
CHANGELOG="${1:-}"
KEY_DIR="$HOME/.intentmode"
KEY="$KEY_DIR/signing_key"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift not found. Install the Command Line Tools first:  xcode-select --install"
  exit 1
fi

echo "==> Building Intent Mode $VER"
# Stamp the version into the code.
sed -i '' -E "s/(static let version = )\"[^\"]*\"/\1\"$VER\"/" Sources/IntentCore/BuildInfo.swift

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

OUT="$ROOT/build/IntentMode-$VER"
rm -rf "$OUT" "$ROOT/build/IntentMode-$VER.tar.gz"
mkdir -p "$OUT/bin" "$OUT/Resources"

cp "$BIN/intentmoded" "$BIN/intentmode" "$BIN/intentguard" "$OUT/bin/"

APP="$OUT/IntentScreen.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/IntentScreen" "$APP/Contents/MacOS/IntentScreen"
sed "s/__VERSION__/$VER/g" Resources/IntentScreen-Info.plist > "$APP/Contents/Info.plist"

cp Resources/config.default.json Resources/emergency-off.sh Resources/uninstall.sh "$OUT/Resources/"
cp -R Resources/launchd Resources/chrome "$OUT/Resources/"
mkdir -p "$OUT/Resources/blocklists"
cp -R Resources/blocklists/. "$OUT/Resources/blocklists/" 2>/dev/null || true
cp scripts/install.sh "$OUT/install.sh"
chmod +x "$OUT/install.sh" "$OUT/Resources/emergency-off.sh" "$OUT/Resources/uninstall.sh"
echo "$VER" > "$OUT/VERSION"
printf '%s\n' "$CHANGELOG" > "$OUT/CHANGELOG.txt"

echo "==> Ad-hoc code signing (required on Apple Silicon)"
codesign --force --sign - "$OUT/bin/intentmoded" "$OUT/bin/intentmode" "$OUT/bin/intentguard"
codesign --force --sign - "$APP"

echo "==> Update-signing key"
if [ ! -f "$KEY" ]; then
  "$OUT/bin/intentmode" keygen
fi
cp "$KEY.pub" "$OUT/Resources/update_pubkey.b64"

echo "==> Self-test"
"$OUT/bin/intentmoded" --self-test --config "$OUT/Resources/config.default.json"

echo "==> Signing package"
"$OUT/bin/intentmode" sign "$OUT" --key "$KEY" --version "$VER" --changelog "$CHANGELOG"

tar -C "$ROOT/build" -czf "$ROOT/build/IntentMode-$VER.tar.gz" "IntentMode-$VER"

echo
echo "Built: $OUT"
echo "       $ROOT/build/IntentMode-$VER.tar.gz"
echo
echo "First install:      sudo \"$OUT/install.sh\""
echo "Update an install:  intentmode update propose \"$ROOT/build/IntentMode-$VER.tar.gz\""
