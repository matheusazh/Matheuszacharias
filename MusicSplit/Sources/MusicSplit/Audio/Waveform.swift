import Accelerate
import AVFoundation

/// Picos da forma de onda: 100 valores por segundo (máximo absoluto), guardados em peaks/<id>.peaks.
enum Waveform {
    static let binsPerSecond = 100.0

    static func compute(file url: URL, gain: Double = 1) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let binFrames = AVAudioFrameCount(format.sampleRate / binsPerSecond)
        let chunkFrames: AVAudioFrameCount = binFrames * 1000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return [] }
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(Double(file.length) / Double(binFrames)) + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            let channels = Int(format.channelCount)
            var start = 0
            while start < frames {
                let n = min(Int(binFrames), frames - start)
                var peak: Float = 0
                for c in 0..<channels {
                    var m: Float = 0
                    vDSP_maxmgv(data[c] + start, 1, &m, vDSP_Length(n))
                    peak = max(peak, m)
                }
                peaks.append(min(1, peak * Float(gain)))
                start += n
            }
        }
        return peaks
    }

    static func save(_ peaks: [Float], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = peaks.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        try Data(bytes).write(to: url, options: .atomic)
    }

    static func load(_ url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.map { Float($0) / 255 }
    }

    /// Reduz os picos para `count` colunas (máximo por coluna) no intervalo [from, to) de índices.
    static func downsample(_ peaks: [Float], count: Int, from: Int = 0, to: Int? = nil) -> [Float] {
        let end = min(to ?? peaks.count, peaks.count)
        let start = max(0, min(from, end))
        guard count > 0, end > start else { return [] }
        let span = end - start
        var out = [Float](repeating: 0, count: count)
        peaks.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let a = start + i * span / count
                let b = max(a + 1, start + (i + 1) * span / count)
                var m: Float = 0
                vDSP_maxv(p.baseAddress! + a, 1, &m, vDSP_Length(min(b, end) - a))
                out[i] = m
            }
        }
        return out
    }
}
