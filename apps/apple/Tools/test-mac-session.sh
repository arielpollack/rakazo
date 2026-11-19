#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEST_RUNNER_RAKAZO_TEST_ORIGIN:?Run via Tools/with-upstream.sh}"
mkdir -p .build
dir=$(mktemp -d "$PWD/.build/mac-session.XXXXXXXX")
app="$dir/SessionSmoke.app"
exe="$app/Contents/MacOS/SessionSmoke"
plist="$app/Contents/Info.plist"
mkdir -p "${exe%/*}"
plutil -create xml1 "$plist"
plutil -insert CFBundleIdentifier -string "dev.rakazo.smoke.session.s$(uuidgen)" "$plist"
plutil -insert CFBundleExecutable -string SessionSmoke "$plist"
plutil -insert CFBundlePackageType -string APPL "$plist"
plutil -insert CFBundleVersion -string 1 "$plist"
plutil -insert LSBackgroundOnly -bool YES "$plist"
swiftc App/{Models,Connection,Sample,SampleComputer,IntegrationLibrary,WorkspaceStore,PrivateSpace,MarketplaceCatalog,ManagedIntegrations,ManagedServers}.swift Tools/MacSessionSmoke.swift -o "$exe"
codesign --force --sign - --options runtime --entitlements Config/RakazoMac.entitlements "$app"
trap '"$exe" clean' EXIT
"$exe" sign-in
unset TEST_RUNNER_RAKAZO_TEST_PASSWORD
"$exe" restore-and-sign-out
"$exe" verify-signed-out
echo 'PASS: sandboxed sign-in → quit → reopen without credentials → authenticated workspace → sign out → reopen signed out.'
