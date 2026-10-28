# MediaCRTV

App nativo macOS (SwiftUI + Liquid Glass) que junta o **DownloaderCRTV** e o **ConverterCRTV** num programa só:

- **Baixar** — vídeo/áudio do YouTube, Instagram, TikTok, X e qualquer site suportado pelo yt-dlp.
- **Converter** — deixa vídeos prontos para o Adobe Premiere (VP9, AV1, WebM, MKV, HEVC 10-bit → H.264), ProRes 422 ou WAV.

Os dois se conversam: um download concluído tem o botão **Enviar para o Converter** (⟳), e arquivos do Finder
soltos na janela, no ícone do Dock ou via botão direito ▸ **Serviços ▸ Converter p/ Premiere** caem direto na aba Converter.

Atalhos: **⌘1** Baixar · **⌘2** Converter · **⇧⌘V** colar link · **⌘O** adicionar arquivos para converter.

## Compilar no seu Mac

Precisa de um Mac com Apple Silicon (M1 ou mais novo), macOS 26+ e o **Xcode** instalado (abra uma vez e aceite a licença).

```bash
cd MediaCRTV
scripts/fetch-tools.sh          # baixa yt-dlp, deno, ffmpeg e ffprobe (com checksum)
scripts/build-app.sh --install  # compila e instala em /Applications
scripts/make-dmg.sh             # opcional: gera build/MediaCRTV-<versão>.dmg
```

Na primeira abertura, se o macOS bloquear: **Ajustes do Sistema ▸ Privacidade e Segurança ▸ Abrir Mesmo Assim**.

## Estrutura

```
Sources/MediaCRTV/
  App/         janela, abas, menus, serviços do Finder (MediaCRTVApp, RootView)
  Shared/      marca, símbolo e animação de abertura
  Downloader/  yt-dlp: modelos, motor, telas (vindo do DownloaderCRTV)
  Converter/   ffmpeg: análise, presets, fila, tela (vindo do ConverterCRTV)
```

## Licença

MIT. Baseado em DownloaderCRTV e ConverterCRTV de Noah CRTV. O app embute yt-dlp (Unlicense), deno (MIT)
e FFmpeg (GPL v3, build estático de Martin Riedl) — veja `scripts/THIRD-PARTY.txt`.
