import AppKit
import SwiftUI

/// Pistas alinhadas no tempo: régua (loop), partes, acordes, faixas e metrônomo.
/// Todas compartilham o mesmo eixo: x = t / duração × largura da área de conteúdo.
struct TimelineLanes: View {
    @Environment(AppModel.self) private var model
    let project: Project

    static let controlsWidth: CGFloat = 200
    static let gap: CGFloat = 12

    var body: some View {
        let analysis = project.analysis
        VStack(spacing: 8) {
            LaneRow(height: 26) {
                Text("Tempo").laneCaption()
            } content: {
                RulerLane(project: project)
            }
            if let analysis, !analysis.sections.isEmpty {
                LaneRow(height: 30) {
                    Text("Partes").laneCaption()
                } content: {
                    SectionLane(project: project, sections: analysis.sections)
                }
            }
            if let analysis {
                LaneRow(height: 34) {
                    Text("Acordes").laneCaption()
                } content: {
                    ChordLane(project: project, chords: analysis.chords)
                }
            }
            ForEach(project.stems) { stem in
                StemLane(project: project, stem: stem)
            }
            if let analysis, !analysis.beats.isEmpty {
                MetronomeLane(project: project, analysis: analysis)
            }
        }
        .overlay { TimelineOverlay(project: project) }
    }
}

extension Text {
    func laneCaption() -> some View {
        self.font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }
}

/// Linha com a coluna de controles fixa e o conteúdo no eixo do tempo.
struct LaneRow<Controls: View, Content: View>: View {
    var height: CGFloat
    @ViewBuilder let controls: Controls
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: TimelineLanes.gap) {
            controls.frame(width: TimelineLanes.controlsWidth, alignment: .leading)
            content.frame(maxWidth: .infinity)
        }
        .frame(height: height)
    }
}

// MARK: - Sobreposições: região do loop e cursor

private struct TimelineOverlay: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        GeometryReader { geo in
            let x0 = TimelineLanes.controlsWidth + TimelineLanes.gap
            let w = max(1, geo.size.width - x0)
            let duration = max(0.001, model.player.duration)
            ZStack(alignment: .topLeading) {
                if let a = project.mix.loopStart, let b = project.mix.loopEnd, b > a {
                    Rectangle()
                        .fill(Color.accentColor.opacity(project.mix.loopOn ? 0.10 : 0.04))
                        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(project.mix.loopOn ? 0.7 : 0.3)).frame(width: 1) }
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.accentColor.opacity(project.mix.loopOn ? 0.7 : 0.3)).frame(width: 1) }
                        .frame(width: CGFloat((b - a) / duration) * w, height: geo.size.height)
                        .offset(x: x0 + CGFloat(a / duration) * w)
                }
                TimelineView(.animation(minimumInterval: nil, paused: !model.player.isPlaying)) { _ in
                    let t = model.scrubTime ?? model.player.displayTime()
                    Playhead(height: geo.size.height)
                        .offset(x: x0 + CGFloat(t / duration) * w - 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct Playhead: View {
    let height: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Triangle().fill(.primary).frame(width: 10, height: 7).offset(x: -4)
            Rectangle().fill(.primary).frame(width: 2)
        }
        .frame(width: 2, height: height, alignment: .top)
        .shadow(color: .black.opacity(0.2), radius: 1)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Gesto de busca (toque = ir para; arrastar = varrer 1:1)

private struct ScrubModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            model.scrubTime = time(g.location.x, width: geo.size.width)
                        }
                        .onEnded { g in
                            model.player.seek(to: time(g.location.x, width: geo.size.width))
                            model.scrubTime = nil
                        }
                )
        }
    }

    private func time(_ x: CGFloat, width: CGFloat) -> Double {
        Double(max(0, min(1, x / max(1, width)))) * model.player.duration
    }
}

extension View {
    func scrubbable() -> some View { modifier(ScrubModifier()) }
}

// MARK: - Régua (cria e ajusta o loop)

