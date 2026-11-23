#!/bin/bash
# Сборка под текущий Mac (Intel) БЕЗ Xcode — достаточно Command Line Tools:
#   xcode-select --install
set -e
cd "$(dirname "$0")"
APP="Release Launcher.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ReleaseLauncher"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ReleaseLauncher"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Готово: $APP ($(lipo -archs "$APP/Contents/MacOS/ReleaseLauncher"))"
open .
