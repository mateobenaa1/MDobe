#!/bin/zsh
# Compila la app de iPad sin firmar y genera build/MDobe.ipa para instalarla con AltStore.
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project MDobe.xcodeproj -scheme MDobeiPad -configuration Release -sdk iphoneos \
  -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet build
rm -rf build/Payload build/MDobe.ipa
mkdir -p build/Payload
cp -R build/ios/Build/Products/Release-iphoneos/MDobe.app build/Payload/
(cd build && zip -qr MDobe.ipa Payload && rm -rf Payload)
echo "Listo: $(pwd)/build/MDobe.ipa"
