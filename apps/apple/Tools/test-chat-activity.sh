#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
derived="$PWD/.build/native-activity"
out="$PWD/.build/chat-art"
app="$out/Smoke.app"
exe="$app/Contents/MacOS/Smoke"
plist="$app/Contents/Info.plist"
mkdir -p "${exe%/*}" "$app/Contents/Resources" "$out/frames"
xcodebuild -quiet -scheme RakazoMac -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$derived" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
plutil -create xml1 "$plist"
plutil -insert CFBundleIdentifier -string dev.rakazo.test.avatarart "$plist"
plutil -insert CFBundleExecutable -string Smoke "$plist"
plutil -insert CFBundlePackageType -string APPL "$plist"
cp "$derived/Build/Products/Release/Rakazo Mac.app/Contents/Resources/Assets.car" "$app/Contents/Resources/"
sources=()
for source in App/*.swift App/Platform/*.swift; do
  [[ $source == App/RakazoApp.swift ]] || sources+=("$source")
done
swiftc -whole-module-optimization "${sources[@]}" Tools/ChatActivitySmoke.swift -o "$exe"
"$exe" "$out/frames"
if [[ ${1:-} == --server ]]; then
  bash Tools/with-upstream.sh "$exe" --server
fi
