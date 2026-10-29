import AVFoundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case wav, flac, mp3, m4a
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var ext: String { rawValue }
    var caption: String {
        switch self {
        case .wav: "24 bits, sem perda (Premiere, DAWs)"
        case .flac: "Sem perda, menor que WAV"
        case .mp3: "320 kbps, toca em qualquer lugar"
        case .m4a: "AAC 256 kbps, iPhone e redes"
        }
    }
    var codecArgs: [String] {
        switch self {
        case .wav: ["-c:a", "pcm_s24le"]
        case .flac: ["-c:a", "flac", "-sample_fmt", "s32"]
        case .mp3: ["-c:a", "libmp3lame", "-b:a", "320k"]
        case .m4a: ["-c:a", "aac", "-b:a", "256k"]
        }
    }
}

/// Renderização offline (mesmo grafo da reprodução: o que se ouve é o que se exporta) e conversão com ffmpeg.
enum Exporter {
    struct Input {
        let url: URL
        let gain: Double
        let volume: Float
        var isClick = false
    }

    enum Failure: LocalizedError {
        case render(String)
        var errorDescription: String? {
            switch self { case .render(let m): "Falha ao exportar: \(m)" }
        }
    }

    /// Mistura as entradas com tom/velocidade num CAF float temporário.
    static func render(_ inputs: [Input], pitch: Int, rate: Double, to output: URL,
                       progress: @escaping (Double) -> Void) throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let bus = AVAudioMixerNode()
        let timePitch = AVAudioUnitTimePitch()
        let clickPitch = AVAudioUnitTimePitch()
        timePitch.pitch = Float(pitch * 100)
        timePitch.rate = Float(rate)
        timePitch.overlap = 16
        clickPitch.rate = Float(rate)
        engine.attach(bus)
        engine.attach(timePitch)
        engine.attach(clickPitch)
        engine.connect(bus, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.connect(clickPitch, to: engine.mainMixerNode, format: ClickTrack.monoFormat)

        var players: [AVAudioPlayerNode] = []
        var longest: AVAudioFramePosition = 0
        for input in inputs {
            let file = try AVAudioFile(forReading: input.url)
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let destination: AVAudioNode = input.isClick ? clickPitch : bus
            if input.gain > 1.0001 {
                let eq = AVAudioUnitEQ(numberOfBands: 0)
                eq.globalGain = Float(20 * log10(input.gain))
                engine.attach(eq)
                engine.connect(player, to: eq, format: file.processingFormat)
                engine.connect(eq, to: destination, format: file.processingFormat)
            } else {
                engine.connect(player, to: destination, format: file.processingFormat)
            }
            player.volume = input.volume
            player.scheduleFile(file, at: nil)
            players.append(player)
            if !input.isClick { longest = max(longest, file.length) }
        }
        try engine.start()
        players.forEach { $0.play() }

        let total = AVAudioFramePosition(Double(longest) / rate) + 4410
        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false   // arquivo em disco é intercalado
        let outFile = try AVAudioFile(forWriting: output, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw Failure.render("sem memória para o buffer")
        }
        var lastReport = 0.0
        while engine.manualRenderingSampleTime < total {
            let frames = min(buffer.frameCapacity, AVAudioFrameCount(total - engine.manualRenderingSampleTime))
            switch try engine.renderOffline(frames, to: buffer) {
            case .success:
                try outFile.write(from: buffer)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw Failure.render("erro de renderização")
            @unknown default:
                throw Failure.render("estado desconhecido")
            }
            let f = Double(engine.manualRenderingSampleTime) / Double(total)
            if f - lastReport > 0.01 { lastReport = f; progress(f) }
        }
        engine.stop()
    }

    /// Converte para o formato final. `limit` evita estouro (mixagens); `loudness` nivela em LUFS (fala).
    static func encode(_ input: URL, to output: URL, format: ExportFormat, gain: Double = 1,
                       limit: Bool = false, loudness: Double? = nil) async throws {
        guard let ffmpeg = Toolchain.ffmpeg else { throw MediaTools.Failure.missingTool("ffmpeg") }
        var filters: [String] = []
        if abs(gain - 1) > 0.0001 { filters.append(String(format: "volume=%.6f", gain)) }
        if let target = loudness {
            let measured = try await measureLoudness(input, target: target)
            filters.append(String(format: "loudnorm=I=%.1f:TP=-1.5:LRA=11:measured_I=%@:measured_TP=%@:measured_LRA=%@:measured_thresh=%@:offset=%@:linear=true",
                                  target, measured.i, measured.tp, measured.lra, measured.thresh, measured.offset))
        } else if limit {
            filters.append("alimiter=limit=0.97:level=false:attack=5:release=50")
        }
        var args = ["-nostdin", "-y", "-v", "error", "-i", input.path]
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
        args += ["-ar", "44100"] + format.codecArgs + [output.path]
        try await ProcessRunner.run(ffmpeg, args)
    }

    struct Measured { var i, tp, lra, thresh, offset: String }

    /// 1ª passada do loudnorm (medição), para a 2ª ser linear e transparente.
    static func measureLoudness(_ input: URL, target: Double) async throws -> Measured {
        guard let ffmpeg = Toolchain.ffmpeg else { throw MediaTools.Failure.missingTool("ffmpeg") }
        let out = try await ProcessRunner.run(ffmpeg, ["-nostdin", "-hide_banner", "-i", input.path, "-af",
                                                       String(format: "loudnorm=I=%.1f:TP=-1.5:LRA=11:print_format=json", target),
                                                       "-f", "null", "-"], allowFailure: true)
        let text = out.stderr
        guard let start = text.lastIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: String] else {
            throw Failure.render("não consegui medir o loudness")
        }
        return Measured(i: json["input_i"] ?? "-23", tp: json["input_tp"] ?? "-2", lra: json["input_lra"] ?? "7",
                        thresh: json["input_thresh"] ?? "-33", offset: json["target_offset"] ?? "0")
    }

    /// Troca o áudio do vídeo sem recodificar a imagem.
    static func remux(video: URL, audio: URL, to output: URL) async throws {
        guard let ffmpeg = Toolchain.ffmpeg else { throw MediaTools.Failure.missingTool("ffmpeg") }
        var args = ["-nostdin", "-y", "-v", "error", "-i", video.path, "-i", audio.path,
                    "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-shortest"]
        if ["mp4", "m4v", "mov"].contains(output.pathExtension.lowercased()) { args += ["-movflags", "+faststart"] }
        args.append(output.path)
        try await ProcessRunner.run(ffmpeg, args)
    }

    static func videoExtension(for source: URL) -> String {
        switch source.pathExtension.lowercased() {
        case "mov": "mov"
        case "mp4", "m4v": "mp4"
        default: "mkv"
        }
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }
}
