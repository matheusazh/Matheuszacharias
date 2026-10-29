import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

/// Estado raiz: biblioteca, motor, fila, player e seleção.
@MainActor
@Observable
final class AppModel {
    enum Selection: Hashable {
        case project(UUID)
        case job(UUID)
    }

    struct ImportRequest: Identifiable {
        let id = UUID()
        var sources: [Job.Source]
        var suggested: ProjectKind?
    }

    let library = LibraryStore()
    let engine = EngineClient()
    let player = PlaybackEngine()
    let queue: JobQueue

    var selection: Selection? {
        didSet { if oldValue != selection { selectionChanged() } }
    }
    var importRequest: ImportRequest?
    var showOpening = !UserDefaults.standard.bool(forKey: "skipOpening")
    var showLyrics = false
    var lyricsWork: LyricsWork?
    var exportRequest: UUID?
    /// Posição sob o dedo enquanto se arrasta na linha do tempo (o cursor segue 1:1; o áudio pula ao soltar).
    var scrubTime: Double?
    /// Janela principal (os atalhos de uma tecla só valem nela).
    weak var mainWindow: NSWindow?
    var alert: String?

    struct LyricsWork: Equatable {
        var projectID: UUID
        var stage: String
        var fraction: Double
        var error: String?
    }

    private var saveTask: Task<Void, Never>?

    init() {
        queue = JobQueue(engine: engine, library: library)
        queue.onFinished = { [weak self] project in
            guard let self else { return }
            // abre o resultado se o usuário estava olhando o processamento
            if case .job = self.selection { self.selection = .project(project.id) }
            if self.selection == nil { self.selection = .project(project.id) }
            NSApp.requestUserAttention(.informationalRequest)
            self.updateBadge()
        }
        queue.onChange = { [weak self] in self?.updateBadge() }
        // tirar a quarentena de milhares de arquivos do Python leva alguns segundos na 1ª abertura:
        // fora da main thread, e o motor só sobe depois
        Task.detached(priority: .userInitiated) { [engine] in
            Toolchain.prepare()
            await MainActor.run { engine.start() }
        }
    }

    var currentProject: Project? {
        if case .project(let id) = selection { return library.project(id) }
        return nil
    }

    var currentJob: Job? {
        if case .job(let id) = selection { return queue.jobs.first { $0.id == id } }
        return nil
    }

    // MARK: - Importar

    func requestImport(urls: [URL]) {
        let media = urls.filter { MediaTools.isMedia($0) }
        guard !media.isEmpty else {
            alert = "Esse tipo de arquivo não é suportado. Use áudio (MP3, WAV, M4A, FLAC…) ou vídeo (MP4, MOV…)."
            return
        }
        importRequest = ImportRequest(sources: media.map { .file($0) }, suggested: nil)
        let first = media[0]
        Task {
            let kind = await KindDetector.detect(url: first)
            if importRequest?.sources.first == .file(first) { importRequest?.suggested = kind }
        }
    }

    func requestImport(link: String) {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MediaTools.looksLikeLink(t) else {
            alert = "Isso não parece um link. Copie o endereço do vídeo ou da música e tente de novo."
            return
        }
        importRequest = ImportRequest(sources: [.link(t)], suggested: nil)
    }

    func pasteLink() {
        guard let s = NSPasteboard.general.string(forType: .string) else {
            alert = "A área de transferência está vazia."
            return
        }
        if let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), url.isFileURL {
            requestImport(urls: [url])
        } else {
            requestImport(link: s)
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Separar"
        panel.message = "Escolha áudios ou vídeos"
        if panel.runModal() == .OK { requestImport(urls: panel.urls) }
    }

    func confirmImport(kind: ProjectKind, separation: SeparationOptions, speech: SpeechOptions) {
        guard let request = importRequest else { return }
        importRequest = nil
        UserDefaults.standard.set(kind.rawValue, forKey: "lastKind")
        var first: Job?
        for source in request.sources {
            let job = Job(source: source, kind: kind, separation: separation, speech: speech)
            queue.enqueue(job)
            if first == nil { first = job }
        }
        if let first, currentProject == nil || request.sources.count == 1 { selection = .job(first.id) }
        updateBadge()
    }

