#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
derived="$root/.build/native-release"
xcodebuild -quiet -project "$root/RakazoNative.xcodeproj" -scheme RakazoMac \
  -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
app="$derived/Build/Products/Release/Rakazo Mac.app"
codesign --verify --deep --strict "$app"
open "$app"
