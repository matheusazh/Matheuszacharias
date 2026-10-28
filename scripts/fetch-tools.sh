#!/bin/zsh
# Baixa as ferramentas embutidas no app (Apple Silicon) para vendor/bin.
# Rode de novo para atualizar. Uso: scripts/fetch-tools.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR=vendor
DL=$VENDOR/downloads
BIN=$VENDOR/bin
mkdir -p "$DL" "$BIN" "$VENDOR/licenses"

fetch() { echo "↓ $2"; curl -fL --progress-bar -o "$DL/$2" "$1"; }

# yt-dlp (binário oficial universal) + checksum publicado no release
fetch https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos yt-dlp_macos
fetch https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS yt-dlp.sha256
expected=$(awk '$2=="yt-dlp_macos"{print $1}' "$DL/yt-dlp.sha256")
actual=$(shasum -a 256 "$DL/yt-dlp_macos" | awk '{print $1}')
[[ "$expected" == "$actual" ]] || { echo "Checksum do yt-dlp não confere"; exit 1; }
install -m 755 "$DL/yt-dlp_macos" "$BIN/yt-dlp"
fetch https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/LICENSE yt-dlp-LICENSE
cp "$DL/yt-dlp-LICENSE" "$VENDOR/licenses/yt-dlp.txt"

# deno + checksum publicado no release
fetch https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip deno.zip
fetch https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip.sha256sum deno.sha256
expected=$(grep -oE '[0-9a-f]{64}' "$DL/deno.sha256" | head -1)
actual=$(shasum -a 256 "$DL/deno.zip" | awk '{print $1}')
[[ "$expected" == "$actual" ]] || { echo "Checksum do deno não confere"; exit 1; }
unzip -oq "$DL/deno.zip" -d "$DL/deno" && install -m 755 "$DL/deno/deno" "$BIN/deno"
fetch https://raw.githubusercontent.com/denoland/deno/main/LICENSE.md deno-LICENSE
cp "$DL/deno-LICENSE" "$VENDOR/licenses/deno.txt"

# ffmpeg + ffprobe estáticos (build de Martin Riedl, GPL)
for tool in ffmpeg ffprobe; do
  url=$(curl -fsL -r 0-0 -o /dev/null -w '%{url_effective}' "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/$tool.zip")
  fetch "$url" "$tool.zip"
  expected=$(curl -fsL "$url.sha256" | awk '{print $1}')
  actual=$(shasum -a 256 "$DL/$tool.zip" | awk '{print $1}')
  [[ "$expected" == "$actual" ]] || { echo "Checksum do $tool não confere"; exit 1; }
  unzip -oq "$DL/$tool.zip" -d "$DL/$tool" && install -m 755 "$DL/$tool/$tool" "$BIN/$tool"
done
fetch https://www.gnu.org/licenses/gpl-3.0.txt gpl-3.0.txt
cp "$DL/gpl-3.0.txt" "$VENDOR/licenses/ffmpeg-GPL-3.0.txt"

# Tira a quarentena dos binários baixados e registra versões
xattr -cr "$BIN"
{
  echo "yt-dlp  $("$BIN/yt-dlp" --version < /dev/null)"
  echo "deno    $("$BIN/deno" --version | head -1)"
  echo "ffmpeg  $("$BIN/ffmpeg" -version | head -1)"
  echo "ffprobe $("$BIN/ffprobe" -version | head -1)"
} | tee "$VENDOR/VERSIONS.txt"
awk '$1=="yt-dlp"{print $2}' "$VENDOR/VERSIONS.txt" > "$VENDOR/yt-dlp.version"

# Nenhum binário pode depender de bibliotecas do Homebrew
for f in "$BIN"/*; do
  if otool -L "$f" 2>/dev/null | grep -qE '/opt/homebrew|/usr/local'; then
    echo "ERRO: $f depende de bibliotecas externas"; exit 1
  fi
done
du -sh "$BIN"
