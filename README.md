# SplitterCRTV

App nativo macOS (SwiftUI + Liquid Glass) para separar voz e instrumentos de músicas (estilo Moises)
e limpar a voz de falas, pregações e vídeos (estilo Adobe Podcast). A IA roda toda no Mac, sem internet.

## Requisitos
- macOS 26+ (testado no 27.2), Apple Silicon. 16 GB de memória recomendados.
- Para compilar: Xcode 27 (actool para o ícone do Icon Composer), `uv` e Homebrew opcionais.

## Build
```bash
scripts/fetch-tools.sh     # yt-dlp, deno e ffmpeg estáticos em vendor/bin (com checksum)
scripts/build-engine.sh    # Python 3.12 relocável + dependências em vendor/python
scripts/fetch-models.sh    # modelos em vendor/models (RoFormer em float16)
scripts/build-app.sh       # build/SplitterCRTV.app completo (use --dev para testar a interface sem embutir o motor)
scripts/make-dmg.sh        # build/SplitterCRTV-<versão>.dmg (app completo em build/full, LZFSE, ~1,6 GB — cabe no WhatsApp)
```
Com `--dev`, o app usa `engine/.venv` do código-fonte (`cd engine && uv sync`). Para apontar para uma pasta
de modelos já baixados: `defaults write com.lipenoe.splittercrtv DevModelsPath <pasta>`.

Assinatura ad-hoc: em outro Mac, "Abrir Mesmo Assim" em Ajustes ▸ Privacidade e Segurança (explicado no
`LEIA-ME.txt` do DMG). Ao abrir, se o Python embutido ainda estiver em quarentena, o app tira a quarentena de
`Contents/Resources/{bin,python}` antes de subir o motor — sem isso o macOS mata o processo (código 137).

## Como funciona
- **Swift** (`Sources/SplitterCRTV`): biblioteca, fila, player de faixas (AVAudioEngine com tom/velocidade,
  loop sem emenda, metrônomo e contagem), telas Música e Fala, exportação (renderização offline + ffmpeg).
- **Motor** (`engine/splitter_engine`): processo Python falando JSON por linha no stdin/stdout.
  - `separate_music`: 2 faixas = BS-RoFormer viperx; 4/6 = BS-RoFormer SW; rápido = htdemucs; backing = RoFormer karaokê.
  - `clean_speech`: isola a voz (viperx) → UVR-DeNoise-Lite → MelBand De-Reverb (anvuew); mede loudness.
  - `analyze`: Beat This! (batidas/compasso/BPM), lv-chordia (acordes), tonalidade (cromagrama + acordes),
    partes da música (auto-similaridade por compasso + nomes por heurística).
  - `transcribe`: Whisper large-v3-turbo em MLX (baixado sob demanda, ~1,5 GB), com marcação por palavra.
  - Cancelar = o app encerra o processo; o próximo pedido sobe outro.
- Velocidade e escolhas de modelo: `engine/BENCHMARK.md`.

## Pastas
- Biblioteca: `~/Music/SplitterCRTV/Biblioteca/<id>/` (project.json, mix.flac, stems/*.flac, peaks/, cache/)
- Modelos baixados e caches: `~/Library/Application Support/SplitterCRTV/`
- Log do motor: `~/Library/Logs/SplitterCRTV/engine.log`

## Atalhos
espaço tocar/pausar · ← → 5 s (⇧ = 1 s) · I/O início/fim do loop · L loop · K metrônomo ·
[ ] velocidade · ⌘↑ ⌘↓ tom · B antes/depois (fala) · ⌥⌘T letra · ⌘E exportar · ⇧⌘V colar link
