#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/Build/Products/Release/SuperRightClick.app"
EXTENSION_PATH="$APP_PATH/Contents/PlugIns/SuperRightClickFinder.appex"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/SuperRightClick.XXXXXX")"

cleanup() {
  /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

fail() {
  print -u2 "error: $1"
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

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

[[ -d "$APP_PATH" ]] || fail "Release app was not produced at $APP_PATH"
[[ -d "$EXTENSION_PATH" ]] || fail "Embedded Finder extension is missing"

APP_INFO="$APP_PATH/Contents/Info.plist"
EXTENSION_INFO="$EXTENSION_PATH/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_INFO" "$EXTENSION_INFO" >/dev/null

APP_VERSION="$(plist_value "$APP_INFO" CFBundleShortVersionString)"
APP_BUNDLE_ID="$(plist_value "$APP_INFO" CFBundleIdentifier)"
APP_EXECUTABLE_NAME="$(plist_value "$APP_INFO" CFBundleExecutable)"
EXTENSION_BUNDLE_ID="$(plist_value "$EXTENSION_INFO" CFBundleIdentifier)"
EXTENSION_EXECUTABLE_NAME="$(plist_value "$EXTENSION_INFO" CFBundleExecutable)"
[[ -n "$APP_VERSION" && -n "$APP_BUNDLE_ID" ]] || fail "App metadata is incomplete"
[[ "$EXTENSION_BUNDLE_ID" == "$APP_BUNDLE_ID."* ]] \
  || fail "Finder extension bundle identifier is not nested under the host app identifier"

APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME"
EXTENSION_EXECUTABLE="$EXTENSION_PATH/Contents/MacOS/$EXTENSION_EXECUTABLE_NAME"
[[ -x "$APP_EXECUTABLE" ]] || fail "Host executable is missing"
[[ -x "$EXTENSION_EXECUTABLE" ]] || fail "Finder extension executable is missing"

# 无开发者证书时，Xcode 的临时签名会随构建变化。添加稳定的指定要求，
# 避免每次覆盖安装后辅助功能授权都被 TCC 识别成另一个应用。
/usr/bin/codesign \
  --force \
  --sign - \
  --options runtime \
  --requirements "=designated => identifier \"$APP_BUNDLE_ID\"" \
  "$APP_PATH"

# 验证宿主、嵌入扩展、架构集合和扩展 sandbox。这里只要求二者一致，
# 不锁定 arm64 或 x86_64，继续沿用调用者选择的构建架构。
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
APP_ARCHS="$(/usr/bin/lipo -archs "$APP_EXECUTABLE")"
EXTENSION_ARCHS="$(/usr/bin/lipo -archs "$EXTENSION_EXECUTABLE")"
[[ "$APP_ARCHS" == "$EXTENSION_ARCHS" ]] \
  || fail "Host and Finder extension architectures differ: $APP_ARCHS vs $EXTENSION_ARCHS"

ENTITLEMENTS_PATH="$STAGING_DIR/extension-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$EXTENSION_PATH" >"$ENTITLEMENTS_PATH" 2>/dev/null
/usr/bin/plutil -lint "$ENTITLEMENTS_PATH" >/dev/null
SANDBOX_VALUE="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ENTITLEMENTS_PATH" 2>/dev/null || true)"
[[ "$SANDBOX_VALUE" == "true" || "$SANDBOX_VALUE" == "1" ]] \
  || fail "Finder extension sandbox entitlement is missing"
/bin/rm -f "$ENTITLEMENTS_PATH"

DMG_PATH="$DIST_DIR/SuperRightClick-$APP_VERSION.dmg"
/bin/mkdir -p "$DIST_DIR"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/SuperRightClick.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/hdiutil create \
  -volname "SuperRightClick" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"

print "DMG created at: $DMG_PATH"
print "Validated architectures: $APP_ARCHS"
