import Foundation
import Observation

struct SeparationResult: Decodable {
    var stems: [StemInfo]
    var frames: Int
    var sampleRate: Int
}

struct SpeechResult: Decodable {
    var stems: [StemInfo]
    var frames: Int
    var sampleRate: Int
    var loudness: [String: Double?]
}

struct LyricsResult: Decodable {
    var lines: [LyricLine]
}

/// Um arquivo ou link esperando/processando. O id vira o id do projeto.
@MainActor
@Observable
final class Job: Identifiable {
    enum Source: Equatable {
        case file(URL)
        case link(String)
    }

    enum Status: Equatable {
        case waiting, running, done, failed(String), cancelled
    }

    let id = UUID()
    let source: Source
    var kind: ProjectKind
    var separation: SeparationOptions
    var speech: SpeechOptions
    var title: String
    var status: Status = .waiting
    var progress: Double = 0
    var stage = "Na fila"
    var startedAt: Date?
    fileprivate var task: Task<Void, Never>?

    init(source: Source, kind: ProjectKind, separation: SeparationOptions, speech: SpeechOptions) {
        self.source = source
        self.kind = kind
        self.separation = separation
        self.speech = speech
        switch source {
        case .file(let url): title = url.deletingPathExtension().lastPathComponent
        case .link(let link): title = URL(string: link)?.host(percentEncoded: false) ?? link
        }
    }

    var isActive: Bool { status == .waiting || status == .running }

    /// Estimativa simples do tempo restante a partir do ritmo até aqui.
    var remaining: TimeInterval? {
        guard status == .running, let startedAt, progress > 0.08 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        return max(0, elapsed / progress - elapsed)
    }
}

@MainActor
@Observable
final class JobQueue {
    private(set) var jobs: [Job] = []
    let engine: EngineClient
    let library: LibraryStore
    var onFinished: ((Project) -> Void)?
    /// Chamado sempre que a fila muda de estado (selo do Dock).
    var onChange: (() -> Void)?

    init(engine: EngineClient, library: LibraryStore) {
        self.engine = engine
        self.library = library
    }

    var activeCount: Int { jobs.filter(\.isActive).count }
    var running: Job? { jobs.first { $0.status == .running } }

    func enqueue(_ job: Job) {
        jobs.append(job)
        pump()
    }

    func cancel(_ job: Job) {
        switch job.status {
        case .waiting:
            job.status = .cancelled
            onChange?()
        case .running:
            job.task?.cancel()
            engine.cancelAll()
        default:
            break
        }
    }

