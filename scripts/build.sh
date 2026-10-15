#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="dist/护输宝.app"
mkdir -p build/module-cache "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 一个 ZIP，同时包含 Apple 芯片和 Intel 的可执行代码。
for ARCH in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -whole-module-optimization \
        -target "$ARCH-apple-macos13.0" \
        -module-cache-path "$ROOT/build/module-cache" \
        Sources/main.swift -o "build/ChatterflyInputGuard-$ARCH"
done
xcrun lipo -create build/ChatterflyInputGuard-arm64 build/ChatterflyInputGuard-x86_64 \
    -output "$APP/Contents/MacOS/ChatterflyInputGuard"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="Chatterfly-Input-Guard-$VERSION-macOS.zip"
ditto -c -k --norsrc --keepParent "$APP" "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > SHA256SUMS.txt)
echo "已生成 dist/$ZIP"
