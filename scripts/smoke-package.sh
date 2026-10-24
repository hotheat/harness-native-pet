#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${DSH_NATIVE_PET_DIST_DIR:-$ROOT/dist}"
TMP="$(mktemp -d /tmp/dnp-package.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
/usr/bin/ditto "$DIST/DSH Native Pet.app" "$TMP/Moved Pet.app"
DSH_NATIVE_PET_RUNTIME_DIR="$TMP/runtime" "$TMP/Moved Pet.app/Contents/MacOS/DSHNativePet" --smoke-test
/usr/bin/codesign --verify --strict --verbose=2 "$TMP/Moved Pet.app"
echo 'Relocated application smoke passed'
