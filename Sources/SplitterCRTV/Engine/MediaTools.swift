import Foundation

/// ffprobe / ffmpeg / yt-dlp: ler, converter e baixar mídia.
enum MediaTools {
    struct Probe {
        var duration: Double
        var hasVideo: Bool
        var hasAudio: Bool
        var title: String?
    }

    enum Failure: LocalizedError {
        case missingTool(String)
        case failed(String)
        case noAudio

        var errorDescription: String? {
            switch self {
            case .missingTool(let t): "\(t) não encontrado."
            case .failed(let m): m
            case .noAudio: "Esse arquivo não tem áudio."
            }
        }
    }

    static let mediaExtensions: Set<String> = [
        "mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "ogg", "opus", "wma", "caf", "alac",
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "mts", "3gp",
    ]

    static func isMedia(_ url: URL) -> Bool { mediaExtensions.contains(url.pathExtension.lowercased()) }

    /// Lê duração e trilhas com o próprio ffmpeg (dispensa o ffprobe e seus 66 MB no DMG).
    static func probe(_ url: URL) async throws -> Probe {
        guard let ffmpeg = Toolchain.ffmpeg else { throw Failure.missingTool("ffmpeg") }
        let out = try await ProcessRunner.run(ffmpeg, ["-nostdin", "-hide_banner", "-i", url.path], allowFailure: true)
        let text = out.stderr
        guard text.contains("Input #0") else { throw Failure.failed("Não consegui ler o arquivo.") }
        var duration = 0.0
        if let r = text.range(of: #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) {
            let parts = text[r].dropFirst("Duration: ".count).split(separator: ":").compactMap { Double($0) }
            if parts.count == 3 { duration = parts[0] * 3600 + parts[1] * 60 + parts[2] }
        }
        let streams = text.split(separator: "\n").filter { $0.contains("Stream #") }
        let hasVideo = streams.contains { $0.contains("Video:") && !$0.contains("attached pic") }
        let hasAudio = streams.contains { $0.contains("Audio:") }
        var title: String?
        let header = text.components(separatedBy: "Stream #").first ?? ""
        if let r = header.range(of: #"\n\s+title\s+: [^\n]+"#, options: .regularExpression) {
            title = header[r].components(separatedBy: ": ").dropFirst().joined(separator: ": ").trimmingCharacters(in: .whitespaces)
        }
        return Probe(duration: duration, hasVideo: hasVideo, hasAudio: hasAudio, title: title)
    }

    /// Converte qualquer mídia no áudio do projeto: FLAC 24 bits, 44,1 kHz, estéreo.
    static func extractAudio(from source: URL, to target: URL, duration: Double,
                             progress: @escaping (Double) -> Void) async throws {
        guard let ffmpeg = Toolchain.ffmpeg else { throw Failure.missingTool("ffmpeg") }
        let args = ["-nostdin", "-y", "-v", "error", "-i", source.path, "-vn", "-map", "0:a:0",
                    "-ac", "2", "-ar", "44100", "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24",
                    "-progress", "pipe:1", "-nostats", target.path]
        _ = try await ProcessRunner.run(ffmpeg, args) { line in
            if line.hasPrefix("out_time_us="), duration > 0, let us = Double(line.dropFirst(12)) {
                progress(min(1, us / 1_000_000 / duration))
            }
        }
    }

