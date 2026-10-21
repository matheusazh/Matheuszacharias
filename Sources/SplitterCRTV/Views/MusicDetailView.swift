import SwiftUI

struct MusicDetailView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            MusicHeader(project: project)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)
            ScrollView(.vertical) {
                TimelineLanes(project: project)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 120)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
        .overlay(alignment: .bottom) {
            MusicTransportBar(project: project)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .inspector(isPresented: $model.showLyrics) {
            LyricsPanel(project: project)
                .inspectorColumnWidth(min: 260, ideal: 310, max: 440)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showLyrics.toggle() } label: {
                    Label("Letra", systemImage: "quote.bubble")
                }
                .help("Letra sincronizada (⌥⌘T)")
                Button { model.exportRequest = project.id } label: {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                }
                .help("Exportar faixas ou mixagem (⌘E)")
            }
        }
        .navigationTitle(project.title)
        .navigationSubtitle(project.subtitle)
    }
}

// MARK: - Cabeçalho

private struct MusicHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let analysis = project.analysis
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(project.title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let key = analysis?.key {
                        InfoChip(symbol: "music.quarternote.3",
                                 text: "Tom " + ChordFormatter.keyName(key, transpose: project.mix.pitch),
                                 help: ChordFormatter.keyLongName(key, transpose: project.mix.pitch)
                                    + (project.mix.pitch != 0 ? " (original: \(ChordFormatter.keyName(key)))" : ""))
                    }
                    if let bpm = analysis?.bpm {
                        let shown = bpm * project.mix.speed
                        InfoChip(symbol: "metronome", text: "\(Int(shown.rounded())) BPM",
                                 help: project.mix.speed != 1 ? "Original: \(Int(bpm.rounded())) BPM" : "Andamento")
                    }
                    if let meter = analysis?.meter, meter > 1 {
                        InfoChip(symbol: "square.grid.3x1.below.line.grid.1x2", text: "\(meter)/4", help: "Compasso")
                    }
                    InfoChip(symbol: "clock", text: Formatters.duration(project.duration), help: "Duração")
                    if analysis == nil {
                        InfoChip(symbol: "exclamationmark.circle", text: "Sem análise", help: "Tom, BPM e acordes não foram detectados.")
                    }
                }
            }
            Spacer()
            if let analysis, !analysis.chords.isEmpty {
                CurrentChordView(project: project, chords: analysis.chords)
            }
        }
    }
}

/// Acorde atual grande e o próximo, com a barra do tempo até a troca.
private struct CurrentChordView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chords: [ChordSegment]
    @AppStorage("simpleChords") private var simple = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.player.isPlaying)) { _ in
            let t = model.scrubTime ?? model.player.displayTime()
            let flats = ChordFormatter.flats(for: project.analysis?.key, transpose: project.mix.pitch)
            let i = chords.lastIndex { $0.start <= t } ?? 0
            let current = chords.indices.contains(i) ? ChordFormatter.display(chords[i].label, transpose: project.mix.pitch, simple: simple, flats: flats) : nil
            let nextIndex = chords[(i + 1)...].firstIndex { ChordFormatter.parse($0.label) != nil && $0.label != chords[i].label }
            let next = nextIndex.flatMap { ChordFormatter.display(chords[$0].label, transpose: project.mix.pitch, simple: simple, flats: flats) }
            let segment = chords.indices.contains(i) ? chords[i] : nil
            let frac = segment.map { max(0, min(1, (t - $0.start) / max(0.01, $0.end - $0.start))) } ?? 0
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(current ?? "–")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .tracking(-0.5)
                        .contentTransition(.numericText())
                        .animation(Motion.quick, value: current)
                    Capsule().fill(.quaternary)
                        .frame(width: 70, height: 3)
                        .overlay(alignment: .leading) { Capsule().fill(Color.accentColor).frame(width: 70 * frac, height: 3) }
                }
                if let next {
                    Text(next)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 150, alignment: .trailing)
            .help("Acorde atual e o próximo")
        }
    }
}

// MARK: - Transporte

