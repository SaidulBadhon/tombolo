#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the spike and assemble "out/Tombolo Host.app" (ad-hoc signed). Command Line Tools only, no Xcode.
#   scripts/build.sh [VERSION]      VERSION goes into CFBundleVersion (default 1); bump it to simulate an update.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1}"
HOST_ID="io.github.saidulbadhon.Tombolo.spike-s13.host"

swift build -c release 2>&1 | tail -3
BIN="$(swift build -c release --show-bin-path)"
APP="out/Tombolo Host.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/tombolo-host" "$APP/Contents/MacOS/TomboloHost"
cp "$BIN/tombolo-shim" "$APP/Contents/Helpers/tombolo-shim"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>TomboloHost</string>
  <key>CFBundleIdentifier</key><string>${HOST_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Tombolo Host</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Nested code first, then the bundle. Hardened runtime like a release build would have.
codesign --force --sign - --identifier "${HOST_ID}.shim-template" --options runtime "$APP/Contents/Helpers/tombolo-shim"
codesign --force --sign - --identifier "$HOST_ID" --options runtime "$APP"
codesign --verify --strict "$APP"
echo "built $APP version $VERSION"
codesign -dvvv "$APP" 2>&1 | grep -E '^(Identifier|CDHash|Signature|CodeDirectory)'
# Measurement helper (not part of the app).
swiftc -O -o out/winlist tools/winlist.swift 2>&1 | grep -v "ld: warning" || true
clang -O2 -o out/probe_ipc probes/probe_ipc.c && codesign --force -s - out/probe_ipc 2>/dev/null
