#!/bin/bash

# Build the Sonos Volume Controller app

echo "Building Sonos Volume Controller..."

# Compile all Swift files
swiftc \
  -o SonosVolumeController \
  -framework Cocoa \
  -framework CoreAudio \
  -framework ApplicationServices \
  Sources/*.swift

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    echo "Run with: ./SonosVolumeController"
else
    echo "❌ Build failed"
    exit 1
fi