#!/bin/bash
# Copy app-icon PNGs from handoff/icon/png/ into the Xcode asset catalog.
#
# Run after the design team drops a new icon revision into handoff/icon/png/.
# Usage:  scripts/sync_icons.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/handoff/icon/png"
APPICON="$ROOT/Dictly/Dictly/Assets.xcassets/AppIcon.appiconset"
BRAND="$ROOT/Dictly/Dictly/Assets.xcassets/BrandIcon.imageset"

if [ ! -d "$SRC" ]; then
  echo "error: $SRC not found — handoff/icon/png is missing" >&2
  exit 1
fi

# AppIcon — every macOS slot wants the squircle-shaped PNG. The system does NOT mask
# macOS app icons (unlike iOS), so the rounded silhouette must already be baked in.
rm -f "$APPICON"/*.png
cp "$SRC/icon-16-squircle.png"   "$APPICON/icon_16.png"
cp "$SRC/icon-32-squircle.png"   "$APPICON/icon_16@2x.png"
cp "$SRC/icon-32-squircle.png"   "$APPICON/icon_32.png"
cp "$SRC/icon-64-squircle.png"   "$APPICON/icon_32@2x.png"
cp "$SRC/icon-128-squircle.png"  "$APPICON/icon_128.png"
cp "$SRC/icon-256-squircle.png"  "$APPICON/icon_128@2x.png"
cp "$SRC/icon-256-squircle.png"  "$APPICON/icon_256.png"
cp "$SRC/icon-512-squircle.png"  "$APPICON/icon_256@2x.png"
cp "$SRC/icon-512-squircle.png"  "$APPICON/icon_512.png"
cp "$SRC/icon-1024-squircle.png" "$APPICON/icon_512@2x.png"
echo "✓ AppIcon.appiconset (10 squircle PNGs)"

# BrandIcon — used in onboarding header / about panel via NSImage(named: "BrandIcon").
# Same source PNGs, just two scales.
rm -f "$BRAND"/*.png
cp "$SRC/icon-128-squircle.png" "$BRAND/brand-icon.png"
cp "$SRC/icon-256-squircle.png" "$BRAND/brand-icon@2x.png"
echo "✓ BrandIcon.imageset (128 + 256 squircle)"

# Menu-bar templates — sourced from handoff/menubar-*.svg via a small Swift helper that
# reads SVG into NSImage and writes 22 + 44 px PNGs into the matching ImageSets.
cd "$ROOT"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun swift "$ROOT/scripts/sync_menubar_icons.swift"
