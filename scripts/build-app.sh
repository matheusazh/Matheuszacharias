#!/bin/zsh
# Compila e empacota Music Split.app em ./build.
# Uso: scripts/build-app.sh [--dev] [--install]
#   --dev      não embute Python/modelos (usa engine/.venv do código-fonte); build rápido para testar a interface
#   --install  copia para /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-build/Music Split.app}"   # make-dmg usa build/full para não mexer no app de teste aberto
VERSION=1.0.0
BUILD_NUMBER=1
DEV=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=1 ;;
    --install) INSTALL=1 ;;
  esac
done

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MusicSplit "$APP/Contents/MacOS/MusicSplit"
(( DEV )) || strip -S "$APP/Contents/MacOS/MusicSplit"  # tira caminhos de debug do binário

if [[ $DEV == 0 ]]; then
  # Ferramentas (scripts/fetch-tools.sh): ffmpeg, ffprobe, yt-dlp, deno — mantêm a assinatura dos autores.
  if [[ -d vendor/bin ]]; then
    mkdir -p "$APP/Contents/Resources/bin"
    cp vendor/bin/* "$APP/Contents/Resources/bin/"
  else
    echo "Aviso: vendor/bin ausente (rode scripts/fetch-tools.sh)"
  fi
  # Python do motor (scripts/build-engine.sh) e o pacote splitter_engine
  if [[ -d vendor/python ]]; then
    ditto vendor/python "$APP/Contents/Resources/python"
    mkdir -p "$APP/Contents/Resources/engine"
    ditto engine/splitter_engine "$APP/Contents/Resources/engine/splitter_engine"
    find "$APP/Contents/Resources/engine" -name "__pycache__" -type d -prune -exec rm -rf {} +
    # Sem caminhos da máquina de build: shebangs dos scripts do pip e .pyc gerados em execuções locais
    PYDIR="$APP/Contents/Resources/python"
    find "$PYDIR" -name "__pycache__" -type d -prune -exec rm -rf {} +
    for f in "$PYDIR"/bin/*(.N); do
      if head -c 2 "$f" | grep -q '#!' && head -1 "$f" | grep -q "$PWD"; then
        sed -i '' '1s|.*|#!/usr/bin/env python3|' "$f"
      fi
    done
    sed -i '' "s|$PWD/vendor/[^'\" ]*|/python|g" "$PYDIR"/lib/python3.12/_sysconfigdata_*.py
    grep -rlaF "$HOME" "$PYDIR/lib" --include="*.so" | while read -r so; do strip -x -S "$so" 2>/dev/null; done
    "$PYDIR/bin/python3" -m compileall -q -j0 -s "$PYDIR" -p /python "$PYDIR/lib" >/dev/null || true
    "$PYDIR/bin/python3" -m compileall -q -j0 -s "$APP/Contents/Resources" -p / "$APP/Contents/Resources/engine" >/dev/null
  else
    echo "Aviso: vendor/python ausente (rode scripts/build-engine.sh)"
  fi
  # Modelos (scripts/fetch-models.sh)
  if [[ -d vendor/models ]]; then
    ditto vendor/models "$APP/Contents/Resources/models"
  else
    echo "Aviso: vendor/models ausente (rode scripts/fetch-models.sh)"
  fi
  mkdir -p "$APP/Contents/Resources/Licenses"
  cp scripts/THIRD-PARTY.txt "$APP/Contents/Resources/Licenses/" 2>/dev/null || true
  [[ -d vendor/licenses ]] && cp vendor/licenses/* "$APP/Contents/Resources/Licenses/" || true
fi

# Ícone Liquid Glass do Icon Composer
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
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Music Split</string>
  <key>CFBundleDisplayName</key><string>Music Split</string>
  <key>CFBundleIdentifier</key><string>com.matheusazh.musicsplit</string>
  <key>CFBundleExecutable</key><string>MusicSplit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Áudio ou vídeo</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.audio</string><string>public.movie</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Assinatura ad-hoc: primeiro cada binário do Python (dylib/so), depois o app.
if [[ -d "$APP/Contents/Resources/python" ]]; then
  find "$APP/Contents/Resources/python" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 |
    xargs -0 file | grep -E "Mach-O" | cut -d: -f1 | while read -r bin; do
      codesign --force --sign - "$bin" 2>/dev/null || true
    done
fi
codesign --force --sign - "$APP"
echo "OK: $APP ($(du -sh "$APP" | cut -f1))"

if [[ $INSTALL == 1 ]]; then
  rm -rf "/Applications/Music Split.app"
  ditto "$APP" "/Applications/Music Split.app"
  echo "Instalado em /Applications/Music Split.app"
fi
