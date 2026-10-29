import AppKit
import Observation

// MARK: - ffmpeg / ffprobe

/// Mesmas ferramentas do Downloader (embutidas no app ou do Homebrew); a quarentena é tratada em YTDLP.prepareBundledTools().
enum Tools {
    static var ffmpeg: String? { YTDLP.ffmpeg }
    static var ffprobe: String? { YTDLP.ffprobe }
}

// MARK: - Probe

struct MediaProbe {
    var container: String          // extensão do arquivo, minúscula
    var videoCodec: String?        // nil = sem vídeo (ou só capa)
    var pixFmt: String?
    var audioCodec: String?
    var duration: Double
    var width: Int?
    var height: Int?

    /// Codecs que o Premiere (Mac) decodifica sem plugin.
    static let premiereVideo: Set<String> = ["h264", "prores", "dnxhd", "mjpeg"]
    static let premiereAudio: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]
    static let premiereContainers: Set<String> = ["mp4", "mov", "m4v", "mxf"]

    var hasVideo: Bool { videoCodec != nil }

    /// HEVC 8-bit abre no Premiere; 10-bit e VP9/AV1 dão "só áudio" ou travam a timeline.
    var videoOK: Bool {
        guard let v = videoCodec else { return true }
        if v == "hevc" { return !(pixFmt ?? "").contains("10") }
        return Self.premiereVideo.contains(v)
    }
    var audioOK: Bool { audioCodec.map { Self.premiereAudio.contains($0) || $0.hasPrefix("pcm_") } ?? true }
    var containerOK: Bool { Self.premiereContainers.contains(container) }

    var summary: String {
        var parts: [String] = []
        if let v = videoCodec { parts.append(Self.label(v)) }
        if let h = height { parts.append("\(h)p") }
        if let a = audioCodec { parts.append(Self.label(a)) }
        parts.append(container.uppercased())
        return parts.joined(separator: " · ")
    }

    static func label(_ codec: String) -> String {
        switch codec {
        case "h264": "H.264"
        case "hevc": "HEVC"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "av1": "AV1"
        case "prores": "ProRes"
        case "aac": "AAC"
        case "opus": "Opus"
        case "vorbis": "Vorbis"
        case "mp3": "MP3"
        case "flac": "FLAC"
        default: codec.hasPrefix("pcm_") ? "PCM" : codec.uppercased()
        }
    }

    static func probe(_ file: URL) async throws -> MediaProbe {
        guard let bin = Tools.ffprobe else { throw ConvertError.missingFFmpeg }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", file.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConvertError.notMedia
        }
        let streams = root["streams"] as? [[String: Any]] ?? []
        // Capa embutida (attached_pic) não conta como vídeo.
        let video = streams.first {
            $0["codec_type"] as? String == "video" &&
            ((($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) ?? 0) == 0
        }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        guard video != nil || audio != nil else { throw ConvertError.notMedia }
        let format = root["format"] as? [String: Any]
        return MediaProbe(
            container: file.pathExtension.lowercased(),
            videoCodec: video?["codec_name"] as? String,
            pixFmt: video?["pix_fmt"] as? String,
            audioCodec: audio?["codec_name"] as? String,
            duration: Double(format?["duration"] as? String ?? "") ?? 0,
            width: video?["width"] as? Int,
            height: video?["height"] as? Int
        )
    }
}

// MARK: - Presets

enum Preset: String, CaseIterable, Identifiable {
    case premiere, prores, audio
    var id: String { rawValue }

    var label: String {
        switch self {
        case .premiere: "Premiere"
        case .prores: "ProRes 422"
        case .audio: "Só áudio"
        }
    }

    var caption: String {
        switch self {
        case .premiere: "H.264 MP4 · leve"
        case .prores: "MOV · edição pesada"
        case .audio: "WAV · sem perdas"
        }
    }
}

/// O que será feito com um arquivo — decidido depois do probe.
enum Plan: Equatable {
    case nothing            // já abre no Premiere
    case remux              // só troca o container (instantâneo, sem perda)
    case audioOnly          // copia o vídeo, converte o áudio para AAC
    case transcode          // reencoda vídeo (e áudio)
    case prores
    case extractAudio

    var label: String {
        switch self {
        case .nothing: "Já compatível"
        case .remux: "Trocar container"
        case .audioOnly: "Converter áudio"
        case .transcode: "Converter para H.264"
        case .prores: "Converter para ProRes"
        case .extractAudio: "Extrair áudio"
        }
    }

