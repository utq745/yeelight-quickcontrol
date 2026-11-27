#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Yeelight QuickControl"
APP_EXECUTABLE="YeelightQuickControl"
BUNDLE_IDENTIFIER="com.utkusakallioglu.yeelightquickcontrol"
APP_VERSION="$(sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]+)".*/\1/p' "$SCRIPT_DIR/package.json" | head -n 1)"
if [ -z "$APP_VERSION" ]; then
  echo "Could not read version from package.json" >&2
  exit 1
fi
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
STAGING_ROOT="$SCRIPT_DIR/.yeelight-quickcontrol-build"
STAGING_APP="$STAGING_ROOT/$APP_NAME.app"
BUILD_DMG=false

# Use the active developer directory's SDK. Set YEELIGHT_QUICKCONTROL_SDK to
# override it (for example when the Command Line Tools ship several SDKs and
# the default one does not match the Swift toolchain).
SDK_PATH="${YEELIGHT_QUICKCONTROL_SDK:-$(xcrun --show-sdk-path)}"
# Space-separated list; the default produces a universal binary.
ARCHS="${YEELIGHT_QUICKCONTROL_ARCHS:-arm64 x86_64}"

for arg in "$@"; do
  case "$arg" in
    --dmg) BUILD_DMG=true ;;
  esac
done

echo ""
echo "  Building $APP_NAME..."
echo ""

# Build in a staging directory so a compiler failure never destroys the
# last working application bundle.
rm -rf "$STAGING_ROOT"

# Create .app bundle structure
mkdir -p "$STAGING_APP/Contents/MacOS"
mkdir -p "$STAGING_APP/Contents/Resources"
mkdir -p "$STAGING_ROOT/module-cache"

