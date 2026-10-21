#!/bin/zsh
# Gera build/SplitterCRTV-<versão>.dmg com o app completo (motor e modelos embutidos),
# atalho para Aplicativos, LEIA-ME e licenças. Uso: scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export APP=build/full/SplitterCRTV.app
mkdir -p build/full
scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=build/dmg
DMG=build/SplitterCRTV-${VERSION}.dmg

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SplitterCRTV.app"
ln -s /Applications "$STAGE/Aplicativos"
cp scripts/LEIA-ME.txt "$STAGE/LEIA-ME.txt"
cp scripts/THIRD-PARTY.txt "$STAGE/Licenças de terceiros.txt"

# ULFO (LZFSE): rápido e chega a ~1,6 GB; LZMA ganharia pouco (os modelos quase não comprimem) e leva 25 min
hdiutil create -volname "SplitterCRTV" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign - "$DMG"

SIZE=$(stat -f%z "$DMG")
echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
if (( SIZE > 2000000000 )); then
  echo "Atenção: passou de 2 GB (limite de arquivo do WhatsApp). Use Google Drive/AirDrop ou deixe um modelo para baixar sob demanda."
fi
