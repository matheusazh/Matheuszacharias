# Benchmark dos modelos (28/09/2026, MacBook M5 24 GB, PyTorch 2.14 MPS)

Música: 17 trechos de 7 s do MUSDB18 (teste) com faixas de referência. SDR em dB (quanto maior, melhor).
Velocidade: segundos para processar 4 minutos. RoFormer com fp16 + torch.compile (mesmo SDR do fp32, ~5x mais rápido).

| Modelo | Voz | Instrumental | Bateria | Baixo | Outros | s / 4 min |
|---|---|---|---|---|---|---|
| BS-RoFormer viperx 1297 | **10.16** | **16.10** | | | | 119 |
| BS-RoFormer SW (6 faixas) | 9.70 | 15.65 | **10.60** | 6.53 | **6.14** | 33 |
| MelBand RoFormer becruily | 9.29 | 15.35 | | | | 38 |
| htdemucs | 7.21 | 13.23 | 9.21 | 7.11 | 5.00 | 12.5 |
| htdemucs_ft | 7.33 | 12.31 | 9.17 | **7.39** | 4.78 | 48 |
| htdemucs_6s | 7.55 | 12.71 | 8.96 | 5.70 | 4.57 | 16.6 |
| BS-RoFormer Resurrection | 4.27 | 10.52 | | | | (fp32) 225 |

Escolhas: 2 faixas = viperx; 4/6 faixas = SW; modo rápido = htdemucs (4) e SW (6).

Fala: 3 falas PT-BR (voz do macOS) com música 3 dB abaixo; versão "igreja" com reverb RT60 1,6 s, ruído rosa e hum.
SI-SDR contra a fala seca:

| Cadeia | Fala + música | Igreja (eco + ruído + música) |
|---|---|---|
| mixagem | 3.5 | -1.4 |
| viperx (isolar voz) | 20.8 | 3.4 |
| + DeNoise (Lite/UVR/MelBand) | = | = (a isolação já tira o ruído) |
| + UVR-DeEcho-DeReverb | | 6.5 |
| + MelBand De-Reverb anvuew | | **9.8** |
| + De-Reverb-Echo v2 (Sucial) | | pior (descartado) |

Escolhas: isolar = viperx; ruído = UVR-DeNoise-Lite (18 MB); eco = MelBand De-Reverb anvuew.

## Ajustes de velocidade (mesma qualidade medida)

- fp16 + `torch.compile` no MPS: viperx de 521 s para 107 s por 4 min (SDR 11,16 igual).
  Precisa de `torch/include/c10/metal` no Python embutido (o Inductor compila shaders Metal com esses headers).
  Não precisa das ferramentas do Xcode.
- Sobreposição 2 em vez de 4 (viperx, karaokê): 107 s → 61 s, SDR 11,16 → 11,15.
- Checkpoints RoFormer gravados em float16: metade do tamanho, SDR idêntico (o motor já roda em fp16).

Tempos finais no M5 (música de 4 min): voz + instrumental ~60 s · 4/6 faixas ~40 s · rápido (htdemucs) ~12 s ·
backing vocal +30 s · análise (batidas, acordes, tom, partes) ~10 s · letra (Whisper large-v3-turbo MLX) ~30 s.