private struct RulerLane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var dragAnchor: Double?
    @State private var handleGrab: (isStart: Bool, offset: Double)?

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let duration = max(0.001, model.player.duration)
            let step = tickStep(duration: duration, width: w)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.35))
                Canvas { ctx, size in
                    var t = 0.0
                    while t <= duration {
                        let x = CGFloat(t / duration) * size.width
                        ctx.fill(Path(CGRect(x: x, y: size.height - 7, width: 1, height: 7)), with: .color(.secondary.opacity(0.6)))
                        ctx.draw(Text(Formatters.duration(t)).font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary), at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                        t += step
                    }
                }
                if let a = project.mix.loopStart, let b = project.mix.loopEnd, b > a {
                    LoopHandle(isStart: true, active: project.mix.loopOn)
                        .offset(x: CGFloat(a / duration) * w - 6)
                    LoopHandle(isStart: false, active: project.mix.loopOn)
                        .offset(x: CGFloat(b / duration) * w - 6)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        let t = Double(max(0, min(1, g.location.x / w))) * duration
                        if dragAnchor == nil, handleGrab == nil {
                            let start = Double(g.startLocation.x / w) * duration
                            if let a = project.mix.loopStart, let b = project.mix.loopEnd, b > a {
                                let tol = Double(8 / w) * duration
                                if abs(start - a) < tol { handleGrab = (true, a - start) }
                                else if abs(start - b) < tol { handleGrab = (false, b - start) }
                            }
                            if handleGrab == nil { dragAnchor = start }
                        }
                        if let grab = handleGrab {
                            let v = max(0, min(duration, t + grab.offset))
                            model.updateMix { m in
                                if grab.isStart { m.loopStart = min(v, (m.loopEnd ?? duration) - 0.25) }
                                else { m.loopEnd = max(v, (m.loopStart ?? 0) + 0.25) }
                            }
                        } else if let anchor = dragAnchor {
                            model.updateMix { m in
                                m.loopStart = min(anchor, t)
                                m.loopEnd = max(anchor, t)
                                m.loopOn = true
                            }
                        }
                    }
                    .onEnded { _ in
                        dragAnchor = nil
                        handleGrab = nil
                        snapLoopToBeats()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                model.updateMix { m in m.loopStart = nil; m.loopEnd = nil; m.loopOn = false }
            })
            .help("Arraste para marcar um trecho e repetir. Duplo clique apaga o loop.")
        }
    }

    /// Encaixa as pontas do loop na batida mais próxima (se estiver perto), para repetir redondo.
    private func snapLoopToBeats() {
        guard let beats = project.analysis?.beats, !beats.isEmpty else { return }
        func snap(_ t: Double?) -> Double? {
            guard let t else { return nil }
            let nearest = beats.min { abs($0 - t) < abs($1 - t) } ?? t
            return abs(nearest - t) < 0.12 ? nearest : t
        }
        model.updateMix { m in
            m.loopStart = snap(m.loopStart)
            m.loopEnd = snap(m.loopEnd)
        }
    }

    private func tickStep(duration: Double, width: CGFloat) -> Double {
        let target = duration / Double(max(1, width / 70))
        for s in [5.0, 10, 15, 30, 60, 120, 300, 600] where s >= target { return s }
        return 900
    }
}

private struct LoopHandle: View {
    let isStart: Bool
    let active: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.accentColor.opacity(active ? 1 : 0.45))
            .frame(width: 12, height: 22)
            .overlay(Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
            .offset(y: 2)
    }
}

// MARK: - Partes da música

