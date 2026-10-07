#!/bin/bash
# Builds "Mac Space Finder.app" into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Mac Space Finder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacSpaceFinder "$APP/Contents/MacOS/MacSpaceFinder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built: $PWD/$APP"
echo "Run:   open \"$APP\"   (or drag it to /Applications)"
