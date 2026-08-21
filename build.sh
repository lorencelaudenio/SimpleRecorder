#!/bin/bash
set -e

APP_NAME="SimpleRecorder"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_FILE="AppIcon.icns"
DMG_DIR="$(mktemp -d)"
DMG_FILE="$BUILD_DIR/$APP_NAME.dmg"

trap 'rm -rf "$DMG_DIR"' EXIT

echo "=== Cleaning previous build ==="

rm -rf "$BUILD_DIR"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"


# ============================================================
# Build Swift application
# ============================================================

echo "=== Compiling $APP_NAME ==="

swiftc -parse-as-library Sources/main.swift \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    -target x86_64-apple-macos12.3

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"


# ============================================================
# Copy Info.plist
# ============================================================

echo "=== Installing Info.plist ==="

cp Info.plist \
    "$APP_BUNDLE/Contents/Info.plist"


# ============================================================
# Install application icon
# ============================================================

echo "=== Installing app icon ==="

if [ ! -f "$ICON_FILE" ]; then
    echo "ERROR: $ICON_FILE was not found."
    echo "Put your .icns file next to build.sh."
    exit 1
fi

cp "$ICON_FILE" \
    "$APP_BUNDLE/Contents/Resources/AppIcon.icns"


# ============================================================
# Tell macOS which icon to use
# ============================================================

echo "=== Configuring app icon ==="

PLIST="$APP_BUNDLE/Contents/Info.plist"

/usr/libexec/PlistBuddy \
    -c "Delete :CFBundleIconFile" \
    "$PLIST" 2>/dev/null || true

/usr/libexec/PlistBuddy \
    -c "Add :CFBundleIconFile string AppIcon.icns" \
    "$PLIST"


# ============================================================
# Code signing
# ============================================================

echo "=== Code signing ==="

codesign --force \
    --sign - \
    --entitlements Entitlements.plist \
    "$APP_BUNDLE"


# ============================================================
# Remove quarantine attributes
# ============================================================

xattr -cr "$APP_BUNDLE"


# ============================================================
# Create DMG staging directory
# ============================================================

echo "=== Preparing DMG ==="

mkdir -p "$DMG_DIR"

cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Applications shortcut
ln -s /Applications "$DMG_DIR/Applications"


# ============================================================
# Create DMG
# ============================================================

echo "=== Creating DMG ==="

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_FILE"


# ============================================================
# Cleanup DMG staging directory
# ============================================================

rm -rf "$DMG_DIR"


# ============================================================
# Finished
# ============================================================

echo ""
echo "=========================================="
echo "        BUILD SUCCESSFUL!"
echo "=========================================="
echo ""
echo "Application:"
echo "  $(pwd)/$APP_BUNDLE"
echo ""
echo "DMG:"
echo "  $(pwd)/$DMG_FILE"
echo ""
echo "Your DMG contains:"
echo "  $APP_NAME.app"
echo "  Applications shortcut"
echo ""