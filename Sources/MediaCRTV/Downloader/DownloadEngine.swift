import AppKit
import Observation
import SwiftUI

// MARK: - yt-dlp wrapper

enum YTDLP {
    /// Ferramentas instaladas no sistema (Homebrew etc.) têm prioridade.
    /// Diagnóstico: `defaults write com.lipenoe.mediacrtv ForceBundledTools -bool YES` simula um Mac sem Homebrew.
    static let systemDirs = UserDefaults.standard.bool(forKey: "ForceBundledTools")
        ? [] : ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin"]

    /// Cópia do yt-dlp que o app mantém e atualiza (o bundle não deve ser modificado).
    static let supportBin = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "MediaCRTV/bin", directoryHint: .isDirectory)

    /// ffmpeg, ffprobe, deno e yt-dlp embutidos no app (Contents/Resources/bin).
    static let bundledBin = Bundle.main.resourceURL?.appending(path: "bin", directoryHint: .isDirectory)

    static var searchDirs: [String] {
        systemDirs + [supportBin.path] + (bundledBin.map { [$0.path] } ?? [])
    }

    /// Libera os binários embutidos da quarentena (o usuário já aprovou o app) e
    /// copia o yt-dlp para Application Support, onde `yt-dlp -U` consegue se atualizar.
    static func prepareBundledTools() {
        guard let bundled = bundledBin else { return }
        let fm = FileManager.default
        let tools = (try? fm.contentsOfDirectory(atPath: bundled.path)) ?? []
        for tool in tools { removeQuarantine(bundled.appending(path: tool).path) }

        let source = bundled.appending(path: "yt-dlp")
        guard fm.isExecutableFile(atPath: source.path),
              !systemDirs.contains(where: { fm.isExecutableFile(atPath: "\($0)/yt-dlp") }) else { return }

        let target = supportBin.appending(path: "yt-dlp")
        let stamp = supportBin.appending(path: "yt-dlp.version")
        let bundledVersion = (try? String(contentsOf: bundled.appending(path: "yt-dlp.version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let copiedVersion = (try? String(contentsOf: stamp, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Versões do yt-dlp são datas (2026.08.19), então comparação de texto basta.
        guard !fm.isExecutableFile(atPath: target.path) || bundledVersion > copiedVersion else { return }

        do {
            try fm.createDirectory(at: supportBin, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
            removeQuarantine(target.path)
            try bundledVersion.write(to: stamp, atomically: true, encoding: .utf8)
        } catch {
            NSLog("MediaCRTV: falha ao preparar yt-dlp: \(error)")
        }
    }

    private static func removeQuarantine(_ path: String) {
        removexattr(path, "com.apple.quarantine", 0)
    }

    static func find(_ tool: String) -> String? {
        searchDirs.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var binary: String? { find("yt-dlp") }
    static var ffmpeg: String? { find("ffmpeg") }
    static var ffprobe: String? { find("ffprobe") }

    /// Codec de vídeo do primeiro stream (ex.: "h264", "vp9", "av1"); nil sem vídeo ou sem ffprobe.
    static func videoCodec(of file: URL) -> String? {
        guard let probe = ffprobe else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: probe)
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name",
                       "-of", "default=nw=1:nk=1", file.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let codec = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return codec.isEmpty ? nil : codec
    }

    /// Converte para H.264 + AAC no mesmo container (x264 veryfast: ~2x mais rápido que o VideoToolbox no Apple Silicon). Progresso: `out_time_us` do ffmpeg.
    static func h264ConvertArgs(input: URL, output: URL) -> [String] {
        ["-hide_banner", "-nostdin", "-y", "-i", input.path,
         "-map", "0:v:0", "-map", "0:a?",
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p", "-tag:v", "avc1",
         "-c:a", "aac", "-b:a", "256k",
         "-movflags", "+faststart",
         "-progress", "pipe:1", "-nostats", output.path]
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = UserDefaults.standard.bool(forKey: "ForceBundledTools") ? "/usr/bin:/bin" : (env["PATH"] ?? "")
        env["PATH"] = (searchDirs + [inherited]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    static func makeProcess(_ args: [String]) throws -> Process {
        guard let bin = binary else { throw EngineError.missingYTDLP }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        return p
    }

    static func cookieArgs(_ source: CookieSource) -> [String] {
        source == .none ? [] : ["--cookies-from-browser", source.rawValue]
    }

    /// Lê metadados sem baixar.
    static func fetchInfo(url: String, cookies: CookieSource) async throws -> MediaInfo {
        let p = try makeProcess(["-J", "--no-playlist", "--no-warnings"] + cookieArgs(cookies) + [url])
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try p.run() } catch { cont.resume(throwing: error); return }
                    var errData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    p.waitUntilExit()
                    if p.terminationStatus != 0 {
                        cont.resume(throwing: EngineError.failed(cleanError(String(decoding: errData, as: UTF8.self))))
                        return
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        cont.resume(throwing: EngineError.failed("Resposta inesperada do yt-dlp."))
                        return
                    }
                    cont.resume(returning: MediaInfo(json: json, platform: Platform.detect(url) ?? .other))
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }

    static func downloadArgs(url: String, options o: DownloadOptions, destination: URL, cookies: CookieSource) -> [String] {
        var a = [
            "--newline", "--progress", "--no-playlist", "--no-mtime", "--no-warnings",
            "--progress-template", "download:[P]%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(info.vcodec)s|%(info.acodec)s",
            "--progress-template", "postprocess:[PP]%(progress.postprocessor)s|%(progress.status)s",
            "--print", "after_move:[F]%(filepath)s",
            "-P", destination.path,
            "-o", "%(title).120B [%(id)s].%(ext)s",
        ]
        if let ff = ffmpeg { a += ["--ffmpeg-location", ff] }
        a += cookieArgs(cookies)

        switch o.mode {
        case .video:
            a += ["-f", "bv*+ba/b"]
            // Resolução escolhida manda; em "Melhor" com H.264, o codec vem antes da resolução.
            var sort: [String] = []
            let compat = o.preferH264 && o.container != .webm
            if let h = o.height { sort.append("res:\(h)") }
            if compat { sort.append("vcodec:h264") }
            if o.height == nil { sort.append("res") }
            if compat { sort.append("acodec:aac") }
            if !sort.isEmpty { a += ["-S", sort.joined(separator: ",")] }
            a += ["--merge-output-format", o.container.rawValue, "--remux-video", o.container.rawValue]
        case .audio:
            a += ["-f", "ba/b", "-x", "--audio-format", o.audioFormat.rawValue]
            a += ["--audio-quality", o.audioFormat.isLossless ? "0" : "\(o.audioKbps)K"]
            if o.audioFormat != .wav { a += ["--embed-metadata"] }
            if o.audioFormat == .mp3 { a += ["--embed-thumbnail"] }
        }
        return a + [url]
    }

    static func cleanError(_ s: String) -> String {
        let lines = s.split(separator: "\n").map(String.init)
        let line = lines.last { $0.hasPrefix("ERROR") } ?? lines.last ?? "Falha desconhecida."
        var msg = line.replacingOccurrences(of: "ERROR: ", with: "")
        if let r = msg.range(of: #"^\[[^\]]+\] [^:]+: "#, options: .regularExpression) { msg.removeSubrange(r) }
        if msg.localizedCaseInsensitiveContains("Unsupported URL") {
            return "Esse site não é suportado ou o link não tem vídeo."
        }
        if msg.contains("403") || msg.localizedCaseInsensitiveContains("Forbidden") || msg.localizedCaseInsensitiveContains("Sign in to confirm") {
            msg += "\nDica: o site mudou algo — use MediaCRTV ▸ Atualizar yt-dlp e tente de novo."
        } else if ["login", "cookies", "authentication", "log in", "sign in"].contains(where: { msg.localizedCaseInsensitiveContains($0) }) {
            msg += "\nDica: escolha um navegador logado em “Cookies” no rodapé."
        }
        return msg
    }
}

enum EngineError: LocalizedError {
    case missingYTDLP
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .missingYTDLP: "yt-dlp não encontrado. Instale com: brew install yt-dlp ffmpeg"
        case .failed(let m): m
        }
    }
}

// MARK: - Download job

@MainActor @Observable
final class DownloadJob: Identifiable {
    enum State: Equatable {
        case queued, downloading, processing, done, failed(String), cancelled
    }

    let id = UUID()
    let url: String
    let title: String
    let thumbnail: URL?
    let platform: Platform
    let options: DownloadOptions
    let destination: URL
    let cookies: CookieSource
    let durationSeconds: Double

    var state: State = .queued
    var progress: Double = 0
    var detail = "Na fila"
    var fileURL: URL?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var sawVideoStream = false
    @ObservationIgnored private var stderrLog = ""
    @ObservationIgnored var onFinish: ((DownloadJob) -> Void)?

    init(url: String, info: MediaInfo, options: DownloadOptions, destination: URL, cookies: CookieSource) {
        self.url = url
        self.title = info.title
        self.thumbnail = info.thumbnail
        self.platform = info.platform
        self.options = options
        self.destination = destination
        self.cookies = cookies
        self.durationSeconds = info.duration ?? 0
    }

    var isActive: Bool { state == .queued || state == .downloading || state == .processing }

    func start() {
        state = .downloading
        progress = 0
        detail = "Conectando…"
        sawVideoStream = false
        stderrLog = ""
        buffer = ""

        let args = YTDLP.downloadArgs(url: url, options: options, destination: destination, cookies: cookies)
        let p: Process
        do { p = try YTDLP.makeProcess(args) } catch {
            fail(error.localizedDescription); return
        }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async { self?.stderrLog += chunk }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            DispatchQueue.main.async {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                self?.finish(status: status, reason: reason)
            }
        }
        do { try p.run(); process = p } catch { fail(error.localizedDescription) }
    }

    func cancel() {
        guard isActive else { return }
        state = .cancelled
        detail = "Cancelado"
        process?.terminate()
    }

    private func consume(_ chunk: String) {
        buffer += chunk
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...nl)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard state == .downloading || state == .processing else { return }
        if line.hasPrefix("[P]") {
            let f = line.dropFirst(3).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return }
            let done = Double(f[0]) ?? 0
            let total = Double(f[1]) ?? Double(f[2]) ?? 0
            let speed = Double(f[3])
            let eta = Double(f[4])
            let hasVideo = f[5] != "none" && f[5] != "NA"
            let hasAudio = f[6] != "none" && f[6] != "NA"
            let frac = total > 0 ? min(done / total, 1) : 0

            // Vídeo sem áudio: 0–90%, áudio separado depois: 90–100%.
            if hasVideo && !hasAudio && options.mode == .video {
                sawVideoStream = true
                progress = frac * 0.9
            } else if !hasVideo && sawVideoStream {
                progress = 0.9 + frac * 0.1
            } else {
                progress = frac
            }
            state = .downloading
            var parts: [String] = []
            if total > 0 { parts.append("\(Fmt.bytes(Int64(done))) de \(Fmt.bytes(Int64(total)))") }
            if let s = speed { parts.append("\(Fmt.bytes(Int64(s)))/s") }
            if let e = eta, e > 0 { parts.append("faltam \(Fmt.duration(e))") }
            detail = parts.isEmpty ? "Baixando…" : parts.joined(separator: " · ")
        } else if line.hasPrefix("[PP]") {
            let name = line.dropFirst(4).split(separator: "|").first.map(String.init) ?? ""
            guard name != "MoveFiles" else { return }
            state = .processing
            progress = 1
            detail = switch name {
            case "Merger": "Juntando vídeo e áudio…"
            case "ExtractAudio": "Convertendo áudio…"
            case "FFmpegVideoRemuxer", "VideoRemuxer": "Ajustando formato…"
            case "EmbedThumbnail": "Incorporando capa…"
            case "FFmpegMetadata", "Metadata": "Gravando metadados…"
            default: "Processando…"
            }
        } else if line.hasPrefix("[F]") {
            fileURL = URL(fileURLWithPath: String(line.dropFirst(3)))
        }
    }

    private func finish(status: Int32, reason: Process.TerminationReason) {
        process = nil
        if !buffer.isEmpty { handle(buffer); buffer = "" }
        if state == .cancelled { onFinish?(self); return }
        if status == 0, needsH264Conversion, let f = fileURL {
            convertToH264(f); return
        }
        if status == 0 {
            state = .done
            progress = 1
            if let f = fileURL, let size = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                detail = "\(Fmt.bytes(Int64(size))) · \(f.pathExtension.uppercased())"
            } else {
                detail = "Concluído"
            }
        } else {
            fail(YTDLP.cleanError(stderrLog))
        }
        onFinish?(self)
    }

    /// "Priorizar H.264" ligado mas o site só tinha VP9/AV1: converte para o Premiere abrir com imagem.
    private var needsH264Conversion: Bool {
        guard options.mode == .video, options.preferH264, options.container != .webm,
              YTDLP.ffmpeg != nil, let f = fileURL, let codec = YTDLP.videoCodec(of: f) else { return false }
        return codec != "h264"
    }

    private func convertToH264(_ input: URL) {
        guard let ff = YTDLP.ffmpeg else { return }
        state = .processing
        progress = 0
        detail = "Convertendo para H.264…"
        let duration = durationSeconds
        let tmp = input.deletingLastPathComponent()
            .appending(path: ".\(input.deletingPathExtension().lastPathComponent).h264.\(input.pathExtension)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = YTDLP.h264ConvertArgs(input: input, output: tmp)
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.state == .processing, duration > 0 else { return }
                for line in chunk.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                    if let us = Double(line.dropFirst(12)) {
                        self.progress = min(us / 1_000_000 / duration, 1)
                        self.detail = "Convertendo para H.264… \(Int(self.progress * 100))%"
                    }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async { self?.stderrLog += chunk }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.process = nil
                let fm = FileManager.default
                if self.state == .cancelled {
                    try? fm.removeItem(at: tmp)
                } else if status == 0, (try? fm.replaceItemAt(input, withItemAt: tmp)) != nil {
                    self.state = .done
                    self.progress = 1
                    let size = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
                    self.detail = [size.map { Fmt.bytes(Int64($0)) }, "\(input.pathExtension.uppercased()) · H.264"]
                        .compactMap { $0 }.joined(separator: " · ")
                } else {
                    try? fm.removeItem(at: tmp)
                    // Mantém o original: melhor um VP9/AV1 do que nada.
                    self.state = .done
                    self.progress = 1
                    self.detail = "Baixado, mas a conversão para H.264 falhou"
                }
                self.onFinish?(self)
            }
        }
        do { try p.run(); process = p } catch {
            state = .done
            detail = "Baixado, mas a conversão para H.264 falhou"
            onFinish?(self)
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        detail = message
    }

    func reveal() {
        if let f = fileURL, FileManager.default.fileExists(atPath: f.path) {
            NSWorkspace.shared.activateFileViewerSelecting([f])
        } else {
            NSWorkspace.shared.open(destination)
        }
    }

    func open() {
        if let f = fileURL { NSWorkspace.shared.open(f) }
    }
}

