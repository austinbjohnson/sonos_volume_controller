#!/bin/bash

# Build Sonos Volume Controller as a proper .app bundle

set -e

echo "🔨 Building Sonos Volume Controller.app..."

# Clean previous builds
rm -rf SonosVolumeController.app

# Build with Swift Package Manager
echo "📦 Compiling with Swift Package Manager..."
swift build -c release

# Create .app bundle structure
echo "📁 Creating .app bundle structure..."
mkdir -p SonosVolumeController.app/Contents/MacOS
mkdir -p SonosVolumeController.app/Contents/Resources

# Copy executable
echo "📋 Copying executable..."
cp .build/release/SonosVolumeController SonosVolumeController.app/Contents/MacOS/

# Copy Info.plist
echo "📋 Copying Info.plist..."
cp Resources/Info.plist SonosVolumeController.app/Contents/Info.plist

# Copy Resources folder (icons, etc.)
echo "📋 Copying resources..."
if [ -f Resources/SonosMenuBarIcon.svg ]; then
    cp Resources/SonosMenuBarIcon.svg SonosVolumeController.app/Contents/Resources/
fi

# Code signing
echo "🔐 Code signing..."
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.+)".*/\1/')

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "✅ Found signing identity: $SIGNING_IDENTITY"
    codesign --force --sign "$SIGNING_IDENTITY" \
        --entitlements Resources/SonosVolumeController.entitlements \
        --options runtime \
        --timestamp \
        SonosVolumeController.app/Contents/MacOS/SonosVolumeController

    codesign --force --sign "$SIGNING_IDENTITY" \
        --entitlements Resources/SonosVolumeController.entitlements \
        --options runtime \
        --timestamp \
        --deep \
        SonosVolumeController.app

    echo "✅ App signed with Developer ID"
else
    echo "⚠️  No Developer ID found, using ad-hoc signing with entitlements (works locally only)"
    codesign --force --sign - \
        --entitlements Resources/SonosVolumeController.entitlements \
        SonosVolumeController.app
fi

# Verify signature
echo "🔍 Verifying signature..."
codesign -dv SonosVolumeController.app 2>&1 | head -5

echo ""
echo "✅ Build complete: SonosVolumeController.app"
echo ""

# Optional: Install to /Applications
if [ "$1" == "--install" ] || [ "$1" == "-i" ]; then
    echo "📦 Installing to /Applications..."

    # Kill running instance if it exists
    if pgrep -x "SonosVolumeController" > /dev/null; then
        echo "⚠️  Stopping running instance..."
        pkill -x "SonosVolumeController"
        sleep 1
    fi

    # Remove old version
    if [ -d "/Applications/SonosVolumeController.app" ]; then
        echo "🗑️  Removing old version..."
        sudo rm -rf /Applications/SonosVolumeController.app
    fi

    # Copy new version
    echo "📋 Copying to /Applications..."
    sudo cp -R SonosVolumeController.app /Applications/

    echo "✅ Installed to /Applications!"
    echo ""
    echo "🚀 Launching..."
    open /Applications/SonosVolumeController.app
    echo ""
    echo "📌 To enable 'Run at Login':"
    echo "   Click menu bar icon → Preferences → General → Run at Login"
else
    echo "📌 To install to /Applications (keeps development copy):"
    echo "   ./build-app.sh --install"
    echo ""
    echo "📌 Or manually:"
    echo "   sudo cp -R SonosVolumeController.app /Applications/"
    echo "   open /Applications/SonosVolumeController.app"
fi
echo ""
echo "💡 Tip: The app runs in your menu bar without showing in the Dock"