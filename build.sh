#!/bin/bash
# Build script for ekctl - macOS EventKit CLI tool

set -e

echo "Building ekctl..."

# Build in release mode
swift build -c release

# Get the binary path
BINARY_PATH=".build/release/ekctl"

# Sign the binary with entitlements (required for EventKit access)
echo "Signing binary with entitlements..."
codesign --force --sign - --entitlements ekctl.entitlements "$BINARY_PATH"

echo ""
echo "Build complete!"
echo "Binary location: $BINARY_PATH"
echo ""
echo "To install system-wide, run:"
echo "  sudo cp $BINARY_PATH /usr/local/bin/ekctl"
echo ""
echo "First run will prompt for Calendar and Reminders access."
