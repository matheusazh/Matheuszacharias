import SwiftUI

// MARK: - Platform

enum Platform: String {
    case youtube, instagram, tiktok, x, other

    /// Plataformas em destaque na tela inicial. Qualquer outro site suportado pelo yt-dlp cai em `.other`.
    static let featured: [Platform] = [.youtube, .instagram, .tiktok, .x]

    static func detect(_ text: String) -> Platform? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("instagram.com") { return .instagram }
        if host.contains("tiktok.com") { return .tiktok }
        if host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com") { return .x }
        return .other
    }

    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .x: "X"
        case .other: "Link"
        }
    }

    var symbol: String {
        switch self {
        case .youtube: "play.rectangle.fill"
        case .instagram: "camera.fill"
        case .tiktok: "music.note"
        case .x: "text.bubble.fill" // não há símbolo do X; a UI usa PlatformIcon, que desenha 𝕏
        case .other: "link"
        }
    }

    var tint: Color {
        switch self {
        case .youtube: Color(red: 1.0, green: 0.16, blue: 0.2)
        case .instagram: Color(red: 0.88, green: 0.19, blue: 0.56)
        case .tiktok: Color(red: 0.1, green: 0.78, blue: 0.82)
        case .x: Color(red: 0.11, green: 0.61, blue: 0.94)
        case .other: .accentColor
        }
    }
}

// MARK: - Media info (yt-dlp -J)

struct MediaFormat {
    let id: String
    let ext: String
    /// Lado menor do quadro (720p vale para 1280×720 e 720×1280), como o yt-dlp compara `res`.
    let height: Int?
    let fps: Double?
    let vcodec: String
    let acodec: String
    let tbr: Double?
    let abr: Double?
    let filesize: Int64?

    var hasVideo: Bool { vcodec != "none" && !vcodec.isEmpty }
    var hasAudio: Bool { acodec != "none" && !acodec.isEmpty }
    var isH264: Bool { vcodec.hasPrefix("avc1") || vcodec.hasPrefix("h264") }
}

struct MediaInfo {
    let id: String
    let title: String
    let uploader: String?
    let duration: Double?
    let thumbnail: URL?
    let width: Int?
    let height: Int?
    let formats: [MediaFormat]
    let platform: Platform
    let entryCount: Int
    /// Nome exibido: a plataforma conhecida ou o site que o yt-dlp identificou (ex.: "Vimeo").
    let sourceName: String

    /// Falso para links só de áudio. Sem lista de formatos, assume que há vídeo.
    var hasVideo: Bool { formats.isEmpty || formats.contains(where: \.hasVideo) }

    var isVertical: Bool {
        if let w = width, let h = height, w > 0 { return h > w }
        return platform == .tiktok
    }

    /// Resoluções disponíveis (alturas), da maior para a menor.
    var heights: [Int] {
        let all = Set(formats.filter(\.hasVideo).compactMap(\.height).filter { $0 >= 240 })
        return all.sorted(by: >)
    }

    /// Altura que "Melhor" vai entregar: com H.264 priorizado, a maior disponível em H.264.
    func bestHeight(preferH264: Bool) -> Int? {
        if preferH264, let h = formats.filter({ $0.isH264 && $0.hasVideo }).compactMap(\.height).max() { return h }
        return heights.first
    }

    func hasH264(atOrBelow height: Int?) -> Bool {
        let target = height ?? bestHeight(preferH264: true) ?? .max
        let bestAvailable = formats.filter(\.hasVideo).compactMap(\.height).filter { $0 <= target }.max()
        return formats.contains { $0.isH264 && $0.height == bestAvailable }
    }

    /// Estimativa grosseira do tamanho final.
    func estimatedSize(mode: DownloadMode, height: Int?, compat: Bool) -> Int64? {
        func size(_ f: MediaFormat) -> Int64? {
            if let s = f.filesize, s > 0 { return s }
            if let tbr = f.tbr ?? f.abr, let d = duration { return Int64(tbr * d * 125) }
            return nil
        }
        let audio = formats.filter { $0.hasAudio && !$0.hasVideo }
            .max { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) }

        if mode == .audio {
            if let a = audio { return size(a) }
            return nil
        }

