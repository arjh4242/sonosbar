#!/bin/bash
# Laver et installationssæt: dist/SonosBar-<version>.dmg med appen, en genvej til
# Programmer og en "Læs mig".
#
#   ./make-dmg.sh                                   – almindelig DMG (macOS advarer ved første åbning)
#   VERSION=1.1 ./make-dmg.sh                       – med versionsnummer
#
# Med et "Developer ID Application"-certifikat og en gemt notarytool-profil kan den
# signeres og notariseres, så den åbner uden advarsel på andre Mac'er:
#   SIGN_ID="Developer ID Application: Navn (TEAMID)" NOTARY_PROFILE=sonosbar ./make-dmg.sh
# (profilen oprettes én gang med: xcrun notarytool store-credentials sonosbar)
set -euo pipefail
cd "$(dirname "$0")"

export VERSION="${VERSION:-1.0}"
SIGN_ID="${SIGN_ID:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

./build.sh

STAGE=".build/dmg"
DMG="dist/SonosBar-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" dist

cp -R SonosBar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Læs mig.txt" <<TXT
SonosBar $VERSION
=================

DANSK

Installation
1. Træk SonosBar over på genvejen Applications (mappen Programmer).
2. Åbn SonosBar fra Programmer. Et højttalerikon dukker op i menulinjen.

Første gang
SonosBar er ikke notariseret af Apple, så macOS siger første gang, at appen
ikke kan åbnes. Gør sådan:
- Højreklik (eller ctrl-klik) på SonosBar i Programmer, og vælg "Åbn". Bekræft med "Åbn".
- Eller: Åbn Systemindstillinger > Anonymitet og sikkerhed, rul ned, og klik
  "Åbn alligevel" ud for SonosBar.
Tillad derefter adgang til det lokale netværk, når macOS spørger. Ellers kan
SonosBar ikke finde dine højttalere.

Mac'en skal være på samme netværk som dine Sonos-højttalere.
Under indstillinger (tandhjulet) kan du vælge tema og sprog og slå "Start ved login" til.

Kræver macOS 13 eller nyere.


ENGLISH

Installation
1. Drag SonosBar onto the Applications shortcut.
2. Open SonosBar from Applications. A speaker icon appears in the menu bar.

First launch
SonosBar is not notarized by Apple, so macOS will say it can't be opened the
first time. To open it:
- Right-click (or control-click) SonosBar in Applications and choose "Open". Confirm with "Open".
- Or: open System Settings > Privacy & Security, scroll down and click
  "Open Anyway" next to SonosBar.
Then allow local network access when macOS asks, otherwise SonosBar can't
find your speakers.

Your Mac must be on the same network as your Sonos speakers.
In settings (the gear) you can choose theme and language and turn on "Open at login".

Requires macOS 13 or later.
TXT

# "diskutil image" afløser hdiutil i nyere macOS; ældre versioner har kun hdiutil
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName "SonosBar $VERSION" "$STAGE" "$DMG" >/dev/null
else
    hdiutil create -volname "SonosBar $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
fi

if [ "$SIGN_ID" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    if [ -n "$NOTARY_PROFILE" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "Installationssæt: $(pwd)/$DMG"
