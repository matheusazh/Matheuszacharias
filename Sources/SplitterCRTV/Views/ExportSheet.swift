import AppKit
import AVFoundation
import SwiftUI

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project

    enum MusicMode: Hashable { case stems, mix }
    enum SpeechMode: Hashable { case audio, video }

    @State private var musicMode: MusicMode = .stems
    @State private var speechMode: SpeechMode = .audio
    @State private var selected: Set<String> = []
    @State private var includeClick = false
    @State private var applyPitchSpeed = true
    @State private var exportBackground = false
    @AppStorage("exportFormat") private var format: ExportFormat = .wav
    @State private var progress: Double?
    @State private var status = ""
    @State private var result: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var changedPitchSpeed: Bool { project.mix.pitch != 0 || abs(project.mix.speed - 1) > 0.001 }
    private var videoURL: URL? { model.library.videoURL(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Exportar \"\(project.title)\"")
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
            if project.kind == .music { musicOptions } else { speechOptions }
            if !(project.kind == .speech && speechMode == .video) {
                VStack(alignment: .leading, spacing: 6) {
                    SlidingSegments(items: ExportFormat.allCases, selection: $format) { $0.title }
                        .frame(width: 320)
                    Text(format.caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            footer
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            selected = Set(project.stems.filter { !$0.silent }.map(\.id))
            includeClick = project.mix.metronome
            if videoURL != nil { speechMode = .video }
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: Música

    private var musicOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            SlidingSegments(items: [MusicMode.stems, .mix], selection: $musicMode) { $0 == .stems ? "Faixas separadas" : "Mixagem atual" }
                .frame(width: 320)
            if musicMode == .stems {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(project.stems) { stem in
                        Toggle(isOn: Binding(get: { selected.contains(stem.id) },
                                             set: { on in if on { selected.insert(stem.id) } else { selected.remove(stem.id) } })) {
                            HStack(spacing: 8) {
                                Circle().fill(StemStyle.color(stem.id)).frame(width: 8, height: 8)
                                Text(stem.label)
                                if stem.silent { Text("(sem som)").foregroundStyle(.tertiary) }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    if project.analysis?.beats.isEmpty == false {
                        Toggle("Click do metrônomo (faixa separada)", isOn: $includeClick).toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 4)
            } else {
                Text("Exporta o que você ouve agora: volumes, mudo e solo do mixer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if project.analysis?.beats.isEmpty == false {
                    Toggle("Incluir o metrônomo na mixagem", isOn: $includeClick).toggleStyle(.checkbox)
                }
            }
            if changedPitchSpeed {
                Toggle(isOn: $applyPitchSpeed) {
                    Text("Aplicar tom \(project.mix.pitch > 0 ? "+" : "")\(project.mix.pitch) e velocidade \(Int((project.mix.speed * 100).rounded()))%")
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: Fala

    private var speechOptions: some View {
        let s = project.speech
        return VStack(alignment: .leading, spacing: 14) {
            if project.hasVideo {
                SlidingSegments(items: [SpeechMode.video, .audio], selection: $speechMode) { $0 == .video ? "Vídeo com áudio novo" : "Só o áudio" }
                    .frame(width: 320)
                    .disabled(videoURL == nil)
                if videoURL == nil {
                    Text("O vídeo original não foi encontrado (foi movido ou apagado). Exporte só o áudio.")
                        .font(.caption).foregroundStyle(.orange)
                } else if speechMode == .video {
                    Text("A imagem é copiada sem recodificar: sai na mesma qualidade e rápido.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Limpeza \(Int(s.intensity * 100))% · trilha de fundo \(Int(s.background * 100))%", systemImage: "slider.horizontal.3")
                Label("Volume final: \(s.loudness.title)", systemImage: "speaker.wave.2")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if speechMode == .audio {
                Toggle("Exportar também a trilha de fundo separada", isOn: $exportBackground).toggleStyle(.checkbox)
            }
        }
    }

    // MARK: Rodapé

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress).frame(maxWidth: .infinity)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                if let result {
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                }
                Spacer()
                Button(result == nil ? "Cancelar" : "Fechar") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if result == nil {
                    Button("Exportar…") { start() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .disabled(progress != nil || (project.kind == .music && musicMode == .stems && selected.isEmpty && !includeClick))
                }
            }
            .controlSize(.large)
        }
    }

    // MARK: Execução

    private func start() {
        error = nil
        let base = Exporter.safeName(project.title)
        switch (project.kind, musicMode, speechMode) {
        case (.music, .stems, _):
            guard let folder = chooseFolder() else { return }
            run { try await exportStems(to: folder, base: base) }
        case (.music, .mix, _):
            let suffix = changedPitchSpeed && applyPitchSpeed ? " (\(project.mix.pitch > 0 ? "+" : "")\(project.mix.pitch) \(Int(project.mix.speed * 100))%)" : ""
            guard let url = chooseFile(name: "\(base) mix\(suffix).\(format.ext)") else { return }
            run { try await exportMix(to: url) }
        case (.speech, _, .video):
            guard let video = videoURL,
                  let url = chooseFile(name: "\(base) (áudio limpo).\(Exporter.videoExtension(for: video))") else { return }
            run { try await exportSpeech(to: url, video: video) }
        case (.speech, _, .audio):
            guard let url = chooseFile(name: "\(base) (voz limpa).\(format.ext)") else { return }
            run { try await exportSpeech(to: url, video: nil) }
        }
    }

    private func run(_ work: @escaping () async throws -> URL) {
        progress = 0
        status = "Preparando"
        task = Task {
            do {
                let url = try await work()
                progress = nil
                result = url
            } catch is CancellationError {
                progress = nil
            } catch {
                progress = nil
                self.error = error.localizedDescription
            }
        }
    }

    private var tempDir: URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "SplitterCRTV-export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func exportStems(to folder: URL, base: String) async throws -> URL {
        let stems = project.stems.filter { selected.contains($0.id) }
        let pitchSpeed = changedPitchSpeed && applyPitchSpeed
        let tmp = tempDir
        defer { try? FileManager.default.removeItem(at: tmp) }
        // se alguma faixa passa de 0 dBFS, todas descem juntas: as proporções continuam certas
        let headroom = max(1, stems.map(\.gain).max() ?? 1)
        var items: [(label: String, url: URL, gain: Double, isClick: Bool)] = stems.map {
            ($0.label, model.library.stemURL($0, in: project), $0.gain, false)
        }
        if includeClick, let click = clickURL() { items.append(("Metrônomo", click, 1, true)) }
        var last = folder
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            status = item.label
            let out = uniqueURL(folder.appending(path: "\(base) - \(item.label).\(format.ext)"))
            let step = 1 / Double(items.count)
            if pitchSpeed {
                let rendered = tmp.appending(path: "\(i).caf")
                let p = project
                try await Task.detached {
                    try Exporter.render([.init(url: item.url, gain: item.gain / (item.isClick ? 1 : headroom), volume: 1, isClick: item.isClick)],
                                        pitch: item.isClick ? 0 : p.mix.pitch, rate: p.mix.speed, to: rendered) { f in
                        Task { @MainActor in progress = (Double(i) + f * 0.8) * step }
                    }
                }.value
                try await Exporter.encode(rendered, to: out, format: format)
            } else {
                try await Exporter.encode(item.url, to: out, format: format, gain: item.isClick ? 1 : item.gain / headroom)
            }
            progress = Double(i + 1) * step
            last = out
        }
        return items.count == 1 ? last : folder
    }

    private func exportMix(to url: URL) async throws -> URL {
        let m = project.mix
        let anySolo = !m.soloed.isEmpty
        var inputs: [Exporter.Input] = project.stems.compactMap { s in
            if m.muted.contains(s.id) || (anySolo && !m.soloed.contains(s.id)) { return nil }
            return .init(url: model.library.stemURL(s, in: project), gain: s.gain, volume: Float(m.volume(s.id)))
        }
        if includeClick, let click = clickURL() { inputs.append(.init(url: click, gain: 1, volume: Float(m.metronomeVolume), isClick: true)) }
        guard !inputs.isEmpty else { throw Exporter.Failure.render("todas as faixas estão mudas") }
        let pitchSpeed = changedPitchSpeed && applyPitchSpeed
        let tmp = tempDir
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rendered = tmp.appending(path: "mix.caf")
        status = "Mixando"
        let pitch = pitchSpeed ? m.pitch : 0, rate = pitchSpeed ? m.speed : 1
        try await Task.detached {
            try Exporter.render(inputs, pitch: pitch, rate: rate, to: rendered) { f in
                Task { @MainActor in progress = f * 0.85 }
            }
        }.value
        status = "Convertendo"
        try await Exporter.encode(rendered, to: url, format: format, limit: true)
        progress = 1
        return url
    }

    private func exportSpeech(to url: URL, video: URL?) async throws -> URL {
        let s = project.speech
        func stem(_ id: String) -> StemInfo? { project.stems.first { $0.id == id } }
        var inputs: [Exporter.Input] = []
        if let raw = stem("voice_raw"), s.intensity < 0.999 {
            inputs.append(.init(url: model.library.stemURL(raw, in: project), gain: raw.gain, volume: Float(1 - s.intensity)))
        }
        if let clean = stem("voice"), s.intensity > 0.001 {
            inputs.append(.init(url: model.library.stemURL(clean, in: project), gain: clean.gain, volume: Float(s.intensity)))
        }
        if let bg = stem("background"), s.background > 0.001 {
            inputs.append(.init(url: model.library.stemURL(bg, in: project), gain: bg.gain, volume: Float(s.background)))
        }
        let tmp = tempDir
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rendered = tmp.appending(path: "voz.caf")
        status = "Mixando"
        try await Task.detached {
            try Exporter.render(inputs, pitch: 0, rate: 1, to: rendered) { f in
                Task { @MainActor in progress = f * 0.5 }
            }
        }.value
        status = s.loudness.lufs != nil ? "Nivelando volume" : "Convertendo"
        if let video {
            let audio = tmp.appending(path: "voz.wav")
            try await Exporter.encode(rendered, to: audio, format: .wav, limit: true, loudness: s.loudness.lufs)
            progress = 0.8
            status = "Montando o vídeo"
            try await Exporter.remux(video: video, audio: audio, to: url)
        } else {
            try await Exporter.encode(rendered, to: url, format: format, limit: true, loudness: s.loudness.lufs)
            if exportBackground, let bg = stem("background") {
                status = "Trilha de fundo"
                let out = uniqueURL(url.deletingLastPathComponent()
                    .appending(path: "\(Exporter.safeName(project.title)) (trilha de fundo).\(format.ext)"))
                try await Exporter.encode(model.library.stemURL(bg, in: project), to: out, format: format, gain: bg.gain, limit: true)
            }
        }
        progress = 1
        return url
    }

    private func clickURL() -> URL? {
        guard let analysis = project.analysis, let first = project.stems.first,
              let file = try? AVAudioFile(forReading: model.library.stemURL(first, in: project)) else { return nil }
        return ClickTrack.file(for: analysis, frames: AVAudioFrameCount(file.length),
                               cacheDir: model.library.folder(for: project.id).appending(path: "cache"))
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Exportar aqui"
        panel.message = "Escolha a pasta para as faixas"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseFile(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appending(path: "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }
}