        let limit = height ?? bestHeight(preferH264: compat) ?? .max
        var videos = formats.filter { $0.hasVideo && ($0.height ?? 0) <= limit }
        guard let topHeight = videos.compactMap(\.height).max() else { return nil }
        videos = videos.filter { $0.height == topHeight }
        if compat, videos.contains(where: \.isH264) { videos = videos.filter(\.isH264) }
        guard let v = videos.max(by: { ($0.tbr ?? 0) < ($1.tbr ?? 0) }), let vs = size(v) else { return nil }
        if v.hasAudio { return vs }
        return vs + (audio.flatMap(size) ?? 0)
    }

    /// "TwitchClips" → "Twitch", "Soundcloud" → "SoundCloud"…
    static func friendlyName(forExtractor key: String) -> String {
        let known = ["Facebook", "Reddit", "Twitch", "Pinterest", "LinkedIn", "Dailymotion", "Vimeo", "Bluesky", "Bilibili"]
        if let match = known.first(where: { key.hasPrefix($0) }) { return match }
        return ["Soundcloud": "SoundCloud"][key] ?? key
    }

    init(json: [String: Any], platform: Platform) {
        var root = json
        var count = 1
        if (json["_type"] as? String) == "playlist", let entries = json["entries"] as? [[String: Any]], let first = entries.first {
            count = entries.count
            root = first
            if root["title"] == nil { root["title"] = json["title"] }
        }
        id = root["id"] as? String ?? UUID().uuidString
        title = (root["title"] as? String) ?? (root["description"] as? String) ?? "Sem título"
        uploader = (root["uploader"] as? String) ?? (root["channel"] as? String) ?? (root["uploader_id"] as? String)
        duration = (root["duration"] as? NSNumber)?.doubleValue
        if let t = root["thumbnail"] as? String { thumbnail = URL(string: t) }
        else if let thumbs = root["thumbnails"] as? [[String: Any]], let t = thumbs.last?["url"] as? String { thumbnail = URL(string: t) }
        else { thumbnail = nil }
        width = (root["width"] as? NSNumber)?.intValue
        height = (root["height"] as? NSNumber)?.intValue
        entryCount = count
        self.platform = platform
        if platform != .other {
            sourceName = platform.name
        } else if let key = root["extractor_key"] as? String, key != "Generic" {
            sourceName = MediaInfo.friendlyName(forExtractor: key)
        } else {
            sourceName = (root["webpage_url_domain"] as? String) ?? "Link"
        }
        let raw = root["formats"] as? [[String: Any]] ?? []
        formats = raw.map { f in
            MediaFormat(
                id: f["format_id"] as? String ?? "",
                ext: f["ext"] as? String ?? "",
                height: {
                    let h = (f["height"] as? NSNumber)?.intValue
                    guard let w = (f["width"] as? NSNumber)?.intValue, let h else { return h }
                    return min(w, h)
                }(),
                fps: (f["fps"] as? NSNumber)?.doubleValue,
                vcodec: f["vcodec"] as? String ?? "none",
                acodec: f["acodec"] as? String ?? "none",
                tbr: (f["tbr"] as? NSNumber)?.doubleValue,
                abr: (f["abr"] as? NSNumber)?.doubleValue,
                filesize: (f["filesize"] as? NSNumber)?.int64Value ?? (f["filesize_approx"] as? NSNumber)?.int64Value
            )
        }
    }
}

// MARK: - Options

enum DownloadMode: String, CaseIterable, Identifiable {
    case video, audio
    var id: String { rawValue }
    var label: String { self == .video ? "Vídeo" : "Áudio" }
    var symbol: String { self == .video ? "film" : "waveform" }
}

enum VideoContainer: String, CaseIterable, Identifiable {
    case mp4, mov, mkv, webm
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, wav, flac, opus
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var isLossless: Bool { self == .wav || self == .flac }
}

enum CookieSource: String, CaseIterable, Identifiable {
    case none, safari, chrome, firefox, brave, edge
    var id: String { rawValue }
    var label: String { self == .none ? "Nenhum" : rawValue.capitalized }
}

struct DownloadOptions {
    var mode: DownloadMode = .video
    var container: VideoContainer = .mp4
    var height: Int? = nil
    var preferH264 = true
    var audioFormat: AudioFormat = .mp3
    var audioKbps = 320

    var summary: String {
        switch mode {
        case .video:
            let res = height.map { "\($0)p" } ?? "Melhor qualidade"
            return "\(container.label) · \(res)\(preferH264 && container != .webm ? " · H.264" : "")"
        case .audio:
            return "\(audioFormat.label) · \(audioFormat.isLossless ? "sem perdas" : "\(audioKbps) kbps")"
        }
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func resolution(_ h: Int) -> String {
        switch h {
        case 4320...: "8K"
        case 2160...: "4K"
        case 1440...: "2K"
        case 1080...: "Full HD"
        case 720...: "HD"
        default: "SD"
        }
    }
}
