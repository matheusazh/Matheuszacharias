import AVFoundation
import Observation

/// Toca as faixas de um projeto em sincronia, com tom/velocidade, loop A-B, metrônomo e contagem.
///
/// Grafo: faixas → stemBus → timePitch → makeup → limiter → saída
///        click → clickPitch (mesma velocidade, tom fixo) → saída
///        original (fala, "Antes") e contagem → saída direto
@MainActor
@Observable
final class PlaybackEngine {
    enum Route { case stems, click, direct }

    private struct Track {
        let id: String
        let file: AVAudioFile
        let player: AVAudioPlayerNode
        let boost: AVAudioUnitEQ?
        let route: Route
    }

    private(set) var projectID: UUID?
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// Posição publicada ~10x/s (rótulos de tempo). Playhead usa `position()` num TimelineView.
    private(set) var currentTime: Double = 0
    private(set) var loadError: String?

    private let engine = AVAudioEngine()
    private let stemBus = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let clickPitch = AVAudioUnitTimePitch()
    private let makeup = AVAudioUnitEQ(numberOfBands: 0)
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private let countInPlayer = AVAudioPlayerNode()

    private var tracks: [Track] = []
    private var targetVolumes: [String: Float] = [:]
    private let scheduler = LoopScheduler()
    private var sampleRate: Double = 44100
    private var totalFrames: AVAudioFramePosition = 0
    private var startFrame: AVAudioFramePosition = 0
    private var firstSegmentFrames: AVAudioFramePosition = 0
    private var loopFrames: (start: AVAudioFramePosition, end: AVAudioFramePosition)?
    private var pausedAt: Double = 0
    private var ticker: Timer?
    private var configObserver: NSObjectProtocol?

    /// Mudar o trecho enquanto toca (arrastando as alças) reagenda com um pequeno atraso,
    /// para não reiniciar os players a cada evento do arraste.
    var loop: ClosedRange<Double>? {
        didSet {
            guard oldValue != loop, isPlaying else { return }
            loopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reschedule() } }
            loopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
    private var loopWork: DispatchWorkItem?
    var loopEnabled = false { didSet { if oldValue != loopEnabled, isPlaying { reschedule() } } }
    var countIn = false
    var countInBeatInterval: Double = 0.5
    var countInBeats = 4

    init() {
        engine.attach(stemBus)
        engine.attach(timePitch)
        engine.attach(clickPitch)
        engine.attach(makeup)
        engine.attach(limiter)
        engine.attach(countInPlayer)
        timePitch.overlap = 12
        clickPitch.overlap = 8
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        engine.connect(stemBus, to: timePitch, format: format)
        engine.connect(timePitch, to: makeup, format: format)
        engine.connect(makeup, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        engine.connect(clickPitch, to: engine.mainMixerNode, format: ClickTrack.monoFormat)
        engine.connect(countInPlayer, to: engine.mainMixerNode, format: ClickTrack.monoFormat)
        engine.prepare()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    // MARK: - Carregar

    struct Source {
        let id: String
        let url: URL
        let gain: Double
        let route: Route
    }

    func load(projectID: UUID, sources: [Source], duration: Double) {
        stop()
        for t in tracks {
            engine.detach(t.player)
            if let b = t.boost { engine.detach(b) }
        }
        tracks.removeAll()
        loadError = nil
        self.projectID = projectID
        pausedAt = 0
        currentTime = 0
        for s in sources {
            do {
                let file = try AVAudioFile(forReading: s.url)
                let player = AVAudioPlayerNode()
                engine.attach(player)
                let format = file.processingFormat
                let destination: AVAudioNode = switch s.route {
                case .stems: stemBus
                case .click: clickPitch
                case .direct: engine.mainMixerNode
                }
                var boost: AVAudioUnitEQ?
                if s.gain > 1.0001 {
                    let eq = AVAudioUnitEQ(numberOfBands: 0)
                    eq.globalGain = Float(20 * log10(s.gain))
                    engine.attach(eq)
                    engine.connect(player, to: eq, format: format)
                    engine.connect(eq, to: destination, format: format)
                    boost = eq
                } else {
                    engine.connect(player, to: destination, format: format)
                }
                player.volume = 0
                tracks.append(Track(id: s.id, file: file, player: player, boost: boost, route: s.route))
                sampleRate = format.sampleRate
            } catch {
                loadError = "Não consegui abrir \(s.url.lastPathComponent)."
                NSLog("SplitterCRTV: \(error)")
            }
        }
        totalFrames = tracks.filter { $0.route != .click }.map(\.file.length).max() ?? 0
        self.duration = totalFrames > 0 ? Double(totalFrames) / sampleRate : duration
        scheduler.set(tracks: tracks.map { LoopScheduler.Entry(player: $0.player, file: $0.file) })
        applyVolumes(immediate: true)
    }

    func unload() {
        stop()
        projectID = nil
    }

    // MARK: - Transporte

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !tracks.isEmpty, !isPlaying else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            loadError = "Saída de áudio indisponível."
            return
        }
        if pausedAt >= duration - 0.05 { pausedAt = 0 }
        isPlaying = true
        schedule(from: pausedAt, withCountIn: countIn)
        startTicker()
    }