private struct MusicTransportBar: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let mix = project.mix
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                RoundIconButton(symbol: "gobackward.5", size: 32, help: "Voltar 5 s (←)") { model.player.skip(-5) }
                RoundIconButton(symbol: model.player.isPlaying ? "pause.fill" : "play.fill", size: 44, prominent: true,
                                tint: Brand.magenta, help: "Tocar/pausar (espaço)") { model.player.togglePlay() }
                RoundIconButton(symbol: "goforward.5", size: 32, help: "Avançar 5 s (→)") { model.player.skip(5) }
            }
            TimeLabel()
            Divider().frame(height: 26)
            // Loop
            Button {
                if mix.loopStart == nil {
                    // sem trecho marcado: repete a parte atual (ou 8 s a partir do cursor)
                    let t = model.player.position()
                    let part = project.analysis?.sections.first { $0.start <= t && t < $0.end }
                    model.updateMix { m in
                        m.loopStart = part?.start ?? t
                        m.loopEnd = part?.end ?? min(project.duration, t + 8)
                        m.loopOn = true
                    }
                } else {
                    model.updateMix { $0.loopOn.toggle() }
                }
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(mix.loopOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(Circle().fill(mix.loopOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.8))))
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .help(mix.loopStart == nil ? "Repetir a parte atual (L)" : "Liga/desliga o loop (L) — arraste na régua para mudar o trecho")
            .accessibilityLabel(mix.loopOn ? "Loop ligado" : "Loop desligado")
            // Metrônomo + contagem
            if project.analysis != nil {
                Menu {
                    Toggle("Metrônomo", isOn: Binding(get: { mix.metronome }, set: { v in model.updateMix { $0.metronome = v } }))
                    Toggle("Contagem antes de tocar", isOn: Binding(get: { mix.countIn }, set: { v in model.updateMix { $0.countIn = v } }))
                    Divider()
                    Text("Volume do click")
                    ForEach([0.4, 0.7, 1.0], id: \.self) { v in
                        Button("\(Int(v * 100))%\(abs(mix.metronomeVolume - v) < 0.01 ? " ✓" : "")") { model.updateMix { $0.metronomeVolume = v } }
                    }
                } label: {
                    Image(systemName: "metronome")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(mix.metronome || mix.countIn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(Circle().fill(mix.metronome || mix.countIn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.8))))
                } primaryAction: {
                    model.updateMix { $0.metronome.toggle() }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Metrônomo (K). Segure para contagem e volume.")
                .accessibilityLabel(mix.metronome ? "Metrônomo ligado" : "Metrônomo desligado")
            }
            Spacer(minLength: 8)
            PitchControl(project: project)
            SpeedControl(project: project)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

struct TimeLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !model.player.isPlaying && model.scrubTime == nil)) { _ in
            let t = model.scrubTime ?? model.player.displayTime()
            HStack(spacing: 3) {
                Text(Formatters.duration(t)).foregroundStyle(.primary)
                Text("/").foregroundStyle(.tertiary)
                Text(Formatters.duration(model.player.duration)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
        .fixedSize()
    }
}

/// Tom em semitons, mostrando o tom resultante.
private struct PitchControl: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let pitch = project.mix.pitch
        HStack(spacing: 4) {
            Button { model.updateMix { $0.pitch = max(-12, $0.pitch - 1) } } label: {
                Image(systemName: "minus").frame(width: 22, height: 22).contentShape(.rect)
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .help("Descer meio tom (⌘↓)")
            VStack(spacing: 0) {
                Text(pitch == 0 ? "Tom" : (pitch > 0 ? "+\(pitch)" : "\(pitch)"))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(pitch)))
                if let key = project.analysis?.key {
                    Text(ChordFormatter.keyName(key, transpose: pitch))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 36)
            .onTapGesture(count: 2) { model.updateMix { $0.pitch = 0 } }
            Button { model.updateMix { $0.pitch = min(12, $0.pitch + 1) } } label: {
                Image(systemName: "plus").frame(width: 22, height: 22).contentShape(.rect)
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .help("Subir meio tom (⌘↑)")
        }
        .font(.system(size: 12, weight: .bold))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(pitch != 0 ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6))))
        .animation(Motion.quick, value: pitch)
        .help("Mudar o tom sem mudar a velocidade. Duplo clique volta ao original.")
    }
}

/// Velocidade 50–150% com ímã em 100%.
private struct SpeedControl: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let speed = project.mix.speed
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { speed }, set: { v in
                let snapped = abs(v - 1) < 0.03 ? 1.0 : (v * 20).rounded() / 20
                if snapped == 1, speed != 1 { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                model.updateMix { $0.speed = snapped }
            }), in: 0.5...1.5)
                .frame(width: 110)
                .controlSize(.small)
            Text("\(Int((speed * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 40, alignment: .leading)
                .onTapGesture(count: 2) { model.updateMix { $0.speed = 1 } }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(speed != 1 ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6))))
        .help("Velocidade sem mudar o tom ([ e ]). Duplo clique no número volta a 100%.")
    }
}
