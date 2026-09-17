#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Yeelight QuickControl"
APP_EXECUTABLE="YeelightQuickControl"
BUNDLE_IDENTIFIER="com.utkusakallioglu.yeelightquickcontrol"
APP_VERSION="$(node -p "require(process.argv[1]).version" "$SCRIPT_DIR/package.json")"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
STAGING_ROOT="$SCRIPT_DIR/.yeelight-quickcontrol-build"
STAGING_APP="$STAGING_ROOT/$APP_NAME.app"
BUILD_DMG=false

# The Command Line Tools can ship multiple SDKs. Prefer the SDK that matches
# the installed Swift toolchain when it is available, while allowing an
# explicit override for CI or another Xcode installation.
SDK_PATH="${YEELIGHT_QUICKCONTROL_SDK:-}"
DEVELOPER_PATH="$(xcode-select -p)"
if [ -z "$SDK_PATH" ] && [ "$DEVELOPER_PATH" = "/Library/Developer/CommandLineTools" ] && [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
  SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi
if [ -z "$SDK_PATH" ]; then
  SDK_PATH="$(xcrun --show-sdk-path)"
fi

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

# Compile Swift → binary
echo "  [1/5] Compiling Swift..."
swiftc -o "$STAGING_APP/Contents/MacOS/$APP_EXECUTABLE" \
  -module-cache-path "$STAGING_ROOT/module-cache" \
  -sdk "$SDK_PATH" \
  -framework Cocoa \
  -framework WebKit \
  -framework ServiceManagement \
  -target arm64-apple-macos13.0 \
  -O \
  "$SCRIPT_DIR/SmartLights.swift"

# Copy resources into Resources
echo "  [2/5] Bundling resources..."
cp "$SCRIPT_DIR/server.js" "$STAGING_APP/Contents/Resources/"
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
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

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
