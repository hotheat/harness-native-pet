#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${DSH_NATIVE_PET_DIST_DIR:-$ROOT/dist}"
APP="$DIST/DSH Native Pet.app"
swift build --package-path "$ROOT/native" -c release --product DSHNativePet
swift build --package-path "$ROOT/native" -c release --product PetHookCLI
BIN_DIR="$(swift build --package-path "$ROOT/native" -c release --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DSHNativePet" "$APP/Contents/MacOS/DSHNativePet"
cp "$BIN_DIR/PetHookCLI" "$APP/Contents/MacOS/pet-hook"
cp "$ROOT/scripts/install-hooks.py" "$APP/Contents/Resources/install-hooks.py"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
for PACK in Character DSHPet; do
  test -f "$ROOT/native/Sources/DSHNativePet/Resources/$PACK/manifest.json"
  rm -rf "$APP/Contents/Resources/$PACK"
  cp -R "$ROOT/native/Sources/DSHNativePet/Resources/$PACK" "$APP/Contents/Resources/$PACK"
done
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/pet-hook"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
echo "$APP"
