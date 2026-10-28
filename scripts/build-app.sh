#!/bin/zsh
# Compila e empacota MediaCRTV.app em ./build. Uso: scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/MediaCRTV.app
VERSION=1.0.0

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MediaCRTV "$APP/Contents/MacOS/MediaCRTV"
strip -S "$APP/Contents/MacOS/MediaCRTV"  # tira caminhos de debug do binário

# Ferramentas embutidas (scripts/fetch-tools.sh). Mantêm a assinatura original dos autores.
if [[ -d vendor/bin ]]; then
  mkdir -p "$APP/Contents/Resources/bin" "$APP/Contents/Resources/Licenses"
  cp vendor/bin/* "$APP/Contents/Resources/bin/"
  cp vendor/yt-dlp.version "$APP/Contents/Resources/bin/yt-dlp.version"
  cp vendor/licenses/* "$APP/Contents/Resources/Licenses/"
  cp scripts/THIRD-PARTY.txt "$APP/Contents/Resources/Licenses/"
else
  echo "Aviso: vendor/bin ausente — app sem ferramentas embutidas (rode scripts/fetch-tools.sh)"
fi

# Ícone: com Xcode, compila o .icon do Icon Composer (Liquid Glass, se adapta a
# escuro/colorido/transparente). Sem Xcode, cai no PNG gerado por script.
if xcrun --find actool >/dev/null 2>&1 && [[ -d Resources/AppIcon.icon ]]; then
  rm -rf build/actool && mkdir -p build/actool
  xcrun actool Resources/AppIcon.icon \
    --compile build/actool \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist build/actool/partial.plist \
    --errors --warnings --output-format human-readable-text >/dev/null
  cp build/actool/Assets.car "$APP/Contents/Resources/"
  cp build/actool/AppIcon.icns "$APP/Contents/Resources/"
else
  ICONSET=build/MediaCRTV.iconset
  swift scripts/make-icon.swift build/icon.png
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# NSServices: aparece no botão direito do Finder (Ações Rápidas / Serviços) para vídeos e áudios.
service() {
  cat <<S
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>$1</string></dict>
      <key>NSMessage</key><string>convertFiles</string>
      <key>NSUserData</key><string>$2</string>
      <key>NSPortName</key><string>MediaCRTV</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.movie</string><string>public.audio</string></array>
    </dict>
S
}

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MediaCRTV</string>
  <key>CFBundleDisplayName</key><string>MediaCRTV</string>
  <key>CFBundleIdentifier</key><string>com.lipenoe.mediacrtv</string>
  <key>CFBundleExecutable</key><string>MediaCRTV</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Vídeo ou áudio</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.movie</string><string>public.audio</string><string>public.folder</string></array>
    </dict>
  </array>
  <key>NSServices</key>
  <array>
$(service "Converter p/ Premiere" premiere)
$(service "Converter p/ ProRes" prores)
$(service "Extrair áudio (WAV)" audio)
  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - "$APP"
echo "OK: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x MediaCRTV || true
  rm -rf /Applications/MediaCRTV.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MediaCRTV.app
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  echo "Instalado em /Applications/MediaCRTV.app"
fi
