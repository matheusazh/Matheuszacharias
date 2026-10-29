import Foundation

/// Picos das formas de onda por projeto (carregados uma vez, ~100 bytes por segundo por faixa).
@MainActor
enum PeaksCache {
    private static var store: [String: [Float]] = [:]

    static func peaks(_ project: Project, _ id: String, library: LibraryStore) -> [Float] {
        let key = "\(project.id.uuidString)/\(id)"
        if let p = store[key] { return p }
        let p = Waveform.load(library.peaksDir(for: project.id).appending(path: "\(id).peaks"))
        if !p.isEmpty { store[key] = p }
        return p
    }

    static func clear(_ projectID: UUID) {
        store = store.filter { !$0.key.hasPrefix(projectID.uuidString) }
    }
}
