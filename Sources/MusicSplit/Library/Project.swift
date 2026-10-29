import Foundation

// MARK: - Projeto (uma música ou uma fala processada)

enum ProjectKind: String, Codable, CaseIterable, Identifiable {
    case music, speech
    var id: String { rawValue }
    var title: String { self == .music ? "Música" : "Fala" }
    var plural: String { self == .music ? "Músicas" : "Falas" }
    var symbol: String { self == .music ? "music.note" : "waveform.and.mic" }
}

enum Quality: String, Codable, CaseIterable, Identifiable {
    case max, fast
    var id: String { rawValue }
    var title: String { self == .max ? "Máxima" : "Rápida" }
    var engineValue: String { rawValue }
}

struct SeparationOptions: Codable, Hashable {
    var stems: Int = 4          // 2, 4 ou 6
    var backing: Bool = false   // separar voz principal × backing
    var quality: Quality = .max
}

struct SpeechOptions: Codable, Hashable {
    var denoise: Bool = true
    var dereverb: Bool = true
}

struct StemInfo: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var file: String
    var gain: Double
    var silent: Bool
}

struct ChordSegment: Codable, Hashable {
    var start: Double
    var end: Double
    var label: String
}

struct SongSection: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var label: String

    enum CodingKeys: String, CodingKey { case start, end, label }
}

struct KeyInfo: Codable, Hashable {
    var tonic: String
    var mode: String       // "major" | "minor"
    var pitchClass: Int
    var confidence: Double

    var isMinor: Bool { mode == "minor" }

    /// Tom escolhido à mão (correção do detectado).
    static func manual(pitchClass: Int, minor: Bool) -> KeyInfo {
        let pc = (pitchClass % 12 + 12) % 12
        let tonic = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"][pc]
        return KeyInfo(tonic: tonic, mode: minor ? "minor" : "major", pitchClass: pc, confidence: 1)
    }

    func same(as other: KeyInfo) -> Bool { pitchClass == other.pitchClass && mode == other.mode }
}

struct Analysis: Codable {
    var beats: [Double]
    var downbeats: [Double]
    var bpm: Double?
    var meter: Int
    var chords: [ChordSegment]
    var key: KeyInfo?
    var sections: [SongSection]
    var duration: Double
}

struct LyricWord: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

struct LyricLine: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var words: [LyricWord]

    enum CodingKeys: String, CodingKey { case start, end, text, words }
}

enum LoudnessTarget: String, Codable, CaseIterable, Identifiable {
    case podcast, social, off
    var id: String { rawValue }
    var lufs: Double? { self == .podcast ? -16 : self == .social ? -14 : nil }
    var title: String {
        switch self {
        case .podcast: "Podcast (-16 LUFS)"
        case .social: "Redes sociais (-14 LUFS)"
        case .off: "Não nivelar"
        }
    }
    var short: String { self == .podcast ? "-16 LUFS" : self == .social ? "-14 LUFS" : "Original" }
}

/// Estado do mixer da música (salvo com o projeto).
struct MixState: Codable, Equatable {
    var volumes: [String: Double] = [:]
    var muted: Set<String> = []
    var soloed: Set<String> = []
    var pitch: Int = 0              // semitons
    var speed: Double = 1.0
    var loopStart: Double?
    var loopEnd: Double?
    var loopOn: Bool = false
    var metronome: Bool = false
    var metronomeVolume: Double = 0.7
    var countIn: Bool = false

    func volume(_ id: String) -> Double { volumes[id] ?? 1.0 }
}

/// Estado do editor de fala.
struct SpeechState: Codable, Equatable {
    var intensity: Double = 1.0     // 0 = só a voz isolada, 1 = voz limpa (sem ruído/eco)
    var background: Double = 0.0    // 0 = sem trilha, 1 = trilha no volume original
    var loudness: LoudnessTarget = .podcast
    var compareOriginal = false     // "Antes"
}

struct Project: Codable, Identifiable {
    var id: UUID
    var title: String
    var kind: ProjectKind
    var createdAt: Date
    var duration: Double
    var sourceName: String
    var sourceURL: String?
    var videoPath: String?          // vídeo original, para devolver com o áudio novo
    var separation: SeparationOptions?
    var speechOptions: SpeechOptions?
    var stems: [StemInfo]
    var loudness: [String: Double] = [:]
    var analysis: Analysis?
    /// Tom corrigido pelo usuário; nil = usa o detectado. Sobrevive a uma nova análise.
    var keyOverride: KeyInfo?
    var lyrics: [LyricLine]?
    var mix = MixState()
    var speech = SpeechState()

    var hasVideo: Bool { videoPath != nil }

    /// Tom em uso: o corrigido pelo usuário ou o detectado.
    var key: KeyInfo? { keyOverride ?? analysis?.key }

    var subtitle: String {
        let time = Formatters.duration(duration)
        switch kind {
        case .music:
            let count = stems.filter { !$0.silent }.count
            return "\(count) faixas · \(time)"
        case .speech:
            return (hasVideo ? "Vídeo · " : "") + time
        }
    }
}

enum Formatters {
    static func duration(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded(.down))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func precise(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00.0" }
        let s = Int(t)
        return String(format: "%d:%02d.%d", s / 60, s % 60, Int((t - Double(s)) * 10))
    }
}