    static func make(_ preset: Preset, _ m: MediaProbe) -> Plan {
        switch preset {
        case .prores: return m.hasVideo ? .prores : .extractAudio
        case .audio: return .extractAudio
        case .premiere:
            guard m.hasVideo else { return m.audioOK ? .nothing : .extractAudio }
            if !m.videoOK { return .transcode }
            if !m.audioOK { return .audioOnly }
            return m.containerOK ? .nothing : .remux
        }
    }
}

enum ConvertError: LocalizedError {
    case missingFFmpeg, notMedia, failed(String)
    var errorDescription: String? {
        switch self {
        case .missingFFmpeg: "ffmpeg não encontrado."
        case .notMedia: "Não é um arquivo de vídeo ou áudio."
        case .failed(let m): m
        }
    }
}

// MARK: - Job

@Observable
final class ConvertJob: Identifiable {
    enum State: Equatable { case probing, ready, converting, done, skipped, failed(String), cancelled }

    let id = UUID()
    let input: URL
    var probe: MediaProbe?
    var plan: Plan?
    var state: State = .probing
    var progress: Double = 0
    var detail = "Analisando…"
    var output: URL?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stderrTail = ""
    @ObservationIgnored var onFinish: ((ConvertJob) -> Void)?

    init(input: URL) { self.input = input }

    var name: String { input.lastPathComponent }
    var isActive: Bool { state == .probing || state == .ready || state == .converting }

    func analyze(preset: Preset) async {
        do {
            let p = try await MediaProbe.probe(input)
            probe = p
            replan(preset)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func replan(_ preset: Preset) {
        guard let p = probe, state == .ready || state == .probing || state == .skipped else { return }
        plan = Plan.make(preset, p)
        if plan == .nothing {
            state = .skipped
            detail = "\(p.summary) — já abre no Premiere"
        } else {
            state = .ready
            detail = "\(p.summary) → \(plan!.label)"
        }
    }

    func start(destination: URL?, useHardware: Bool = true) {
        guard let plan, let probe, let ff = Tools.ffmpeg else {
            fail(ConvertError.missingFFmpeg.localizedDescription); onFinish?(self); return
        }
        let out = Self.outputURL(for: input, plan: plan, in: destination ?? input.deletingLastPathComponent())
        output = out
        state = .converting
        progress = 0
        detail = plan.label + "…"
        stderrTail = ""
        // Grava num temporário oculto e só renomeia no fim: nunca deixa arquivo pela metade com o nome final.
        let tmp = out.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).\(out.pathExtension)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-nostdin", "-y", "-i", input.path]
            + Self.codecArgs(plan, probe: probe, hardware: useHardware)
            + ["-progress", "pipe:1", "-nostats", tmp.path]
        p.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        let duration = probe.duration

        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.state == .converting, duration > 0 else { return }
                for line in chunk.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                    guard let us = Double(line.dropFirst(12)) else { continue }
                    self.progress = min(max(us / 1_000_000 / duration, 0), 1)
                    self.detail = "\(plan.label)… \(Int(self.progress * 100))%"
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + chunk).suffix(4000))
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.process = nil
                let fm = FileManager.default
                if self.state == .cancelled {
                    try? fm.removeItem(at: tmp)
                } else if status == 0 {
                    try? fm.removeItem(at: out)
                    do {
                        try fm.moveItem(at: tmp, to: out)
                        self.state = .done
                        self.progress = 1
                        let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        self.detail = "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) · \(out.lastPathComponent)"
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                } else {
                    try? fm.removeItem(at: tmp)
                    // VideoToolbox recusa algumas resoluções/formatos raros: tenta de novo em software.
                    if useHardware, plan == .transcode || plan == .prores {
                        self.start(destination: destination, useHardware: false); return
                    }
                    self.fail(Self.cleanError(self.stderrTail))
                }
                self.onFinish?(self)
            }
        }
        do { try p.run(); process = p } catch { fail(error.localizedDescription); onFinish?(self) }
    }

    func cancel() {
        guard isActive else { return }
        state = .cancelled
        detail = "Cancelado"
        process?.terminate()
    }

    private func fail(_ message: String) {
        state = .failed(message)
        detail = message
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([output ?? input])
    }

    // MARK: ffmpeg args

    static func codecArgs(_ plan: Plan, probe: MediaProbe, hardware: Bool) -> [String] {
        let maps = ["-map", "0:v:0?", "-map", "0:a:0?", "-map_metadata", "0"]
        let aac = ["-c:a", "aac", "-b:a", "320k"]
        let mp4 = ["-movflags", "+faststart"]
        // No Apple Silicon o x264 veryfast é ~2x mais rápido que o h264_videotoolbox (que trava em ~80 fps
        // a 1440p) com tamanho parecido. O fallback "sem hardware" vira um preset mais lento e robusto.
        let h264 = hardware
            ? ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-profile:v", "high"]
            : ["-c:v", "libx264", "-preset", "medium", "-crf", "18"]
        switch plan {
        case .nothing: return []
        case .remux:
            return maps + ["-c", "copy"] + mp4
        case .audioOnly:
            return maps + ["-c:v", "copy"] + aac + mp4
        case .transcode:
            return maps + h264 + ["-pix_fmt", "yuv420p", "-tag:v", "avc1"] + aac + mp4
        case .prores:
            let v = hardware
                ? ["-c:v", "prores_videotoolbox", "-profile:v", "standard"]
                : ["-c:v", "prores_ks", "-profile:v", "2", "-vendor", "apl0"]
            return maps + v + ["-pix_fmt", hardware ? "p210" : "yuv422p10le", "-c:a", "pcm_s16le"]
        case .extractAudio:
            return ["-map", "0:a:0", "-vn", "-c:a", "pcm_s16le"]
        }
    }

    static func outputURL(for input: URL, plan: Plan, in dir: URL) -> URL {
        let ext = switch plan {
        case .prores: "mov"
        case .extractAudio: "wav"
        default: "mp4"
        }
        let base = input.deletingPathExtension().lastPathComponent
        let suffix = plan == .prores ? "ProRes" : plan == .extractAudio ? "Áudio" : "Premiere"
        var url = dir.appending(path: "\(base) (\(suffix)).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appending(path: "\(base) (\(suffix) \(n)).\(ext)")
            n += 1
        }
        return url
    }

    static func cleanError(_ log: String) -> String {
        let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let hit = lines.last { $0.localizedCaseInsensitiveContains("error") || $0.contains("Invalid") }
        return hit ?? "A conversão falhou."
    }
}

