#!/bin/bash
# Собирает universal (Intel + Apple Silicon) "Release Launcher.app"
set -e
cd "$(dirname "$0")"
APP="Release Launcher.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ReleaseLauncher"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ReleaseLauncher"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Готово: $APP ($(lipo -archs "$APP/Contents/MacOS/ReleaseLauncher"))"