# Compile Swift → one binary per architecture, then merge them
echo "  [1/5] Compiling Swift ($ARCHS)..."
SLICES=()
for ARCH in $ARCHS; do
  swiftc -o "$STAGING_ROOT/$APP_EXECUTABLE-$ARCH" \
    -module-name YeelightQuickControl \
    -module-cache-path "$STAGING_ROOT/module-cache" \
    -sdk "$SDK_PATH" \
    -framework Cocoa \
    -framework WebKit \
    -framework ServiceManagement \
    -framework Network \
    -target "$ARCH-apple-macos13.0" \
    -O \
    "$SCRIPT_DIR"/macos/*.swift
  SLICES+=("$STAGING_ROOT/$APP_EXECUTABLE-$ARCH")
done
lipo -create "${SLICES[@]}" -output "$STAGING_APP/Contents/MacOS/$APP_EXECUTABLE"

# Copy resources into Resources
echo "  [2/5] Bundling resources..."
cp "$SCRIPT_DIR/dashboard.html" "$STAGING_APP/Contents/Resources/"
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/AppIcon.icns" "$STAGING_APP/Contents/Resources/"
fi

# Create Info.plist
echo "  [3/5] Creating Info.plist..."
cat > "$STAGING_APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_IDENTIFIER</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>yeelight-quickcontrol</string>
            </array>
        </dict>
    </array>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Yeelight QuickControl finds and controls Yeelight bulbs on your local network.</string>
</dict>
</plist>
PLIST

# Action helpers: tiny background apps for tools that can only "open an
# application" (Logi Options+ Smart Actions, Stream Deck, …). Each forwards one
# yeelight-quickcontrol:// URL to the main app and quits.
echo "  [3b] Building action helpers..."
HELPER_SLICES=()
for ARCH in $ARCHS; do
  swiftc -o "$STAGING_ROOT/ActionHelper-$ARCH" \
    -module-name YQCActionHelper \
    -module-cache-path "$STAGING_ROOT/module-cache" \
    -sdk "$SDK_PATH" \
    -framework AppKit \
    -target "$ARCH-apple-macos13.0" \
    -Osize \
    "$SCRIPT_DIR/macos/ActionHelper/main.swift"
  HELPER_SLICES+=("$STAGING_ROOT/ActionHelper-$ARCH")
done
lipo -create "${HELPER_SLICES[@]}" -output "$STAGING_ROOT/ActionHelper"

# Small icon (≤128 px; tools show these at ~40 px) so nine helpers don't each
# carry the 1 MB app icon.
HELPER_ICON=""
if [ -f "$SCRIPT_DIR/AppIcon.png" ]; then
  ICONSET="$STAGING_ROOT/HelperIcon.iconset"
  mkdir -p "$ICONSET"
  for SIZE in 16 32 64 128; do
    sips -z "$SIZE" "$SIZE" "$SCRIPT_DIR/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null
  done
  cp "$ICONSET/icon_32x32.png" "$ICONSET/icon_16x16@2x.png"
  mv "$ICONSET/icon_64x64.png" "$ICONSET/icon_32x32@2x.png"
  iconutil -c icns -o "$STAGING_ROOT/HelperIcon.icns" "$ICONSET"
  HELPER_ICON="$STAGING_ROOT/HelperIcon.icns"
fi

# "File name|command" — file names are what users pick in Options+.
HELPER_ACTIONS=(
  "Toggle Light|toggle"
  "Light On|on"
  "Light Off|off"
  "Brightness Up|brightness/up"
  "Brightness Down|brightness/down"
  "Favorite 1|favorite/1"
  "Favorite 2|favorite/2"
  "Favorite 3|favorite/3"
  "Favorite 4|favorite/4"
)
mkdir -p "$STAGING_APP/Contents/Helpers"
for ENTRY in "${HELPER_ACTIONS[@]}"; do
  HELPER_NAME="${ENTRY%%|*}"
  HELPER_COMMAND="${ENTRY#*|}"
  HELPER_ID="$BUNDLE_IDENTIFIER.action.$(echo "$HELPER_COMMAND" | tr '/' '-')"
  HELPER_APP="$STAGING_APP/Contents/Helpers/$HELPER_NAME.app"
  mkdir -p "$HELPER_APP/Contents/MacOS" "$HELPER_APP/Contents/Resources"
  cp "$STAGING_ROOT/ActionHelper" "$HELPER_APP/Contents/MacOS/ActionHelper"
  [ -n "$HELPER_ICON" ] && cp "$HELPER_ICON" "$HELPER_APP/Contents/Resources/AppIcon.icns"
  cat > "$HELPER_APP/Contents/Info.plist" << HPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ActionHelper</string>
    <key>CFBundleIdentifier</key>
    <string>$HELPER_ID</string>
    <key>CFBundleName</key>
    <string>$HELPER_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>YQCCommandURL</key>
    <string>yeelight-quickcontrol://$HELPER_COMMAND</string>
</dict>
</plist>
HPLIST
  codesign --force --sign - --timestamp=none "$HELPER_APP"
done

echo "  [4/5] Applying ad-hoc signature..."
codesign --force --sign - --timestamp=none "$STAGING_APP"

echo "  [5/5] Finalizing bundle..."
rm -rf "$APP_DIR"
mv "$STAGING_APP" "$APP_DIR"
rm -rf "$STAGING_ROOT"
echo ""
echo "  ✓ App build complete!"
echo "  📦 $(du -sh "$APP_DIR" | cut -f1)  $APP_DIR"

if [ "$BUILD_DMG" = true ]; then
  echo ""
  echo "  Creating DMG distribution..."
  DMG_NAME="YeelightQuickControl-macOS.dmg"
  DMG_PATH="$SCRIPT_DIR/$DMG_NAME"
  rm -f "$DMG_PATH"

  DMG_TMP="$(mktemp -d)"
  cp -R "$APP_DIR" "$DMG_TMP/"
  ln -s /Applications "$DMG_TMP/Applications"

  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_TMP" \
    -ov \
    -format UDZO \
    "$DMG_PATH" > /dev/null

  rm -rf "$DMG_TMP"
  echo "  ✓ DMG created: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
fi

echo ""
echo "  Run:  open \"$APP_DIR\""
echo ""
