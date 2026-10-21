# SplitterCRTV

App nativo macOS (SwiftUI + Liquid Glass) para separar voz e instrumentos de músicas (estilo Moises)
e limpar a voz de falas, pregações e vídeos (estilo Adobe Podcast). A IA roda toda no Mac, sem internet.

## Baixar (jeito fácil)

Baixe o `.dmg` em **[Releases](https://github.com/noahcrtv1/SplitterCRTV/releases/latest)**, abra e arraste o SplitterCRTV para Aplicativos.
Na primeira abertura, se o macOS bloquear: **Ajustes do Sistema ▸ Privacidade e Segurança ▸ Abrir Mesmo Assim**.

Quer compilar você mesmo? Siga a seção abaixo.

## Compilar no seu Mac

Precisa de um Mac com Apple Silicon (M1 ou mais novo) e macOS 26 ou mais novo.

1. Instale o **Xcode** pela App Store (grátis), abra uma vez e aceite a licença.
   Ele traz o compilador Swift e a ferramenta que gera o ícone.
   Também instale o **uv** (gerenciador de Python): `curl -LsSf https://astral.sh/uv/install.sh | sh`
   e feche/abra o Terminal.
   Reserve ~15 GB livres e uma boa internet: os modelos de IA são grandes.
2. Abra o app **Terminal** e rode:

```bash
git clone https://github.com/noahcrtv1/SplitterCRTV.git
cd SplitterCRTV
scripts/fetch-tools.sh          # yt-dlp, deno e ffmpeg
scripts/build-engine.sh         # Python embutido + dependências do motor
scripts/fetch-models.sh         # modelos de IA (vários GB, demora)
scripts/build-app.sh --install  # compila e instala em /Applications
```

O app aparece em **Aplicativos** como SplitterCRTV. 16 GB de memória recomendados.

3. Na primeira vez que abrir, o macOS pode bloquear (o app não é assinado pela Apple).
   Vá em **Ajustes do Sistema ▸ Privacidade e Segurança** e clique em **Abrir Mesmo Assim**.

Para atualizar depois: `cd SplitterCRTV && git pull` e rode o último comando de novo.

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
