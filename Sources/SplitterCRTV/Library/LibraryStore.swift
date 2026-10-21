import AppKit
import Observation

/// Biblioteca em ~/Music/SplitterCRTV/Biblioteca/<id>/ com project.json, mix.flac, stems/ e peaks/.
@Observable
final class LibraryStore {
    private(set) var projects: [Project] = []

    static let defaultRoot = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appending(path: "SplitterCRTV", directoryHint: .isDirectory)

    var root: URL {
        if let custom = UserDefaults.standard.string(forKey: "libraryPath"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return Self.defaultRoot
    }

    var libraryDir: URL { root.appending(path: "Biblioteca", directoryHint: .isDirectory) }

    init() { reload() }

    func folder(for id: UUID) -> URL { libraryDir.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func stemsDir(for id: UUID) -> URL { folder(for: id).appending(path: "stems", directoryHint: .isDirectory) }
    func peaksDir(for id: UUID) -> URL { folder(for: id).appending(path: "peaks", directoryHint: .isDirectory) }
    func mixURL(for id: UUID) -> URL { folder(for: id).appending(path: "mix.flac") }
    func stemURL(_ stem: StemInfo, in project: Project) -> URL { stemsDir(for: project.id).appending(path: stem.file) }

    func videoURL(for project: Project) -> URL? {
        guard let path = project.videoPath else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder(for: project.id).appending(path: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Project] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for dir in dirs where dir.hasDirectoryPath {
            let file = dir.appending(path: "project.json")
            guard let data = try? Data(contentsOf: file) else {
                // pasta de um processamento interrompido
                if (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    .map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                    try? fm.removeItem(at: dir)
                }
                continue
            }
            do { loaded.append(try decoder.decode(Project.self, from: data)) } catch {
                NSLog("SplitterCRTV: projeto ilegível em \(dir.path): \(error)")
            }
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func projects(of kind: ProjectKind) -> [Project] { projects.filter { $0.kind == kind } }

    func add(_ project: Project) {
        save(project)
        projects.insert(project, at: 0)
    }

    /// Grava e atualiza a lista. Chamado a cada mudança de mixer (com debounce pelo chamador).
    func save(_ project: Project) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder(for: project.id), withIntermediateDirectories: true)
            try encoder.encode(project).write(to: folder(for: project.id).appending(path: "project.json"), options: .atomic)
        } catch {
            NSLog("SplitterCRTV: falha ao salvar projeto: \(error)")
        }
        if let i = projects.firstIndex(where: { $0.id == project.id }) { projects[i] = project }
    }

    /// Atualiza só na memória (a gravação em disco é agrupada pelo AppModel).
    func updateInMemory(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i] = project
    }

    func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard var p = project(id) else { return }
        change(&p)
        save(p)
    }

    func rename(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update(id) { $0.title = clean }
    }

    /// Vai para o Lixo (dá para recuperar no Finder).
    func delete(_ id: UUID) {
        let dir = folder(for: id)
        NSWorkspace.shared.recycle([dir]) { _, _ in }
        projects.removeAll { $0.id == id }
    }

    func reveal(_ id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([folder(for: id)])
    }
}
