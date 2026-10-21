import Foundation

/// Converte rótulos do detector ("A:min7/b7", "G:maj/3", "N") em cifra brasileira ("Am7/G", "G/B").
enum ChordFormatter {
    struct Chord {
        var root: Int
        var quality: String
        var bass: Int?
    }

    private static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let flats = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    private static let solfege = ["Dó", "Dó#", "Ré", "Ré#", "Mi", "Fá", "Fá#", "Sol", "Sol#", "Lá", "Lá#", "Si"]
    private static let pitch: [String: Int] = [
        "C": 0, "B#": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "Fb": 4, "E#": 5, "F": 5,
        "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11, "Cb": 11,
    ]
    private static let degree: [String: Int] = [
        "1": 0, "b2": 1, "2": 2, "#2": 3, "b3": 3, "3": 4, "4": 5, "#4": 6, "b5": 6, "5": 7,
        "#5": 8, "b6": 8, "6": 9, "bb7": 9, "b7": 10, "7": 11, "b9": 1, "9": 2, "#9": 3, "11": 5, "#11": 6, "13": 9,
    ]
    private static let suffix: [String: String] = [
        "maj": "", "min": "m", "7": "7", "maj7": "7M", "min7": "m7", "dim": "°", "dim7": "°7",
        "hdim7": "m7(b5)", "aug": "+", "sus4": "sus4", "sus2": "sus2", "9": "7(9)", "maj9": "7M(9)",
        "min9": "m7(9)", "maj6": "6", "min6": "m6", "minmaj7": "m(7M)", "11": "7(11)", "min11": "m7(11)",
        "13": "7(13)", "min13": "m7(13)", "maj13": "7M(13)", "7sus4": "7sus4", "add9": "(9)", "madd9": "m(9)",
    ]

    static func parse(_ label: String) -> Chord? {
        guard label != "N", label != "X", !label.isEmpty else { return nil }
        let parts = label.split(separator: ":", maxSplits: 1).map(String.init)
        guard let root = pitch[parts[0]] else { return nil }
        var quality = parts.count > 1 ? parts[1] : "maj"
        var bass: Int?
        if let slash = quality.firstIndex(of: "/") {
            let deg = String(quality[quality.index(after: slash)...])
            quality = String(quality[..<slash])
            if let d = degree[deg] { bass = (root + d) % 12 }
        }
        if quality.isEmpty { quality = "maj" }
        if quality.hasPrefix("(") { quality = "maj" }
        return Chord(root: root, quality: quality, bass: bass)
    }

    static func isMinor(_ quality: String) -> Bool {
        quality.hasPrefix("min") || quality.hasPrefix("hdim") || quality.hasPrefix("dim")
    }

    static func display(_ label: String, transpose: Int = 0, simple: Bool = false, flats: Bool = false) -> String? {
        guard let c = parse(label) else { return nil }
        let names = flats ? Self.flats : sharps
        let root = names[((c.root + transpose) % 12 + 12) % 12]
        if simple {
            if c.quality.hasPrefix("dim") { return root + "°" }
            if c.quality == "aug" { return root + "+" }
            return root + (isMinor(c.quality) ? "m" : "")
        }
        var text = root + (suffix[c.quality] ?? c.quality)
        if let b = c.bass, b != c.root {
            text += "/" + names[((b + transpose) % 12 + 12) % 12]
        }
        return text
    }

    /// Tonalidades que se escrevem com bemóis.
    static func prefersFlats(tonic pitchClass: Int, minor: Bool) -> Bool {
        let flatMajors: Set<Int> = [5, 10, 3, 8, 1, 6]     // F Bb Eb Ab Db Gb
        let flatMinors: Set<Int> = [2, 7, 0, 5, 10, 3]     // Dm Gm Cm Fm Bbm Ebm
        return minor ? flatMinors.contains(pitchClass) : flatMajors.contains(pitchClass)
    }

    static func keyName(_ key: KeyInfo, transpose: Int = 0) -> String {
        let pc = ((key.pitchClass + transpose) % 12 + 12) % 12
        let minor = key.mode == "minor"
        let names = prefersFlats(tonic: pc, minor: minor) ? flats : sharps
        return names[pc] + (minor ? "m" : "")
    }

    static func keyLongName(_ key: KeyInfo, transpose: Int = 0) -> String {
        let pc = ((key.pitchClass + transpose) % 12 + 12) % 12
        return solfege[pc] + (key.mode == "minor" ? " menor" : " maior")
    }

    static func flats(for key: KeyInfo?, transpose: Int) -> Bool {
        guard let key else { return false }
        let pc = ((key.pitchClass + transpose) % 12 + 12) % 12
        return prefersFlats(tonic: pc, minor: key.mode == "minor")
    }
}
