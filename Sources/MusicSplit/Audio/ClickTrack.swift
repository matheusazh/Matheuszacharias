import AVFoundation

/// Metrônomo que segue as batidas detectadas (acento no tempo forte).
enum ClickTrack {
    static let sampleRate = 44100.0

    static var monoFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    /// Um clique curto: senoide com decaimento rápido e um transiente de "madeira".
    static func click(accent: Bool) -> [Float] {
        let n = Int(sampleRate * 0.035)
        let freq = accent ? 1760.0 : 1245.0
        let amp: Float = accent ? 0.9 : 0.6
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let env = Float(exp(-t * 140))
            let tone = Float(sin(2 * .pi * freq * t)) + 0.35 * Float(sin(2 * .pi * freq * 2.01 * t))
            return amp * env * tone * 0.75
        }
    }

    static func render(beats: [Double], downbeats: [Double], frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let frames = max(1, frames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        memset(data, 0, Int(frames) * MemoryLayout<Float>.size)
        let strong = click(accent: true), weak = click(accent: false)
        let downs = Set(downbeats.map { Int(($0 * 100).rounded()) })
        for b in beats {
            let isDown = downs.contains(Int((b * 100).rounded())) || downs.contains(Int((b * 100).rounded()) - 1)
                || downs.contains(Int((b * 100).rounded()) + 1)
            let sound = isDown ? strong : weak
            let start = Int(b * sampleRate)
            for (i, s) in sound.enumerated() where start + i < Int(frames) && start + i >= 0 {
                data[start + i] += s
            }
        }
        return buffer
    }

    /// Grava o click da música num CAF (cache do projeto) com o mesmo número de quadros das faixas
    /// (assim o loop não escorrega) e devolve a URL.
    static func file(for analysis: Analysis, frames: AVAudioFrameCount, cacheDir: URL) -> URL? {
        let url = cacheDir.appending(path: "click-v1-\(frames).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let buffer = render(beats: analysis.beats, downbeats: analysis.downbeats, frames: frames) else { return nil }
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            var settings = monoFormat.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            return url
        } catch {
            NSLog("MusicSplit: falha ao gravar click: \(error)")
            return nil
        }
    }

    /// Contagem de um compasso antes de tocar.
    static func countIn(beats: Int, interval: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(Double(beats) * interval * sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        memset(data, 0, Int(frames) * MemoryLayout<Float>.size)
        for k in 0..<beats {
            let sound = click(accent: k == 0)
            let start = Int(Double(k) * interval * sampleRate)
            for (i, s) in sound.enumerated() where start + i < Int(frames) { data[start + i] = s }
        }
        return buffer
    }
}