// MARK: - DownloadStore

@MainActor @Observable
final class DownloadStore {
    var urlText = ""
    var info: MediaInfo?
    var isFetching = false
    var fetchError: String?
    var options = DownloadOptions() { didSet { saveOptions() } }
    var jobs: [DownloadJob] = []

    var destination: URL {
        didSet { UserDefaults.standard.set(destination.path, forKey: "destination") }
    }
    var cookies: CookieSource {
        didSet { UserDefaults.standard.set(cookies.rawValue, forKey: "cookies") }
    }

    let ytdlpAvailable: Bool
    /// deno resolve os desafios JavaScript do YouTube; sem ele, muitos vídeos dão 403.
    let missingTools: [String]

    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var analyzedURL: String?

    init() {
        YTDLP.prepareBundledTools()
        ytdlpAvailable = YTDLP.binary != nil
        missingTools = ["yt-dlp", "ffmpeg", "deno"].filter { YTDLP.find($0) == nil }

        let d = UserDefaults.standard
        destination = d.string(forKey: "destination").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        cookies = CookieSource(rawValue: d.string(forKey: "cookies") ?? "") ?? .none
        var o = DownloadOptions()
        o.mode = DownloadMode(rawValue: d.string(forKey: "mode") ?? "") ?? .video
        o.container = VideoContainer(rawValue: d.string(forKey: "container") ?? "") ?? .mp4
        o.preferH264 = d.object(forKey: "preferH264") as? Bool ?? true
        o.audioFormat = AudioFormat(rawValue: d.string(forKey: "audioFormat") ?? "") ?? .mp3
        o.audioKbps = d.object(forKey: "audioKbps") as? Int ?? 320
        options = o
    }

