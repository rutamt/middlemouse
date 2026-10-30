#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="FreeWheel.app"
BUILD_DIR="build"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos13.0"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

mkdir -p "$BUILD_DIR"

echo "==> Generating icons"
swiftc -O -swift-version 5 generate_icon.swift -o "$BUILD_DIR/generate_icon"
"$BUILD_DIR/generate_icon" "$BUILD_DIR"

echo "==> Compiling FreeWheel ($ARCH)"
swiftc -O -whole-module-optimization -swift-version 5 \
    -target "$TARGET" \
    -Xlinker -dead_strip \
    -o "$BUILD_DIR/FreeWheel" \
    main.swift EventTapManager.swift TrackpadManager.swift
strip -x "$BUILD_DIR/FreeWheel"

echo "==> Packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/FreeWheel" "$APP/Contents/MacOS/FreeWheel"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$BUILD_DIR/MenuBarIcon.pdf" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing"
# Stray extended attributes make codesign fail with "resource fork ... not allowed".
xattr -cr "$APP"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> Built $PWD/$APP ($(du -sh "$APP" | cut -f1), binary $(du -h "$APP/Contents/MacOS/FreeWheel" | cut -f1))"