    func updateBadge() {
        let n = queue.activeCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: - Projeto aberto

    private func selectionChanged() {
        showLyrics = false
        guard let project = currentProject else {
            player.unload()
            return
        }
        guard player.projectID != project.id else { return }
        loadPlayer(project)
    }

    func loadPlayer(_ project: Project) {
        var sources: [PlaybackEngine.Source] = []
        switch project.kind {
        case .music:
            for s in project.stems {
                sources.append(.init(id: s.id, url: library.stemURL(s, in: project), gain: s.gain, route: .stems))
            }
            if let analysis = project.analysis, !analysis.beats.isEmpty, let frames = mixFrames(project),
               let click = ClickTrack.file(for: analysis, frames: frames, cacheDir: library.folder(for: project.id).appending(path: "cache")) {
                sources.append(.init(id: "click", url: click, gain: 1, route: .click))
            }
        case .speech:
            sources.append(.init(id: "mix", url: library.mixURL(for: project.id), gain: 1, route: .direct))
            for s in project.stems {
                sources.append(.init(id: s.id, url: library.stemURL(s, in: project), gain: s.gain, route: .stems))
            }
        }
        player.load(projectID: project.id, sources: sources, duration: project.duration)
        applyPlayerState(project)
    }

    private func mixFrames(_ project: Project) -> AVAudioFrameCount? {
        guard let first = project.stems.first,
              let file = try? AVAudioFile(forReading: library.stemURL(first, in: project)) else { return nil }
        return AVAudioFrameCount(file.length)
    }

    /// Aplica o estado salvo do projeto no player (volumes, tom, velocidade, loop, metrônomo).
    func applyPlayerState(_ project: Project) {
        switch project.kind {
        case .music:
            let m = project.mix
            var volumes: [String: Float] = [:]
            let anySolo = !m.soloed.isEmpty
            for s in project.stems {
                var v = Float(m.volume(s.id))
                if m.muted.contains(s.id) || (anySolo && !m.soloed.contains(s.id)) { v = 0 }
                volumes[s.id] = v
            }
            volumes["click"] = m.metronome ? Float(m.metronomeVolume) : 0
            player.setVolumes(volumes)
            player.pitchSemitones = m.pitch
            player.rate = m.speed
            if let a = m.loopStart, let b = m.loopEnd, b > a { player.loop = a...b } else { player.loop = nil }
            player.loopEnabled = m.loopOn
            player.countIn = m.countIn
            if let analysis = project.analysis {
                player.countInBeats = max(2, min(7, analysis.meter))
                player.countInBeatInterval = analysis.bpm.map { 60 / $0 } ?? 0.5
            }
            player.makeupGain = 0
        case .speech:
            let s = project.speech
            var volumes: [String: Float] = [:]
            if s.compareOriginal {
                volumes["mix"] = 1
            } else {
                volumes["voice_raw"] = Float(1 - s.intensity)
                volumes["voice"] = Float(s.intensity)
                volumes["background"] = Float(s.background)
            }
            player.setVolumes(volumes)
            player.pitchSemitones = 0
            player.rate = 1
            player.loopEnabled = false
            player.makeupGain = s.compareOriginal ? 0 : speechMakeup(project)
        }
    }

    /// Estima o ganho para chegar no loudness alvo, a partir das medições do motor.
    func speechMakeup(_ project: Project) -> Double {
        guard let target = project.speech.loudness.lufs else { return 0 }
        let voice = project.loudness["voice"] ?? project.loudness["voice_raw"]
        guard let voice else { return 0 }
        var energy = pow(10, voice / 10)
        if let bg = project.loudness["background"], project.speech.background > 0 {
            energy += pow(project.speech.background, 2) * pow(10, bg / 10)
        }
        let current = 10 * log10(energy)
        return max(-12, min(18, target - current))
    }

    func updateMix(_ change: (inout MixState) -> Void) {
        guard let project = currentProject else { return }
        var p = project
        change(&p.mix)
        guard p.mix != project.mix else { return }
        library.updateInMemory(p)
        applyPlayerState(p)
        scheduleSave(p.id)
    }

    func updateSpeech(_ change: (inout SpeechState) -> Void) {
        guard let project = currentProject else { return }
        var p = project
        change(&p.speech)
        guard p.speech != project.speech else { return }
        library.updateInMemory(p)
        applyPlayerState(p)
        scheduleSave(p.id)
    }

    func updateProject(_ id: UUID, _ change: (inout Project) -> Void) {
        library.update(id, change)
    }

    /// Edita as partes da música. Durante um arraste, `save: false` mexe só na memória.
    func editSections(_ id: UUID, save: Bool, _ change: (inout [SongSection]) -> Void) {
        guard var p = library.project(id), p.analysis != nil else { return }
        change(&p.analysis!.sections)
        if save { library.save(p) } else { library.updateInMemory(p) }
    }

    private func scheduleSave(_ id: UUID) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let p = self.library.project(id) else { return }
            self.library.save(p)
        }
    }

    func deleteProject(_ id: UUID) {
        if player.projectID == id { player.unload() }
        if selection == .project(id) { selection = nil }
        library.delete(id)
    }

    // MARK: - Letra

    func transcribeLyrics(for project: Project) {
        guard lyricsWork == nil || lyricsWork?.error != nil else { return }
        // o motor faz um pedido por vez: se a fila está processando, a letra espera a vez
        let waiting = queue.running.map { "Na fila: esperando terminar \"\($0.title)\"" } ?? "Preparando"
        lyricsWork = LyricsWork(projectID: project.id, stage: waiting, fraction: 0)
        let vocal = project.stems.first { $0.id == "lead" } ?? project.stems.first { $0.id == "vocals" }
        guard let vocal else {
            lyricsWork?.error = "Essa música não tem faixa de voz."
            return
        }
        let url = library.stemURL(vocal, in: project)
        Task {
            do {
                let status = try JSONSerialization.jsonObject(with: try await engine.call("status")) as? [String: Any]
                if (status?["whisper"] as? Bool) != true {
                    lyricsWork?.stage = "Baixando modelo de letra (~1,5 GB, só na primeira vez)"
                    _ = try await engine.call("download_lyrics_model") { p in
                        self.lyricsWork?.fraction = p.fraction * 0.5
                    }
                }
                lyricsWork?.stage = "Transcrevendo"
                let result = try await engine.call("transcribe", ["input": url.path], as: LyricsResult.self) { p in
                    self.lyricsWork?.fraction = 0.5 + p.fraction * 0.5
                }
                library.update(project.id) { $0.lyrics = result.lines }
                lyricsWork = nil
            } catch {
                lyricsWork?.error = error.localizedDescription
            }
        }
    }
}
