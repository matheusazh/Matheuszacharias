import SwiftUI

// MARK: - Marca

enum Brand {
    static let red = Color(red: 1.00, green: 0.23, blue: 0.25)
    static let magenta = Color(red: 0.86, green: 0.18, blue: 0.55)
    static let violet = Color(red: 0.45, green: 0.22, blue: 0.85)
    static let teal = Color(red: 0.10, green: 0.75, blue: 0.85)

    /// Mesmo gradiente da família CRTV (vermelho → magenta → violeta → turquesa).
    static let gradient = LinearGradient(
        stops: [.init(color: red, location: 0), .init(color: magenta, location: 0.38),
                .init(color: violet, location: 0.68), .init(color: teal, location: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let bands: [Color] = [red, magenta, violet, teal]
}

/// Cor de cada faixa, estável entre projetos.
enum StemStyle {
    static func color(_ id: String) -> Color {
        switch id {
        case "vocals", "lead": Brand.red
        case "backing": Brand.magenta
        case "drums": Color(red: 1.0, green: 0.62, blue: 0.10)
        case "bass": Brand.violet
        case "guitar": Color(red: 0.25, green: 0.80, blue: 0.40)
        case "piano": Brand.teal
        case "other", "instrumental": Color(red: 0.22, green: 0.52, blue: 1.0)
        case "voice": Brand.teal
        case "voice_raw": Color(red: 0.35, green: 0.65, blue: 0.95)
        case "background": Brand.violet
        case "click": Color.gray
        default: Color.accentColor
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "vocals", "lead": "music.mic"
        case "backing": "person.2.wave.2"
        case "drums": "cylinder.split.1x2"
        case "bass": "guitars"
        case "guitar": "guitars.fill"
        case "piano": "pianokeys"
        case "other": "square.stack.3d.up"
        case "instrumental": "music.quarternote.3"
        case "voice", "voice_raw": "waveform.and.mic"
        case "background": "music.note.list"
        case "click": "metronome"
        default: "waveform"
        }
    }
}

/// Molas da casa: amortecimento crítico por padrão; quique só depois de gesto com impulso.
enum Motion {
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1.0)
    static let quick = Animation.spring(response: 0.25, dampingFraction: 1.0)
    static let settle = Animation.spring(response: 0.45, dampingFraction: 1.0)
    static let momentum = Animation.spring(response: 0.35, dampingFraction: 0.8)

    static func standard(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.18) : standard }
    static func quick(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.12) : quick }
}

// MARK: - Símbolo: prisma de som (grade 120×120)

private func prismTransform(_ rect: CGRect) -> CGAffineTransform {
    let s = min(rect.width, rect.height) / 120
    return CGAffineTransform(translationX: rect.midX - 60 * s, y: rect.midY - 60 * s).scaledBy(x: s, y: s)
}

struct PrismShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 60, y: 26))
        p.addLine(to: CGPoint(x: 90, y: 84))
        p.addLine(to: CGPoint(x: 30, y: 84))
        p.closeSubpath()
        return p.applying(prismTransform(rect))
    }
}

/// Onda branca que entra pela face esquerda do prisma.
struct WaveInShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let startX: CGFloat = 4, endX: CGFloat = 47, midY: CGFloat = 62
        p.move(to: CGPoint(x: startX, y: midY))
        let steps = 60
        for i in 1...steps {
            let x = startX + (endX - startX) * CGFloat(i) / CGFloat(steps)
            let progress = CGFloat(i) / CGFloat(steps)
            let amp = 7 * (1 - progress * 0.75)
            let y = midY + amp * sin(progress * .pi * 5.5)
            p.addLine(to: CGPoint(x: x, y: y))
        }
        return p.applying(prismTransform(rect))
    }
}

