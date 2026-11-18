#!/usr/bin/env bash
# Fetch IDevice.xcframework (MIT, github.com/jkcoxson/idevice).
set -euo pipefail

VERSION="${IDEVICE_VERSION:-v0.1.68}"
IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${IOS_ROOT}/Frameworks/IDevice.xcframework"
URL="https://github.com/jkcoxson/idevice/releases/download/${VERSION}/idevice-xcframework-${VERSION}.zip"

if [ -f "$DEST/ios-arm64/libidevice_ffi.a" ] && [ "$(cat "$DEST/.version" 2>/dev/null || true)" = "$VERSION" ]; then
    echo "IDevice.xcframework ${VERSION} already cached at $DEST"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${IDEVICE_ZIP:-}" ]; then
    cp "$IDEVICE_ZIP" "$TMP/idevice.zip"
else
    echo "Fetching jkcoxson/idevice ${VERSION}..."
    curl -fsSL -o "$TMP/idevice.zip" "$URL"
fi

unzip -q "$TMP/idevice.zip" -d "$TMP/x"
SRC="$TMP/x/swift/IDevice.xcframework/ios-arm64"
[ -d "$SRC" ] || { echo "Missing ios-arm64 slice in archive" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/ios-arm64"
cp -R "$SRC/." "$DEST/ios-arm64/"

python3 - "$DEST/Info.plist" <<'PY'
import plistlib, sys
plistlib.dump({
    "AvailableLibraries": [{
        "LibraryIdentifier": "ios-arm64",
        "LibraryPath": "libidevice_ffi.a",
        "HeadersPath": "Headers",
        "SupportedArchitectures": ["arm64"],
        "SupportedPlatform": "ios",
    }],
    "CFBundlePackageType": "XFWK",
    "XCFrameworkFormatVersion": "1.0",
}, open(sys.argv[1], "wb"))
PY

echo "$VERSION" > "$DEST/.version"
echo "IDevice.xcframework ${VERSION} ready"