    func pause() {
        guard isPlaying else { return }
        pausedAt = position()
        currentTime = pausedAt
        stopPlayers()
        isPlaying = false
        ticker?.invalidate()
    }

    func stop() {
        stopPlayers()
        isPlaying = false
        ticker?.invalidate()
    }

    func seek(to time: Double) {
        let t = min(max(0, time), max(0, duration - 0.01))
        pausedAt = t
        currentTime = t
        if isPlaying { schedule(from: t, withCountIn: false) }
    }

    func skip(_ seconds: Double) { seek(to: position() + seconds) }

    /// Tempo para a interface: tocando, lê o relógio de render; parado, lê `currentTime`
    /// (observável, então um salto com o player parado já redesenha cursor e rótulos).
    func displayTime() -> Double { isPlaying ? position() : currentTime }

    /// Posição atual em segundos (lida do relógio de render; barata o bastante para 120 Hz).
    func position() -> Double {
        guard isPlaying, let ref = tracks.first(where: { $0.route != .click }),
              let nodeTime = ref.player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = ref.player.playerTime(forNodeTime: nodeTime) else { return pausedAt }
        let played = max(0, playerTime.sampleTime)
        if played < firstSegmentFrames { return Double(startFrame + played) / sampleRate }
        guard let loop = loopFrames, loop.end > loop.start else {
            return min(duration, Double(startFrame + played) / sampleRate)
        }
        let length = loop.end - loop.start
        return Double(loop.start + (played - firstSegmentFrames) % length) / sampleRate
    }

    // MARK: - Mixer

    func setVolumes(_ volumes: [String: Float], immediate: Bool = false) {
        targetVolumes = volumes
        applyVolumes(immediate: immediate)
    }

    var pitchSemitones: Int = 0 { didSet { timePitch.pitch = Float(pitchSemitones * 100) } }
    var rate: Double = 1 {
        didSet {
            timePitch.rate = Float(rate)
            clickPitch.rate = Float(rate)
        }
    }
    /// Ganho de loudness na prévia da fala (dB).
    var makeupGain: Double = 0 { didSet { makeup.globalGain = Float(max(-24, min(24, makeupGain))) } }

    private func applyVolumes(immediate: Bool) {
        for t in tracks {
            let target = targetVolumes[t.id] ?? 0
            if immediate || !isPlaying || abs(t.player.volume - target) < 0.02 {
                t.player.volume = target
            } else {
                ramp(t.player, to: target)
            }
        }
    }

