import Foundation
import Observation

struct EngineProgress: Equatable {
    var fraction: Double
    var label: String
}

enum EngineError: LocalizedError {
    case unavailable(String)
    case failed(String)
    case crashed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): "Motor de IA indisponível: \(why)"
        case .failed(let message): message
        case .crashed: "O motor de IA parou inesperadamente. Veja o log em ~/Library/Logs/MusicSplit."
        case .cancelled: "Cancelado."
        }
    }
}

/// Processo Python do motor, falando JSON por linha no stdin/stdout.
/// Um pedido por vez é processado pelo motor; os demais esperam na fila do próprio stdin.
@MainActor
@Observable
final class EngineClient {
    enum State: Equatable { case stopped, starting, ready, failed(String) }

    private(set) var state: State = .stopped
    private(set) var device = ""

    private var process: Process?
    private var input: FileHandle?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var pending: [String: Pending] = [:]
    private var cancelling = false

    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let progress: ((EngineProgress) -> Void)?
    }

    var isBusy: Bool { !pending.isEmpty }

    func start() {
        guard process == nil else { return }
        guard let python = Toolchain.python, let engineDir = Toolchain.engineDir else {
            state = .failed("Python do motor não encontrado")
            return
        }
        state = .starting
        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "splitter_engine"]
        p.currentDirectoryURL = Toolchain.supportDir
        var env = Toolchain.toolEnvironment
        env["PYTHONPATH"] = engineDir.path
        env["PYTHONNOUSERSITE"] = "1"
        env["SPLITTER_MODELS_DIR"] = Toolchain.modelsDir.path
        if Toolchain.isBundled { env["PYTHONDONTWRITEBYTECODE"] = "1" }
        if let bundled = Toolchain.bundledModels {
            env["SPLITTER_MODELS_BUNDLED"] = bundled.path
        } else if let dev = UserDefaults.standard.string(forKey: "DevModelsPath") {
            env["SPLITTER_MODELS_BUNDLED"] = dev
        }
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "0"
        p.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = Self.logHandle()

        let buffer = LineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            for line in buffer.append(chunk) {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let message = UncheckedMessage(obj)
                DispatchQueue.main.async { self?.handle(message.value) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { self?.terminated(status: status) }
        }
        do {
            try p.run()
            process = p
            input = stdinPipe.fileHandleForWriting
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func waitUntilReady() async throws {
        if state == .ready { return }
        if process == nil { start() }
        if case .failed(let why) = state { throw EngineError.unavailable(why) }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    /// Envia um pedido e espera o resultado (JSON do campo "result").
    func call(_ method: String, _ params: [String: Any] = [:], progress: ((EngineProgress) -> Void)? = nil) async throws -> Data {
        try await waitUntilReady()
        let id = UUID().uuidString
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = Pending(continuation: cont, progress: progress)
            do {
                try input?.write(contentsOf: data + Data([0x0A]))
            } catch {
                pending[id] = nil
                cont.resume(throwing: EngineError.crashed)
            }
        }
    }

    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as: T.Type,
                            progress: ((EngineProgress) -> Void)? = nil) async throws -> T {
        let data = try await call(method, params, progress: progress)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Cancela tudo encerrando o processo; o próximo pedido sobe um motor novo.
    func cancelAll() {
        guard let process, process.isRunning else { return }
        cancelling = true
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
    }

    func shutdown() {
        guard let process, process.isRunning else { return }
        if let data = try? JSONSerialization.data(withJSONObject: ["method": "shutdown"]) {
            try? input?.write(contentsOf: data + Data([0x0A]))
        }
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { kill(pid, SIGKILL) }
    }

    // MARK: - Mensagens

    private func handle(_ msg: [String: Any]) {
        if let event = msg["event"] as? String {
            if event == "ready" {
                state = .ready
                device = msg["device"] as? String ?? ""
                let waiters = readyWaiters
                readyWaiters.removeAll()
                waiters.forEach { $0.resume() }
                return
            }
            if event == "progress", let id = msg["id"] as? String, let p = pending[id] {
                let fraction = (msg["fraction"] as? NSNumber)?.doubleValue ?? 0
                p.progress?(EngineProgress(fraction: fraction, label: msg["label"] as? String ?? ""))
            }
            return
        }
        guard let id = msg["id"] as? String, let p = pending.removeValue(forKey: id) else { return }
        if let error = msg["error"] as? [String: Any] {
            p.continuation.resume(throwing: EngineError.failed(Self.friendly(error["message"] as? String ?? "Falha no motor.")))
        } else {
            let result = msg["result"] ?? [:]
            let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
            p.continuation.resume(returning: data)
        }
    }

    private func terminated(status: Int32) {
        process = nil
        input = nil
        let error: EngineError = cancelling ? .cancelled : .crashed
        cancelling = false
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.continuation.resume(throwing: error) }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
        state = .stopped
    }

    private static func friendly(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("out of memory") || message.contains("MPS backend out of memory") {
            return "Memória insuficiente para este arquivo. Feche outros apps ou use a qualidade Rápida."
        }
        if message.localizedCaseInsensitiveContains("No such file") { return "Arquivo não encontrado." }
        return message
    }

    private static func logHandle() -> FileHandle {
        let url = Toolchain.logsDir.appending(path: "engine.log")
        let fm = FileManager.default
        try? fm.createDirectory(at: Toolchain.logsDir, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("old.log"))
            try? fm.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("old.log"))
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = (try? FileHandle(forWritingTo: url)) ?? FileHandle.standardError
        _ = try? handle.seekToEnd()
        return handle
    }
}

/// Junta pedaços do stdout e devolve linhas completas (chamado só pela thread do readabilityHandler).
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(data.subdata(in: data.startIndex..<nl))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }
}

/// Dicionário JSON atravessando threads (só leitura).
private struct UncheckedMessage: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
