#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
RESOURCE_DIR="$ROOT_DIR/App/Resources"
MASTER_PNG="$RESOURCE_DIR/AppIcon-1024.png"
ICONSET_DIR="$RESOURCE_DIR/AppIcon.iconset"
ICNS_PATH="$RESOURCE_DIR/AppIcon.icns"

/bin/mkdir -p "$ICONSET_DIR"
/usr/bin/xcrun swift "$ROOT_DIR/Scripts/generate_icon.swift" "$MASTER_PNG"

resize_icon() {
  local size="$1"
  local output="$2"
  /usr/bin/sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_DIR/$output" >/dev/null
}

resize_icon 16 icon_16x16.png
resize_icon 32 icon_16x16@2x.png
resize_icon 32 icon_32x32.png
resize_icon 64 icon_32x32@2x.png
resize_icon 128 icon_128x128.png
resize_icon 256 icon_128x128@2x.png
resize_icon 256 icon_256x256.png
resize_icon 512 icon_256x256@2x.png
resize_icon 512 icon_512x512.png
resize_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
print "Generated macOS icon: $ICNS_PATH"
