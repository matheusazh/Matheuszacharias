import AVFoundation
import SoundAnalysis

/// Sugere Música ou Fala com o classificador de sons nativo da Apple (analisa só o começo do arquivo).
enum KindDetector {
    static func detect(url: URL) async -> ProjectKind? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run(url: url))
            }
        }
    }

    private static func run(url: URL) -> ProjectKind? {
        do {
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 3, preferredTimescale: 48_000)
            request.overlapFactor = 0
            let observer = Observer()
            try analyzer.add(request, withObserver: observer)
            observer.onEnough = { analyzer.cancelAnalysis() }
            analyzer.analyze()
            return observer.verdict
        } catch {
            return nil
        }
    }

    private final class Observer: NSObject, SNResultsObserving {
        var speech = 0.0
        var music = 0.0
        var windows = 0
        var onEnough: (() -> Void)?

        private static let musicLabels: Set<String> = [
            "music", "singing", "choir", "guitar", "piano", "drum", "drum_kit", "bass_guitar", "electric_guitar",
            "acoustic_guitar", "keyboard_musical", "organ", "synthesizer", "violin_fiddle", "orchestra", "rapping",
        ]

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            for c in r.classifications {
                if c.identifier == "speech" || c.identifier == "conversation" || c.identifier == "narration_monologue" {
                    speech += c.confidence
                } else if Self.musicLabels.contains(c.identifier) {
                    music += c.confidence
                }
            }
            windows += 1
            if windows >= 15 { onEnough?() }   // ~45 s bastam
        }

        var verdict: ProjectKind? {
            guard windows > 0, speech + music > 0.2 else { return nil }
            return speech > music * 0.9 ? .speech : .music
        }
    }
}