    private func saveOptions() {
        let d = UserDefaults.standard
        d.set(options.mode.rawValue, forKey: "mode")
        d.set(options.container.rawValue, forKey: "container")
        d.set(options.preferH264, forKey: "preferH264")
        d.set(options.audioFormat.rawValue, forKey: "audioFormat")
        d.set(options.audioKbps, forKey: "audioKbps")
    }

    var platform: Platform? { Platform.detect(urlText) }
    /// Cor da plataforma do link atual; pinta o fundo e os controles.
    var tint: Color { (info?.platform ?? platform)?.tint ?? .accentColor }
    var activeCount: Int { jobs.filter(\.isActive).count }

    func urlChanged() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { reset(); return }
        // Analisa automaticamente links colados ou arrastados. Para sites fora da lista em destaque,
        // espera a digitação parar, para não disparar o yt-dlp a cada tecla.
        guard let p = Platform.detect(trimmed), trimmed != analyzedURL else { return }
        autoTask?.cancel()
        if p != .other { analyze(); return }
        autoTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled,
                  self.urlText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            self.analyze()
        }
    }

    func reset() {
        fetchTask?.cancel()
        info = nil
        fetchError = nil
        isFetching = false
        analyzedURL = nil
    }

    func pasteFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) {
            urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
            analyze()
        }
    }

    func analyze() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Platform.detect(url) != nil else {
            fetchError = "Isso não parece um link válido."
            return
        }
        guard url != analyzedURL || info == nil else { return }
        fetchTask?.cancel()
        analyzedURL = url
        isFetching = true
        fetchError = nil
        info = nil
        let cookies = cookies
        fetchTask = Task {
            do {
                let result = try await YTDLP.fetchInfo(url: url, cookies: cookies)
                guard !Task.isCancelled, url == self.analyzedURL else { return }
                self.info = result
                if let h = self.options.height, !result.heights.contains(h) {
                    self.options.height = result.heights.first { $0 <= h }
                }
            } catch {
                guard !Task.isCancelled, url == self.analyzedURL else { return }
                self.fetchError = error.localizedDescription
                self.analyzedURL = nil
            }
            if url == self.analyzedURL || self.analyzedURL == nil { self.isFetching = false }
        }
    }

    /// Opções valendo para este link: se ele só tem áudio (ex.: SoundCloud), força o modo áudio
    /// sem mexer na preferência salva.
    func effectiveOptions(for info: MediaInfo) -> DownloadOptions {
        var o = options
        if !info.hasVideo { o.mode = .audio }
        return o
    }

    func download() {
        guard let info else { return }
        let job = DownloadJob(url: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
                              info: info, options: effectiveOptions(for: info), destination: destination, cookies: cookies)
        job.onFinish = { [weak self] j in self?.jobFinished(j) }
        jobs.insert(job, at: 0)
        job.start()
        updateBadge()
    }

    func retry(_ job: DownloadJob) {
        job.start()
        updateBadge()
    }

    func remove(_ job: DownloadJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
        updateBadge()
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    private func jobFinished(_ job: DownloadJob) {
        updateBadge()
        switch job.state {
        case .done: NSSound(named: "Glass")?.play()
        case .failed: NSSound(named: "Basso")?.play()
        default: break
        }
    }

    private func updateBadge() {
        let n = activeCount
        DockBadge.set("downloads", n)
    }

    // MARK: yt-dlp update

    var updateStatus: String?
    var isUpdating = false

    func updateYTDLP() {
        guard !isUpdating, let bin = YTDLP.binary else { return }
        isUpdating = true
        updateStatus = "Atualizando yt-dlp…"
        let viaBrew = bin.hasPrefix("/opt/homebrew") || bin.hasPrefix("/usr/local")
        let p = Process()
        if viaBrew, let brew = YTDLP.find("brew") {
            p.executableURL = URL(fileURLWithPath: brew)
            p.arguments = ["upgrade", "yt-dlp"]
        } else {
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-U"]
        }
        var env = YTDLP.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = nil
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { proc in
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let ok = proc.terminationStatus == 0
            let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            // Cópia gerenciada pelo app: registra a nova versão para não ser trocada pela embutida.
            if ok, !viaBrew, bin.hasPrefix(YTDLP.supportBin.path) {
                let v = Process()
                v.executableURL = URL(fileURLWithPath: bin)
                v.arguments = ["--version"]
                v.standardInput = FileHandle.nullDevice
                let vp = Pipe()
                v.standardOutput = vp
                if (try? v.run()) != nil {
                    v.waitUntilExit()
                    let version = String(decoding: vp.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    try? version.trimmingCharacters(in: .whitespacesAndNewlines)
                        .write(to: YTDLP.supportBin.appending(path: "yt-dlp.version"), atomically: true, encoding: .utf8)
                }
            }
            DispatchQueue.main.async {
                self.isUpdating = false
                if ok, let line = lines.last(where: { $0.contains("->") || $0.hasPrefix("Updated yt-dlp") }) {
                    self.updateStatus = "Atualizado: \(line)"
                } else if ok {
                    self.updateStatus = "yt-dlp já está na versão mais recente."
                } else {
                    self.updateStatus = viaBrew
                        ? "Falha ao atualizar. No Terminal: brew upgrade yt-dlp"
                        : "Falha ao atualizar: \(lines.last(where: { $0.hasPrefix("ERROR") }) ?? "verifique a conexão")"
                }
            }
        }
        do { try p.run() } catch {
            isUpdating = false
            updateStatus = "Falha ao atualizar: \(error.localizedDescription)"
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "Escolher"
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
