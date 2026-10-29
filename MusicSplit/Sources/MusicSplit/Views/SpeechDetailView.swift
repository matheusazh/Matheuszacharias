import SwiftUI

/// Editor de fala: antes/depois, intensidade da limpeza, trilha de fundo e nivelamento.
struct SpeechDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: Project

    var body: some View {
        let s = project.speech
        VStack(spacing: 18) {
            header
            ComparisonWaveform(project: project)
                .frame(height: 190)
            SlidingSegments(items: [true, false], selection: Binding(
                get: { s.compareOriginal },
                set: { v in model.updateSpeech { $0.compareOriginal = v } })) { original in
                    original ? "Antes" : "Depois"
                }
                .frame(width: 260)
                .help("Compare o original com o resultado (B)")
            controls
                .frame(maxWidth: 640)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 100)
        .overlay(alignment: .bottom) {
            SpeechTransport()
                .padding(.bottom, 14)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.exportRequest = project.id } label: {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                }
                .help(project.hasVideo ? "Exportar áudio ou o vídeo com o áudio novo (⌘E)" : "Exportar o áudio limpo (⌘E)")
            }
        }
        .navigationTitle(project.title)
        .navigationSubtitle(project.subtitle)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text(project.title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    InfoChip(symbol: "clock", text: Formatters.duration(project.duration))
                    if project.hasVideo {
                        InfoChip(symbol: "film", text: model.library.videoURL(for: project) != nil ? "Vídeo" : "Vídeo não encontrado",
                                 help: "O vídeo original volta com o áudio novo ao exportar")
                    }
                    let opts = project.speechOptions ?? SpeechOptions()
                    InfoChip(symbol: "checkmark", text: "Sem música")
                    if opts.denoise { InfoChip(symbol: "checkmark", text: "Sem ruído") }
                    if opts.dereverb { InfoChip(symbol: "checkmark", text: "Sem eco") }
                }
            }
            Spacer()
        }
    }

    private var controls: some View {
        let s = project.speech
        return VStack(alignment: .leading, spacing: 16) {
            SliderRow(title: "Limpeza", value: s.intensity, caption: s.intensity >= 0.99 ? "Máxima" : "\(Int(s.intensity * 100))%",
                      help: "Quanto do ruído e do eco sai. 0% = só a voz isolada, sem limpeza extra.") { v in
                model.updateSpeech { $0.intensity = v }
            }
            SliderRow(title: "Trilha de fundo", value: s.background, caption: s.background < 0.01 ? "Removida" : "\(Int(s.background * 100))%",
                      help: "Devolve parte da música/ambiente original por baixo da voz.") { v in
                model.updateSpeech { $0.background = v }
            }
            HStack(spacing: 16) {
                Text("Volume final")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
                SlidingSegments(items: LoudnessTarget.allCases, selection: Binding(
                    get: { s.loudness }, set: { v in model.updateSpeech { $0.loudness = v } })) { $0.short }
                    .frame(width: 330)
                    .help("Nivelamento pelo padrão de loudness: -16 LUFS para podcast, -14 LUFS para redes sociais.")
                Spacer()
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

private struct SliderRow: View {
    let title: String
    let value: Double
    let caption: String
    let help: String
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
            Text(caption)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 70, alignment: .leading)
                .contentTransition(.numericText())
        }
        .help(help)
    }
}

/// Original (cinza) atrás, resultado (turquesa) na frente; toque/arraste para ir a um ponto.
private struct ComparisonWaveform: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let original = PeaksCache.peaks(project, "mix", library: model.library)
        let voice = PeaksCache.peaks(project, "voice", library: model.library)
        let compare = project.speech.compareOriginal
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary.opacity(0.3))
            WaveformView(peaks: original, color: .secondary, dimmed: !compare)
                .opacity(compare ? 0.9 : 0.35)
            WaveformView(peaks: voice, color: Brand.teal)
                .opacity(compare ? 0.15 : 1)
                .animation(.easeOut(duration: 0.2), value: compare)
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: nil, paused: !model.player.isPlaying)) { _ in
                    let t = model.scrubTime ?? model.player.displayTime()
                    Rectangle().fill(.primary)
                        .frame(width: 2)
                        .offset(x: CGFloat(t / max(0.001, model.player.duration)) * geo.size.width - 1)
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.vertical, 2)
        .scrubbable()
    }
}

private struct SpeechTransport: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            RoundIconButton(symbol: "gobackward.5", size: 32, help: "Voltar 5 s (←)") { model.player.skip(-5) }
            RoundIconButton(symbol: model.player.isPlaying ? "pause.fill" : "play.fill", size: 44, prominent: true,
                            tint: Brand.teal, help: "Tocar/pausar (espaço)") { model.player.togglePlay() }
            RoundIconButton(symbol: "goforward.5", size: 32, help: "Avançar 5 s (→)") { model.player.skip(5) }
            TimeLabel().padding(.leading, 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}