    /// Baixa um link com o yt-dlp. Para fala com vídeo, baixa o vídeo (H.264) para devolver com o áudio novo.
    static func download(link: String, video: Bool, to dir: URL,
                         progress: @escaping (Double) -> Void) async throws -> (file: URL, title: String) {
        guard let ytdlp = Toolchain.ytdlp else { throw Failure.missingTool("yt-dlp") }
        var args = ["--newline", "--no-playlist", "--no-mtime", "--no-warnings",
                    "--progress-template", "download:[P]%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s",
                    "--print", "after_move:[F]%(filepath)s",
                    "--print", "after_move:[T]%(title)s",
                    "-P", dir.path, "-o", "source.%(ext)s"]
        if let ff = Toolchain.ffmpeg { args += ["--ffmpeg-location", ff] }
        if video {
            args += ["-f", "bv*+ba/b", "-S", "vcodec:h264,res:1080,acodec:aac", "--merge-output-format", "mp4"]
        } else {
            args += ["-f", "ba/b"]
        }
        args.append(link)
        var file: URL?
        var title = ""
        let result = try await ProcessRunner.run(ytdlp, args, allowFailure: true) { line in
            if line.hasPrefix("[P]") {
                let parts = line.dropFirst(3).split(separator: "|").map(String.init)
                let done = Double(parts.first ?? "") ?? 0
                let total = Double(parts.count > 1 ? parts[1] : "") ?? Double(parts.count > 2 ? parts[2] : "") ?? 0
                if total > 0 { progress(min(1, done / total)) }
            } else if line.hasPrefix("[F]") {
                file = URL(fileURLWithPath: String(line.dropFirst(3)))
            } else if line.hasPrefix("[T]") {
                title = String(line.dropFirst(3))
            }
        }
        guard result.status == 0, let file else {
            throw Failure.failed(cleanYTDLPError(result.stderr))
        }
        return (file, title)
    }

    static func cleanYTDLPError(_ s: String) -> String {
        let lines = s.split(separator: "\n").map(String.init)
        let line = lines.last { $0.hasPrefix("ERROR") } ?? lines.last ?? "Falha ao baixar o link."
        var msg = line.replacingOccurrences(of: "ERROR: ", with: "")
        if let r = msg.range(of: #"^\[[^\]]+\] [^:]+: "#, options: .regularExpression) { msg.removeSubrange(r) }
        if msg.localizedCaseInsensitiveContains("Unsupported URL") { return "Esse link não é suportado." }
        if msg.contains("403") { return "O site recusou o download (403). Tente atualizar o yt-dlp." }
        if msg.localizedCaseInsensitiveContains("login") || msg.localizedCaseInsensitiveContains("private") {
            return "Esse conteúdo exige login ou é privado."
        }
        return msg
    }

    static func looksLikeLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}

/// Roda um processo, repassa as linhas do stdout e respeita o cancelamento da Task.
enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    @discardableResult
    static func run(_ executable: String, _ args: [String], allowFailure: Bool = false,
                    onLine: ((String) -> Void)? = nil) async throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = Toolchain.toolEnvironment
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let box = OutputBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; return }
                    for line in box.appendOut(d) { onLine?(line) }
                }
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; return }
                    box.appendErr(d)
                }
                p.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
                    for line in box.appendOut(rest, flush: true) { onLine?(line) }
                    box.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    let output = Output(status: proc.terminationStatus, stdout: box.out, stderr: box.err)
                    if proc.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else if proc.terminationStatus != 0 && !allowFailure {
                        let last = output.stderr.split(separator: "\n").last.map(String.init) ?? "Falha (\(proc.terminationStatus))."
                        cont.resume(throwing: MediaTools.Failure.failed(last))
                    } else {
                        cont.resume(returning: output)
                    }
                }
                do { try p.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = Data()
        private(set) var out = ""
        private(set) var err = ""

        func appendOut(_ d: Data, flush: Bool = false) -> [String] {
            lock.lock(); defer { lock.unlock() }
            partial.append(d)
            var lines: [String] = []
            while let nl = partial.firstIndex(of: 0x0A) {
                let line = String(decoding: partial.subdata(in: partial.startIndex..<nl), as: UTF8.self)
                partial.removeSubrange(partial.startIndex...nl)
                out += line + "\n"
                lines.append(line.trimmingCharacters(in: .whitespaces))
            }
            if flush, !partial.isEmpty {
                let line = String(decoding: partial, as: UTF8.self)
                partial.removeAll()
                out += line
                lines.append(line)
            }
            return lines
        }

        func appendErr(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            err += String(decoding: d, as: UTF8.self)
        }
    }
}
