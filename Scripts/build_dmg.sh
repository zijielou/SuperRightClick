#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/Build/Products/Release/SuperRightClick.app"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/SuperRightClick-0.1.0.dmg"
STAGING_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/SuperRightClick.XXXXXX")"

cleanup() {
  /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/Scripts/generate_icon.sh"

/usr/bin/xcodebuild \
  -project "$ROOT_DIR/SuperRightClick.xcodeproj" \
  -scheme "SuperRightClick" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES \
  build

# 无开发者证书时，Xcode 的临时签名会随构建变化。添加稳定的指定要求，
# 避免每次覆盖安装后辅助功能授权都被 TCC 识别成另一个应用。
/usr/bin/codesign \
  --force \
  --sign - \
  --options runtime \
  --requirements '=designated => identifier "local.SuperRightClick"' \
  "$APP_PATH"

/bin/mkdir -p "$DIST_DIR"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/SuperRightClick.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/hdiutil create \
  -volname "SuperRightClick" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

print "DMG created at: $DMG_PATH"
