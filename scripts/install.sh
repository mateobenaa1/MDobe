#!/bin/zsh
# Compila MDobe y lo instala en /Applications. Uso: ./scripts/install.sh
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=build/MDobe.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MDobe" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
rm -rf "$APP/Contents/Resources/Web" && cp -R Resources/Web "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
pkill -x MDobe 2>/dev/null || true
rm -rf /Applications/MDobe.app && cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MDobe.app
echo "MDobe instalado en /Applications"