    /// Rampa curta (≈40 ms) para mudo/solo não estalarem.
    private func ramp(_ player: AVAudioPlayerNode, to target: Float) {
        let start = player.volume
        let steps = 8
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5 * i)) {
                player.volume = start + (target - start) * Float(i) / Float(steps)
            }
        }
    }

    // MARK: - Agendamento

    private func reschedule() {
        schedule(from: position(), withCountIn: false)
    }

    private func schedule(from time: Double, withCountIn: Bool) {
        stopPlayers()
        var from = AVAudioFramePosition(max(0, time) * sampleRate)
        loopFrames = nil
        if loopEnabled, let loop, loop.upperBound - loop.lowerBound > 0.05 {
            let a = AVAudioFramePosition(loop.lowerBound * sampleRate)
            let b = min(totalFrames, AVAudioFramePosition(loop.upperBound * sampleRate))
            if b > a {
                loopFrames = (a, b)
                if from < a || from >= b { from = a }
            }
        }
        from = min(from, max(0, totalFrames - 1))
        let end = loopFrames?.end ?? totalFrames
        startFrame = from
        firstSegmentFrames = max(0, end - from)
        scheduler.schedule(from: from, end: end, loop: loopFrames)

        let lead = AVAudioTime.hostTime(forSeconds: 0.05)
        var start = mach_absolute_time() + lead
        if withCountIn, countInBeats > 0,
           let buffer = ClickTrack.countIn(beats: countInBeats, interval: countInBeatInterval / max(0.25, rate)) {
            countInPlayer.scheduleBuffer(buffer, at: nil)
            countInPlayer.volume = 0.9
            countInPlayer.play(at: AVAudioTime(hostTime: start))
            start += AVAudioTime.hostTime(forSeconds: Double(buffer.frameLength) / ClickTrack.sampleRate)
        }
        let when = AVAudioTime(hostTime: start)
        for t in tracks { t.player.play(at: when) }
    }

    private func stopPlayers() {
        scheduler.invalidate()
        for t in tracks { t.player.stop() }
        countInPlayer.stop()
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard isPlaying else { return }
        let t = position()
        currentTime = t
        if loopFrames == nil, t >= duration - 0.02 {
            stop()
            pausedAt = 0
            currentTime = 0
        }
    }

    private func handleConfigurationChange() {
        let wasPlaying = isPlaying
        let t = position()
        stop()
        pausedAt = t
        if wasPlaying { play() }
    }
}

/// Agenda os segmentos em todos os players e mantém o loop sempre dois ciclos à frente.
/// Os callbacks de fim de segmento chegam em threads do áudio, por isso a trava.
final class LoopScheduler: @unchecked Sendable {
    struct Entry {
        let player: AVAudioPlayerNode
        let file: AVAudioFile
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var generation = 0
    private var loop: (start: AVAudioFramePosition, end: AVAudioFramePosition)?

    func set(tracks: [Entry]) {
        lock.lock(); entries = tracks; generation += 1; lock.unlock()
    }

    func invalidate() {
        lock.lock(); generation += 1; lock.unlock()
    }

    func schedule(from: AVAudioFramePosition, end: AVAudioFramePosition, loop: (start: AVAudioFramePosition, end: AVAudioFramePosition)?) {
        lock.lock()
        generation += 1
        let gen = generation
        self.loop = loop
        let list = entries
        lock.unlock()
        for e in list {
            let fileEnd = min(end, e.file.length)
            if fileEnd > from {
                e.player.scheduleSegment(e.file, startingFrame: from, frameCount: AVAudioFrameCount(fileEnd - from), at: nil)
            }
            if loop != nil {
                scheduleIteration(e, generation: gen)
                scheduleIteration(e, generation: gen)
            }
        }
    }

    private func scheduleIteration(_ e: Entry, generation gen: Int) {
        lock.lock()
        let current = generation
        let loop = self.loop
        lock.unlock()
        guard gen == current, let loop else { return }
        let end = min(loop.end, e.file.length)
        guard end > loop.start else { return }
        e.player.scheduleSegment(e.file, startingFrame: loop.start, frameCount: AVAudioFrameCount(end - loop.start),
                                 at: nil, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.scheduleIteration(e, generation: gen)
        }
    }
}
