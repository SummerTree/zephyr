#!/bin/bash
# download_pdfium.sh
# Downloads prebuilt PDFium binaries for macOS from bblanchon/pdfium-binaries.
# Places libpdfium.dylib in EngineAsBuilt/ where compile-macos.sh will find it.
#
# Usage:  bash download_pdfium.sh
#   or:   bash download_pdfium.sh --tag "chromium%2F7906"
#
# After running, rebuild and PDF vector import will work on macOS.

set -e

TAG="${1:-chromium%2F7906}"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    PLATFORM="mac-arm64"
elif [ "$ARCH" = "x86_64" ]; then
    PLATFORM="mac-x64"
else
    echo "ERROR: Unsupported architecture: $ARCH"
    echo "Manual download: https://github.com/bblanchon/pdfium-binaries/releases"
    exit 1
fi

FILENAME="pdfium-v8-${PLATFORM}.tgz"
URL="https://github.com/bblanchon/pdfium-binaries/releases/download/${TAG}/${FILENAME}"

echo "=== PDFium Binary Downloader (macOS) ==="
echo "Architecture: $ARCH → $PLATFORM"
echo "Tag:          $TAG"
echo "URL:          $URL"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$(dirname "$SCRIPT_DIR")/EngineAsBuilt"
DEST_DIR="$ENGINE_DIR"

TMP_TGZ="/tmp/${FILENAME}"
TMP_EXTRACT="/tmp/pdfium_extract"

echo "Downloading..."
curl -L --progress-bar -o "$TMP_TGZ" "$URL"

SIZE_MB=$(du -h "$TMP_TGZ" | cut -f1)
echo "Downloaded: ${SIZE_MB}"

echo "Extracting..."
rm -rf "$TMP_EXTRACT"
mkdir -p "$TMP_EXTRACT"
tar -xzf "$TMP_TGZ" -C "$TMP_EXTRACT"

# Find libpdfium.dylib in the extracted tree
DYLIB=$(find "$TMP_EXTRACT" -name "libpdfium.dylib" -type f 2>/dev/null | head -1)

if [ -z "$DYLIB" ]; then
    echo "ERROR: libpdfium.dylib not found in extracted files."
    echo "Contents:"
    find "$TMP_EXTRACT" -type f | head -20
    rm -rf "$TMP_EXTRACT" "$TMP_TGZ"
    exit 1
fi

echo "Found: $DYLIB"

# Copy to EngineAsBuilt
cp "$DYLIB" "$DEST_DIR/libpdfium.dylib"
echo "Copied to: $DEST_DIR/libpdfium.dylib"

# Cleanup
rm -rf "$TMP_EXTRACT" "$TMP_TGZ"

echo ""
echo "=== SUCCESS ==="
echo "PDFium dylib installed. Rebuild and PDF vector import will work."
echo "Run: cd Engine/EngineAsBuilt && bash compile-macos.sh"
