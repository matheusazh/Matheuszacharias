#!/bin/zsh
# Gera build/MediaCRTV-<versão>.dmg com o app, atalho para Aplicativos e LEIA-ME.
# Uso: scripts/make-dmg.sh   (roda build-app.sh antes)
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/MediaCRTV.app/Contents/Info.plist)
STAGE=build/dmg
DMG=build/MediaCRTV-${VERSION}.dmg

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/MediaCRTV.app "$STAGE/"
ln -s /Applications "$STAGE/Aplicativos"
cp scripts/LEIA-ME.txt "$STAGE/LEIA-ME.txt"
cp scripts/THIRD-PARTY.txt "$STAGE/Licenças de terceiros.txt"

hdiutil create -volname "MediaCRTV" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign - "$DMG"

echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