// MARK: - ConvertStore

@Observable
final class ConvertStore {
    var jobs: [ConvertJob] = []
    var preset: Preset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: "converter.preset")
            for j in jobs { j.replan(preset) }
        }
    }
    /// nil = ao lado do arquivo original.
    var destination: URL? {
        didSet { UserDefaults.standard.set(destination?.path, forKey: "converter.destination") }
    }
    var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: "converter.autoStart") }
    }
    let ffmpegAvailable = Tools.ffmpeg != nil && Tools.ffprobe != nil

    init() {
        let d = UserDefaults.standard
        preset = Preset(rawValue: d.string(forKey: "converter.preset") ?? "") ?? .premiere
        destination = d.string(forKey: "converter.destination").map { URL(fileURLWithPath: $0) }
        autoStart = d.object(forKey: "converter.autoStart") as? Bool ?? true
    }

    var running: ConvertJob? { jobs.first { $0.state == .converting } }
    var pending: [ConvertJob] { jobs.filter { $0.state == .ready } }

    func add(_ urls: [URL]) {
        let files = urls.flatMap(Self.expand)
        let known = Set(jobs.filter(\.isActive).map(\.input))
        for url in files where !known.contains(url) {
            let job = ConvertJob(input: url)
            job.onFinish = { [weak self] _ in self?.jobFinished() }
            jobs.insert(job, at: 0)
            Task { @MainActor in
                await job.analyze(preset: self.preset)
                if self.autoStart { self.next() }
            }
        }
    }

    /// Pastas soltas na janela entram com todos os arquivos de dentro.
    private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [url] }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (e?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
    }

    func startAll() { next() }

    /// Um por vez: o encoder de hardware já usa a máquina toda.
    private func next() {
        guard running == nil, let job = pending.last else { updateBadge(); return }
        job.start(destination: destination)
        updateBadge()
    }

    private func jobFinished() {
        next()
        if running == nil, pending.isEmpty, jobs.contains(where: { $0.state == .done }) {
            NSSound(named: "Glass")?.play()
        }
    }

    func retry(_ job: ConvertJob) {
        job.state = .probing
        Task { @MainActor in
            await job.analyze(preset: preset)
            next()
        }
    }

    func remove(_ job: ConvertJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        updateBadge()
    }

    private func updateBadge() {
        let n = jobs.filter { $0.state == .converting || $0.state == .ready }.count
        DockBadge.set("converter", n)
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Escolher"
        if panel.runModal() == .OK { destination = panel.url }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .folder]
        panel.prompt = "Adicionar"
        if panel.runModal() == .OK { add(panel.urls) }
    }
}