/// Uma das faixas coloridas que saem pela face direita, abrindo em leque.
struct BandShape: Shape {
    var index: Int
    func path(in rect: CGRect) -> Path {
        let origin = CGPoint(x: 73, y: 57 + CGFloat(index) * 2.2)
        let endY: CGFloat = 40 + CGFloat(index) * 13
        var p = Path()
        p.move(to: origin)
        p.addQuadCurve(to: CGPoint(x: 116, y: endY),
                       control: CGPoint(x: 95, y: origin.y + (endY - origin.y) * 0.35))
        return p.applying(prismTransform(rect))
    }
}

/// Símbolo completo. Os parâmetros servem à animação de abertura; os padrões dão o símbolo pronto.
struct PrismMark: View {
    var prism: Double = 1
    var wave: CGFloat = 1
    var bands: CGFloat = 1
    var glow: Double = 0
    var lineScale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 120
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    let stagger = max(0, min(1, bands * 1.35 - CGFloat(i) * 0.12))
                    BandShape(index: i)
                        .trim(from: 0, to: stagger)
                        .stroke(Brand.bands[i], style: StrokeStyle(lineWidth: 5.2 * s * lineScale, lineCap: .round))
                        .shadow(color: Brand.bands[i].opacity(0.55 * glow), radius: 8 * s)
                }
                PrismShape()
                    .fill(.white.opacity(0.14))
                    .overlay(PrismShape().stroke(.white.opacity(0.85),
                                                 style: StrokeStyle(lineWidth: 3.2 * s, lineJoin: .round)))
                    .opacity(prism)
                    .scaleEffect(0.85 + 0.15 * prism)
                WaveInShape()
                    .trim(from: 0, to: wave)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4 * s * lineScale, lineCap: .round, lineJoin: .round))
                    .shadow(color: .white.opacity(0.5 * glow), radius: 6 * s)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Símbolo sobre o quadrado escuro do ícone (para abertura e "Sobre").
struct PrismBadge: View {
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.08, blue: 0.16), Color(red: 0.05, green: 0.05, blue: 0.09)],
                                     startPoint: .top, endPoint: .bottom))
            PrismMark(glow: 0.6)
                .padding(size * 0.1)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Abertura

/// Onda entra, prisma acende, faixas abrem em leque; some dissolvendo (materializa ao contrário).
struct OpeningView: View {
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var prism = 0.0
    @State private var wave: CGFloat = 0
    @State private var bands: CGFloat = 0
    @State private var glow = 0.0
    @State private var title = 0.0
    @State private var leaving = false

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 18) {
                PrismMark(prism: prism, wave: wave, bands: bands, glow: glow)
                    .frame(width: 150, height: 150)
                    .background {
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .fill(Color(red: 0.07, green: 0.06, blue: 0.13))
                            .frame(width: 176, height: 176)
                            .opacity(prism)
                    }
                    .padding(.bottom, 12)
                Text("SplitterCRTV")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                    .opacity(title)
                    .offset(y: (1 - title) * 8)
            }
            .scaleEffect(leaving ? 1.06 : 1)
            .blur(radius: leaving ? 12 : 0)
            .opacity(leaving ? 0 : 1)
        }
        .contentShape(.rect)
        .onTapGesture { finish() }
        .task { await run() }
    }

    private func run() async {
        if reduceMotion {
            prism = 1; wave = 1; bands = 1; title = 1
            try? await Task.sleep(for: .milliseconds(700))
            finish()
            return
        }
        withAnimation(Motion.standard) { prism = 1 }
        try? await Task.sleep(for: .milliseconds(160))
        withAnimation(.easeOut(duration: 0.38)) { wave = 1 }
        try? await Task.sleep(for: .milliseconds(360))
        withAnimation(.easeOut(duration: 0.2)) { glow = 1 }
        withAnimation(Motion.momentum) { bands = 1 }
        try? await Task.sleep(for: .milliseconds(180))
        withAnimation(Motion.standard) { title = 1 }
        try? await Task.sleep(for: .milliseconds(650))
        finish()
    }

    private func finish() {
        guard !leaving else { return }
        withAnimation(.easeIn(duration: 0.3)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onFinish() }
    }
}
