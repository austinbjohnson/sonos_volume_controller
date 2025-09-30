#!/bin/bash

# Build Sonos Volume Controller as a proper .app bundle

set -e

echo "🔨 Building Sonos Volume Controller.app..."

# Clean previous builds
rm -rf SonosVolumeController.app

# Build with Swift Package Manager
swift build -c release

# Create .app bundle structure
mkdir -p SonosVolumeController.app/Contents/MacOS
mkdir -p SonosVolumeController.app/Contents/Resources

# Copy executable
cp .build/release/SonosVolumeController SonosVolumeController.app/Contents/MacOS/

# Copy Info.plist
cp Resources/Info.plist SonosVolumeController.app/Contents/Info.plist

echo "✅ Build complete: SonosVolumeController.app"
echo "Run with: open SonosVolumeController.app"