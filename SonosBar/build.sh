#!/bin/bash
# Bygger SonosBar.app (menulinje-app uden Dock-ikon) til både Apple Silicon og Intel
#   VERSION=1.1 ./build.sh                       – sæt versionsnummer
#   SIGN_ID="Developer ID Application: …" ./build.sh – signér til distribution
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_ID="${SIGN_ID:--}"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"

APP="SonosBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/SonosBar" "$APP/Contents/MacOS/SonosBar"
# Sprogfiler (dansk og engelsk)
cp -R Localization/*.lproj "$APP/Contents/Resources/"
# Programikon (laves med: swift Icon/make-icon.swift)
cp Icon/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SonosBar</string>
    <key>CFBundleDevelopmentRegion</key><string>da</string>
    <key>CFBundleLocalizations</key>
    <array><string>da</string><string>en</string></array>
    <key>CFBundleIdentifier</key><string>dk.jayh.sonosbar</string>
    <key>CFBundleExecutable</key><string>SonosBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>SonosBar skal bruge dit lokale netværk for at finde og styre dine Sonos-højttalere.</string>
</dict>
</plist>
PLIST

if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$APP"
else
    # Hærdet runtime + tidsstempel kræves af Apples notarisering
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
echo "Færdig: $(pwd)/$APP (version $VERSION)"
echo "Træk den til /Programmer, eller start den med: open $APP"
