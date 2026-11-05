#!/usr/bin/env bash
# Builds MacKVM.app: compiles the launcher, bundles the MacKVM server binary, and
# signs both with the Apple Development identity so the keychain "always allow"
# answer survives rebuilds. Usage: build.sh [server-repo] [install-dir]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=${1:-$(cd "$here/../.." && pwd)}
dest=${2:-$HOME/Applications}
identity=$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)

out="$here/build"
app="$out/MacKVM.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

echo "== build server ($repo)"
(cd "$repo" && swift build --product MacKVM)
cp "$repo/.build/debug/MacKVM" "$app/Contents/Resources/MacKVM"

cp "$here/Icon/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
echo "== build launcher"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o "$app/Contents/MacOS/MacKVMLauncher" "$here/Sources/main.swift"

cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>MacKVMLauncher</string>
  <key>CFBundleIdentifier</key><string>tw.jet-opto.mackvm.launcher</string>
  <key>CFBundleName</key><string>MacKVM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

if [ -n "$identity" ]; then
  echo "== sign with $identity"
  codesign --force --options runtime --timestamp=none -s "$identity" \
    -i tw.jet-opto.mackvm.server "$app/Contents/Resources/MacKVM"
  codesign --force --options runtime --timestamp=none -s "$identity" "$app"
else
  echo "== no Apple Development identity; ad-hoc signing (keychain will ask after each rebuild)"
  codesign --force -s - -i tw.jet-opto.mackvm.server "$app/Contents/Resources/MacKVM"
  codesign --force -s - "$app"
fi

mkdir -p "$dest"
rm -rf "$dest/MacKVM.app"
cp -R "$app" "$dest/"
echo "== installed $dest/MacKVM.app"