    func retry(_ job: Job) {
        guard !job.isActive else { return }
        let copy = Job(source: job.source, kind: job.kind, separation: job.separation, speech: job.speech)
        copy.title = job.title
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = copy } else { jobs.append(copy) }
        pump()
    }

    func remove(_ job: Job) {
        if job.isActive { cancel(job) }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() { jobs.removeAll { !$0.isActive } }

    private func pump() {
        guard running == nil, let next = jobs.first(where: { $0.status == .waiting }) else { return }
        next.status = .running
        next.startedAt = Date()
        next.task = Task { [weak self] in
            await self?.process(next)
            self?.onChange?()
            self?.pump()
        }
    }

    // MARK: - Etapas

    private func process(_ job: Job) async {
        let folder = library.folder(for: job.id)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: library.stemsDir(for: job.id), withIntermediateDirectories: true)
            let weights = StageWeights(kind: job.kind, isLink: { if case .link = job.source { return true }; return false }())

            // 1. Origem
            var mediaFile: URL
            var sourceName: String
            var sourceURL: String?
            var downloaded = false
            switch job.source {
            case .file(let url):
                mediaFile = url
                sourceName = url.lastPathComponent
            case .link(let link):
                job.stage = "Baixando"
                let result = try await MediaTools.download(link: link, video: job.kind == .speech, to: folder) { f in
                    Task { @MainActor in job.progress = weights.download * f }
                }
                mediaFile = result.file
                sourceName = result.title.isEmpty ? link : result.title
                sourceURL = link
                downloaded = true
                if !result.title.isEmpty { job.title = result.title }
            }
            try Task.checkCancellation()

            // 2. Áudio do projeto
            job.stage = "Preparando o áudio"
            let probe = try await MediaTools.probe(mediaFile)
            guard probe.hasAudio else { throw MediaTools.Failure.noAudio }
            if let t = probe.title, !t.isEmpty, case .file = job.source, job.title.count < 3 { job.title = t }
            let mix = library.mixURL(for: job.id)
            let base = weights.download
            try await MediaTools.extractAudio(from: mediaFile, to: mix, duration: probe.duration) { f in
                Task { @MainActor in job.progress = base + weights.prepare * f }
            }
            try Task.checkCancellation()

            // 3. Separação
            let separationBase = weights.download + weights.prepare
            let onProgress: (EngineProgress) -> Void = { p in
                job.progress = separationBase + weights.separate * p.fraction
                if !p.label.isEmpty { job.stage = p.label }
            }
            var stems: [StemInfo]
            var loudness: [String: Double] = [:]
            let stemsDir = library.stemsDir(for: job.id)
            switch job.kind {
            case .music:
                let params: [String: Any] = ["input": mix.path, "outdir": stemsDir.path,
                                             "stems": job.separation.stems, "backing": job.separation.backing,
                                             "quality": job.separation.quality.engineValue]
                let r = try await engineCall("separate_music", params, as: SeparationResult.self, progress: onProgress)
                stems = r.stems
            case .speech:
                let params: [String: Any] = ["input": mix.path, "outdir": stemsDir.path,
                                             "denoise": job.speech.denoise, "dereverb": job.speech.dereverb]
                let r = try await engineCall("clean_speech", params, as: SpeechResult.self, progress: onProgress)
                stems = r.stems
                loudness = r.loudness.compactMapValues { $0 }
            }
            try Task.checkCancellation()

            // 4. Análise musical
            var analysis: Analysis?
            if job.kind == .music {
                job.stage = "Analisando a música"
                let vocalStems = stems.filter { ["vocals", "lead", "backing"].contains($0.id) }
                let analysisBase = separationBase + weights.separate
                let params: [String: Any] = ["input": mix.path, "stemsDir": stemsDir.path,
                                             "vocals": vocalStems.map(\.file), "vocalsGain": vocalStems.map(\.gain),
                                             "workDir": folder.path]
                do {
                    analysis = try await engineCall("analyze", params, as: Analysis.self) { p in
                        job.progress = analysisBase + weights.analyze * p.fraction
                        if !p.label.isEmpty { job.stage = p.label }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch EngineError.cancelled {
                    throw CancellationError()
                } catch {
                    NSLog("MusicSplit: análise falhou: \(error)")   // as faixas continuam úteis sem análise
                }
            }

            // 5. Formas de onda
            job.stage = "Finalizando"
            let peaksDir = library.peaksDir(for: job.id)
            let files: [(String, URL, Double)] = [("mix", mix, 1)] + stems.map { ($0.id, stemsDir.appending(path: $0.file), $0.gain) }
            try await Task.detached(priority: .userInitiated) {
                for (id, url, gain) in files {
                    let peaks = try Waveform.compute(file: url, gain: gain)
                    try Waveform.save(peaks, to: peaksDir.appending(path: "\(id).peaks"))
                }
            }.value

            // 6. Projeto
            var videoPath: String?
            if job.kind == .speech, probe.hasVideo {
                videoPath = downloaded ? mediaFile.lastPathComponent : mediaFile.path
            } else if downloaded {
                try? fm.removeItem(at: mediaFile)
            }
            var project = Project(id: job.id, title: job.title, kind: job.kind, createdAt: Date(),
                                  duration: probe.duration > 0 ? probe.duration : Double(analysis?.duration ?? 0),
                                  sourceName: sourceName, sourceURL: sourceURL, videoPath: videoPath,
                                  separation: job.kind == .music ? job.separation : nil,
                                  speechOptions: job.kind == .speech ? job.speech : nil,
                                  stems: stems, loudness: loudness, analysis: analysis)
            if job.kind == .speech {
                project.speech.loudness = LoudnessTarget(rawValue: UserDefaults.standard.string(forKey: "speechLoudness") ?? "") ?? .podcast
            }
            library.add(project)
            job.progress = 1
            job.stage = "Pronto"
            job.status = .done
            onFinished?(project)
        } catch {
            try? fm.removeItem(at: folder)
            if error is CancellationError || (error as? EngineError).map({ if case .cancelled = $0 { true } else { false } }) == true
                || Task.isCancelled {
                job.status = .cancelled
                job.stage = "Cancelado"
            } else {
                job.status = .failed(error.localizedDescription)
                job.stage = "Falhou"
            }
        }
    }

    /// Chamada ao motor que respeita o cancelamento da tarefa.
    private func engineCall<T: Decodable>(_ method: String, _ params: [String: Any], as type: T.Type,
                                          progress: @escaping (EngineProgress) -> Void) async throws -> T {
        let engine = self.engine
        return try await withTaskCancellationHandler {
            try await engine.call(method, params, as: type, progress: progress)
        } onCancel: {
            Task { @MainActor in engine.cancelAll() }
        }
    }
}

private struct StageWeights {
    let download: Double
    let prepare: Double
    let separate: Double
    let analyze: Double

    init(kind: ProjectKind, isLink: Bool) {
        download = isLink ? 0.12 : 0
        prepare = 0.04
        analyze = kind == .music ? 0.12 : 0
        separate = 1 - download - prepare - analyze - 0.03
    }
}