private struct SectionLane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let sections: [SongSection]
    @State private var renaming: SongSection?
    @State private var newName = ""

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let duration = max(0.001, model.player.duration)
            ZStack(alignment: .topLeading) {
                ForEach(Array(sections.enumerated()), id: \.offset) { i, s in
                    let x = CGFloat(s.start / duration) * w
                    let width = max(2, CGFloat((s.end - s.start) / duration) * w - 2)
                    let looped = project.mix.loopOn && project.mix.loopStart == s.start && project.mix.loopEnd == s.end
                    Button {
                        model.updateMix { m in
                            if looped { m.loopOn = false } else { m.loopStart = s.start; m.loopEnd = s.end; m.loopOn = true }
                        }
                        if !looped { model.player.seek(to: s.start) }
                    } label: {
                        Text(s.label)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(looped ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 6)
                            .frame(width: width, height: geo.size.height, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(looped ? AnyShapeStyle(color(s.label)) : AnyShapeStyle(color(s.label).opacity(0.22))))
                            .contentShape(.rect)
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                    .help("Clique para repetir \"\(s.label)\"")
                    .contextMenu {
                        Button(looped ? "Parar de repetir" : "Repetir esta parte") {
                            model.updateMix { m in
                                if looped { m.loopOn = false } else { m.loopStart = s.start; m.loopEnd = s.end; m.loopOn = true }
                            }
                        }
                        Button("Renomear…") { newName = s.label; renaming = s }
                        Button("Dividir no cursor") { split(index: i) }
                            .disabled(!(s.start + 1 < model.player.displayTime() && model.player.displayTime() < s.end - 1))
                        Button("Juntar com a próxima") { mergeNext(index: i) }
                            .disabled(i + 1 >= sections.count)
                        Menu("Chamar de") {
                            ForEach(["Intro", "Verso", "Pré-refrão", "Refrão", "Ponte", "Instrumental", "Solo", "Final"], id: \.self) { name in
                                Button(name) { rename(index: i, to: name) }
                            }
                        }
                    }
                    .offset(x: x)
                }
                // divisas entre partes: arraste para ajustar (encaixa no tempo forte)
                ForEach(1..<max(1, sections.count), id: \.self) { i in
                    BoundaryHandle(height: geo.size.height)
                        .offset(x: CGFloat(sections[i].start / duration) * w - 5)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { g in
                                    if dragOrigin == nil { dragOrigin = (i, sections[i].start) }
                                    guard let origin = dragOrigin, origin.index == i else { return }
                                    let raw = origin.time + Double(g.translation.width / w) * duration
                                    let lo = sections[i - 1].start + 1, hi = sections[i].end - 1
                                    let t = snapToBar(min(hi, max(lo, raw)))
                                    model.editSections(project.id, save: false) { list in
                                        list[i - 1].end = t
                                        list[i].start = t
                                    }
                                }
                                .onEnded { _ in
                                    dragOrigin = nil
                                    model.editSections(project.id, save: true) { _ in }
                                }
                        )
                }
            }
        }
        .alert("Renomear parte", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("OK") {
                if let r = renaming, let i = sections.firstIndex(of: r) { rename(index: i, to: newName) }
                renaming = nil
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
    }

    @State private var dragOrigin: (index: Int, time: Double)?

    /// Encaixa no tempo forte mais próximo (até 0,3 s), com toque no trackpad ao encaixar.
    private func snapToBar(_ t: Double) -> Double {
        guard let downs = project.analysis?.downbeats, !downs.isEmpty else { return t }
        let nearest = downs.min { abs($0 - t) < abs($1 - t) } ?? t
        guard abs(nearest - t) < 0.3 else { return t }
        if let i = sections.firstIndex(where: { abs($0.start - nearest) < 0.001 }), i > 0 { return nearest }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return nearest
    }

    private func split(index: Int) {
        let t = snapToBar(model.player.displayTime())
        model.editSections(project.id, save: true) { list in
            guard index < list.count, list[index].start < t, t < list[index].end else { return }
            var second = list[index]
            second.id = UUID()
            second.start = t
            list[index].end = t
            list.insert(second, at: index + 1)
        }
    }

    private func mergeNext(index: Int) {
        model.editSections(project.id, save: true) { list in
            guard index + 1 < list.count else { return }
            list[index].end = list[index + 1].end
            list.remove(at: index + 1)
        }
    }

    private func rename(index: Int, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        model.updateProject(project.id) { p in
            guard p.analysis != nil, index < p.analysis!.sections.count else { return }
            p.analysis!.sections[index].label = clean
        }
    }

    private func color(_ label: String) -> Color {
        switch label {
        case "Refrão": Brand.magenta
        case "Verso": Brand.violet
        case "Pré-refrão": Color(red: 0.95, green: 0.45, blue: 0.35)
        case "Ponte": Brand.teal
        case "Intro", "Final": Color.gray
        case "Instrumental", "Solo": Color(red: 0.25, green: 0.6, blue: 0.95)
        default: Color.accentColor
        }
    }
}

/// Alça invisível na divisa entre duas partes; mostra o cursor de redimensionar.
private struct BoundaryHandle: View {
    let height: CGFloat
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(hovering ? 0.35 : 0.001))
            .frame(width: hovering ? 3 : 10, height: height)
            .frame(width: 10)
            .contentShape(.rect)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("Arraste para ajustar onde a parte começa")
    }
}

// MARK: - Acordes

