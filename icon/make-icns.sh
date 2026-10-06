#!/bin/bash
# Assembles AppIcon.icns from AppIcon.appiconset.
#
# The slices are copied, never resampled. Each size in the set was exported for
# that size, and downscaling one master to all of them is measurably worse at 16
# and 32 — a 3D render loses its silhouette long before the pixels run out.
#
# They are requantised, though, as Key54's are: pngquant at 70–95 quality, on
# copies, so the set itself stays the art as exported. iconutil re-encodes
# whatever it's given, so only the reduced colour count survives into the .icns.
#
# Needs pngquant (brew install pngquant); iconutil ships with macOS.
set -e

cd "$(dirname "$0")"
if ! command -v pngquant >/dev/null 2>&1; then
    echo "make-icns.sh needs pngquant: brew install pngquant" >&2
    exit 1
fi
SET="AppIcon.appiconset"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

for f in mac16 mac32 mac64 mac128 mac256 mac512; do cp "$SET/$f.png" "$WORK/$f.png"; done
# A slice pngquant can't bring inside 70–95 is left exactly as exported (it exits
# 99 and doesn't touch the file), so that isn't an error.
pngquant --quality=70-95 --speed 1 --ext .png --force "$WORK"/mac*.png || true

# iconset slot <- the file exported at that pixel size.
#
# Each pixel size is packed once. An @2x slot that would hold the same pixels as
# a 1x slot is left out: macOS picks an icon representation by its pixel size,
# not its slot name, so 256pt on a Retina screen takes the 512px icon_512x512.
# Packing it again as icon_256x256@2x was 242KB of a 644KB .icns, for nothing;
# likewise 128@2x (= icon_256x256) and 16@2x (= icon_32x32).
slot() { cp "$WORK/$2" "$ICONSET/$1.png"; }

slot icon_16x16        mac16.png
slot icon_32x32        mac32.png
slot icon_32x32@2x     mac64.png
slot icon_128x128      mac128.png
slot icon_256x256      mac256.png
slot icon_512x512      mac512.png

# No 512x512@2x slice, same as Key54. That one rendering is ~940KB — most of the
# .icns on its own — and only the App Store and Finder's maximum Get Info zoom
# ever ask for it. A background agent with no Dock icon renders neither, so it is
# weight with nothing on the other side of the scale. mac1024.png stays in the set
# because it is part of the artwork; it just isn't packed.
#
# appstore1024.png is unused here for a different reason: it is the opaque,
# full-bleed square the App Store wants, which is the wrong shape for a .icns.

iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "Wrote icon/AppIcon.icns ($(( $(stat -f%z AppIcon.icns) / 1024 )) KB)"
