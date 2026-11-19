#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
derived="$PWD/.build/native-release"
out="$PWD/.build/chat-interaction-qa"
bundle="$out/Fixture.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources" "$out/frames"
xcodebuild -quiet -scheme RakazoMac -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
plutil -create xml1 "$bundle/Info.plist"
plutil -insert CFBundleIdentifier -string dev.rakazo.test.chatactions "$bundle/Info.plist"
plutil -insert CFBundleExecutable -string Smoke "$bundle/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$bundle/Info.plist"
cp "$derived/Build/Products/Release/Rakazo Mac.app/Contents/Resources/Assets.car" "$bundle/Resources/"
bash Tools/compile-mac-smoke.sh Tools/ChatInteractionSmoke.swift "$bundle/MacOS/Smoke"
"$bundle/MacOS/Smoke" "$out/frames"