private struct ChordLane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chords: [ChordSegment]
    @AppStorage("simpleChords") private var simple = false

    var body: some View {
        let flats = ChordFormatter.flats(for: project.analysis?.key, transpose: project.mix.pitch)
        let duration = max(0.001, model.player.duration)
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.25))
            if chords.allSatisfy({ ChordFormatter.parse($0.label) == nil }) {
                Text("Sem acordes claros nesta música")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Canvas { ctx, size in
                    // nome só onde cabe sem encostar no anterior; acorde repetido não repete o nome
                    var labelEnd: CGFloat = -100
                    var lastName = ""
                    for c in chords {
                        guard let name = ChordFormatter.display(c.label, transpose: project.mix.pitch, simple: simple, flats: flats) else { continue }
                        let x = CGFloat(c.start / duration) * size.width
                        ctx.fill(Path(CGRect(x: x, y: 6, width: 1, height: size.height - 12)), with: .color(.secondary.opacity(0.3)))
                        guard name != lastName else { continue }
                        let text = ctx.resolve(Text(name).font(.system(size: 12, weight: .semibold)))
                        let w = text.measure(in: CGSize(width: 200, height: size.height)).width
                        if x + 4 > labelEnd + 6 {
                            ctx.draw(text, at: CGPoint(x: x + 4, y: size.height / 2), anchor: .leading)
                            labelEnd = x + 4 + w
                            lastName = name
                        }
                    }
                }
            }
        }
        .scrubbable()
    }
}

// MARK: - Faixa

private struct StemLane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let stem: StemInfo

    var body: some View {
        let mix = project.mix
        let muted = mix.muted.contains(stem.id)
        let soloed = mix.soloed.contains(stem.id)
        let silencedBySolo = !mix.soloed.isEmpty && !soloed
        let color = StemStyle.color(stem.id)
        LaneRow(height: 60) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: StemStyle.symbol(stem.id))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 16)
                    Text(stem.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ToggleChip(title: "M", on: muted, tint: .orange, help: "Mudo") {
                        model.updateMix { m in if muted { m.muted.remove(stem.id) } else { m.muted.insert(stem.id) } }
                    }
                    ToggleChip(title: "S", on: soloed, tint: .yellow.opacity(0.9), help: "Solo (só esta faixa)") {
                        model.updateMix { m in if soloed { m.soloed.remove(stem.id) } else { m.soloed.insert(stem.id) } }
                    }
                }
                Fader(value: Binding(get: { mix.volume(stem.id) }, set: { v in model.updateMix { $0.volumes[stem.id] = v } }),
                      tint: color, dimmed: muted || silencedBySolo, help: "Volume de \(stem.label)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
        } content: {
            WaveformView(peaks: PeaksCache.peaks(project, stem.id, library: model.library),
                         color: color, dimmed: muted || silencedBySolo || stem.silent,
                         level: muted || silencedBySolo ? 0 : mix.volume(stem.id))
                .overlay {
                    if stem.silent {
                        Text("Sem som nesta faixa").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.06)))
                .scrubbable()
        }
    }
}

/// Forma de onda espelhada em barras; a altura acompanha o volume da faixa.
struct WaveformView: View {
    let peaks: [Float]
    let color: Color
    var dimmed = false
    var level: Double = 1

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let barW: CGFloat = 2, gap: CGFloat = 1
            let count = Int(size.width / (barW + gap))
            let values = Waveform.downsample(peaks, count: count)
            let mid = size.height / 2
            let scale = CGFloat(min(1.25, max(0.08, level)))
            var path = Path()
            for (i, v) in values.enumerated() {
                let h = max(1, CGFloat(sqrt(Double(v))) * (size.height - 6) * scale * 0.5)
                path.addRoundedRect(in: CGRect(x: CGFloat(i) * (barW + gap), y: mid - h, width: barW, height: h * 2),
                                    cornerSize: CGSize(width: 1, height: 1))
            }
            ctx.fill(path, with: .color(dimmed ? Color.secondary.opacity(0.35) : color.opacity(0.9)))
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}

// MARK: - Metrônomo

private struct MetronomeLane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let analysis: Analysis

    var body: some View {
        let mix = project.mix
        LaneRow(height: 40) {
            HStack(spacing: 8) {
                Image(systemName: "metronome")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mix.metronome ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text("Metrônomo").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { mix.metronome }, set: { v in model.updateMix { $0.metronome = v } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Click que segue a batida da música (K)")
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
        } content: {
            Canvas { ctx, size in
                let duration = max(0.001, model.player.duration)
                let downs = Set(analysis.downbeats.map { Int(($0 * 50).rounded()) })
                for b in analysis.beats {
                    let x = CGFloat(b / duration) * size.width
                    let isDown = downs.contains(Int((b * 50).rounded()))
                    let h: CGFloat = isDown ? size.height - 10 : (size.height - 10) * 0.45
                    ctx.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: isDown ? 1.5 : 1, height: h)),
                             with: .color(mix.metronome ? Color.accentColor.opacity(isDown ? 0.9 : 0.5) : Color.secondary.opacity(isDown ? 0.5 : 0.25)))
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.2)))
            .scrubbable()
        }
    }
}
