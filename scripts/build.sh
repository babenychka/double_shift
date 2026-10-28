#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Нужна macOS.' >&2; exit 1; }
xcrun --find swiftc >/dev/null 2>&1 || { echo 'Установите Command Line Tools: xcode-select --install' >&2; exit 1; }
VERSION="$(cat "$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Некорректный VERSION' >&2; exit 1; }
mkdir -p "$ROOT/build"
STAGE="$(mktemp -d "$ROOT/build/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/LayoutFixer.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
export MACOSX_DEPLOYMENT_TARGET=12.0
xcrun swiftc -O -module-cache-path "$ROOT/build/module-cache" "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/LayoutFixer" -framework Cocoa -framework Carbon -framework ApplicationServices
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
rm -rf "$ROOT/build/LayoutFixer.app"
mv "$APP" "$ROOT/build/LayoutFixer.app"
echo "Собрано: $ROOT/build/LayoutFixer.app ($VERSION)"
