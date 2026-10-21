import Foundation

/// Onde estão o Python do motor, os modelos e as ferramentas (ffmpeg, yt-dlp, deno).
///
/// No app empacotado tudo fica em Contents/Resources. Rodando do código-fonte (swift run),
/// usa o venv de engine/ e as ferramentas do sistema.
enum Toolchain {
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SplitterCRTV", directoryHint: .isDirectory)
    static let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/SplitterCRTV", directoryHint: .isDirectory)
    static let modelsDir = supportDir.appending(path: "models", directoryHint: .isDirectory)
    static let supportBin = supportDir.appending(path: "bin", directoryHint: .isDirectory)

    static let resources = Bundle.main.resourceURL
    static var bundledPython: URL? { existing(resources?.appending(path: "python/bin/python3")) }
    static var bundledEngine: URL? { existing(resources?.appending(path: "engine")) }
    static var bundledModels: URL? { existing(resources?.appending(path: "models")) }
    static var bundledBin: URL? { existing(resources?.appending(path: "bin")) }

    /// Raiz do repositório quando rodando do código-fonte.
    static let sourceRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static var isBundled: Bool { bundledPython != nil }

    static var python: URL? {
        bundledPython ?? existing(sourceRoot.appending(path: "engine/.venv/bin/python"))
    }

    static var engineDir: URL? {
        bundledEngine ?? existing(sourceRoot.appending(path: "engine"))
    }

    static let systemDirs = UserDefaults.standard.bool(forKey: "ForceBundledTools")
        ? [] : ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin"]

    static var searchDirs: [String] {
        systemDirs + [supportBin.path] + (bundledBin.map { [$0.path] } ?? [])
    }

    static func find(_ tool: String) -> String? {
        searchDirs.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ffmpeg: String? { find("ffmpeg") }
    static var ytdlp: String? { find("yt-dlp") }

    static var toolEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = UserDefaults.standard.bool(forKey: "ForceBundledTools") ? "/usr/bin:/bin" : (env["PATH"] ?? "")
        env["PATH"] = (searchDirs + [inherited]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// Libera da quarentena o que veio no DMG (o usuário já aprovou o app). Sem isso o macOS mata
    /// o Python embutido na hora (assinatura ad-hoc + quarentena). Confere no próprio arquivo, então
    /// uma versão nova instalada por cima também é liberada.
    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        guard let resources, let python = bundledPython else { return }
        let sentinels = [python.resolvingSymlinksInPath().path] + ["ffmpeg", "yt-dlp", "deno"].map { resources.appending(path: "bin/\($0)").path }
        guard sentinels.contains(where: { getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }) else { return }
        for sub in ["bin", "python"] {
            let dir = resources.appending(path: sub)
            removexattr(dir.path, "com.apple.quarantine", 0)
            guard let e = fm.enumerator(atPath: dir.path) else { continue }
            while let rel = e.nextObject() as? String {
                removexattr(dir.appending(path: rel).path, "com.apple.quarantine", XATTR_NOFOLLOW)
            }
        }
    }

    private static func existing(_ url: URL?) -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
