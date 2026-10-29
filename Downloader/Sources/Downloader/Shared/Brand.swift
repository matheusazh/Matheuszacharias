import SwiftUI

// MARK: - Brand

enum Brand {
    static let red = Color(red: 1.00, green: 0.23, blue: 0.25)
    static let magenta = Color(red: 0.86, green: 0.18, blue: 0.55)
    static let violet = Color(red: 0.45, green: 0.22, blue: 0.85)
    static let teal = Color(red: 0.10, green: 0.75, blue: 0.85)

    /// YouTube → Instagram → TikTok.
    static let gradient = LinearGradient(
        stops: [.init(color: red, location: 0), .init(color: magenta, location: 0.38),
                .init(color: violet, location: 0.68), .init(color: teal, location: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// Partes do símbolo (TV de tubo com seta), desenhadas numa grade de 120×120.
struct CRTVGlyph: Shape {
    enum Part { case body, antennas, arrow, screen }
    var part: Part

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch part {
        case .body:
            p.addRoundedRect(in: CGRect(x: 12, y: 32, width: 96, height: 76), cornerSize: CGSize(width: 24, height: 24), style: .continuous)
        case .antennas:
            p.move(to: CGPoint(x: 45, y: 15))
            p.addLine(to: CGPoint(x: 60, y: 32))
            p.addLine(to: CGPoint(x: 75, y: 15))
        case .arrow:
            p.move(to: CGPoint(x: 60, y: 55))
            p.addLine(to: CGPoint(x: 60, y: 86))
            p.move(to: CGPoint(x: 47, y: 74))
            p.addLine(to: CGPoint(x: 60, y: 87))
            p.addLine(to: CGPoint(x: 73, y: 74))
        case .screen:
            p.addRoundedRect(in: CGRect(x: 24, y: 44, width: 72, height: 52), cornerSize: CGSize(width: 13, height: 13), style: .continuous)
        }
        let s = min(rect.width, rect.height) / 120
        let t = CGAffineTransform(translationX: rect.midX - 60 * s, y: rect.midY - 60 * s).scaledBy(x: s, y: s)
        return p.applying(t)
    }
}

/// Linha branca centrada na tela da TV (grade 120×120): abre na horizontal, depois cresce até encher a tela.
struct BeamShape: Shape {
    var scaleX: CGFloat
    var scaleY: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(scaleX, scaleY) }
        set { scaleX = newValue.first; scaleY = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = 72 * scaleX, h = min(2 * scaleY, 52)
        let r = CGRect(x: 60 - w / 2, y: 70 - h / 2, width: w, height: h)
        let radius = min(h / 2, 13)
        let s = min(rect.width, rect.height) / 120
        let t = CGAffineTransform(translationX: rect.midX - 60 * s, y: rect.midY - 60 * s).scaledBy(x: s, y: s)
        return Path(roundedRect: r, cornerRadius: radius, style: .continuous).applying(t)
    }
}

/// Símbolo colorido. Os parâmetros existem para a animação de abertura; os padrões dão o símbolo pronto.
struct CRTVMark: View {
    var bodyTrim: CGFloat = 1
    var antennaTrim: CGFloat = 1
    var screenOn: Double = 1
    var flash: Double = 0
    var beamX: CGFloat = 0
    var beamY: CGFloat = 1
    var beamOpacity: Double = 0
    var arrowOpacity: Double = 1
    var arrowDrop: CGFloat = 0
    var rgbSplit: CGFloat = 0
    var glow: Double = 0

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height) / 120
            let style = StrokeStyle(lineWidth: 8 * s, lineCap: .round, lineJoin: .round)
            let splitOpacity = Double(min(rgbSplit / 4, 1)) * 0.9

            ZStack {
                CRTVGlyph(part: .screen)
                    .fill(Brand.gradient)
                    .opacity(screenOn)
                CRTVGlyph(part: .screen)
                    .fill(.white)
                    .opacity(flash * 0.85 * screenOn)

                // Feixe do tubo ligando: linha que abre e depois enche a tela.
                BeamShape(scaleX: beamX, scaleY: beamY)
                    .fill(.white)
                    .opacity(beamOpacity)

                CRTVGlyph(part: .body)
                    .trim(from: 0, to: bodyTrim)
                    .stroke(.primary, style: style)
                CRTVGlyph(part: .antennas)
                    .trim(from: 0, to: antennaTrim)
                    .stroke(.primary, style: style)

                ZStack {
                    CRTVGlyph(part: .arrow).stroke(Brand.red, style: style)
                        .offset(x: -rgbSplit * s).opacity(splitOpacity)
                    CRTVGlyph(part: .arrow).stroke(Brand.teal, style: style)
                        .offset(x: rgbSplit * s).opacity(splitOpacity)
                    CRTVGlyph(part: .arrow).stroke(.white, style: style)
                }
                .offset(y: arrowDrop * s)
                .opacity(arrowOpacity)
            }
            .compositingGroup()
            .shadow(color: Brand.violet.opacity(0.25 * screenOn), radius: 7 * s, y: 3 * s)
            .shadow(color: Brand.magenta.opacity(0.55 * glow), radius: 10 * s)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct Wordmark: View {
    var size: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("Down").fontWeight(.semibold)
            Text("loader").fontWeight(.heavy).foregroundStyle(Brand.gradient)
        }
        .font(.system(size: size))
        .tracking(-0.02 * size)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Downloader")
    }
}

// MARK: - Abertura

/// Carcaça se desenha → tubo liga → seta cai → nome sobe. Ao terminar, o símbolo
/// voa para o cabeçalho via matchedGeometryEffect (quem chama anima a saída).
struct SplashView: View {
    let namespace: Namespace.ID
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var visible = false
    @State private var bodyTrim: CGFloat = 0
    @State private var antennaTrim: CGFloat = 0
    @State private var screenOn: Double = 0
    @State private var flash: Double = 0
    @State private var beamX: CGFloat = 0
    @State private var beamY: CGFloat = 1
    @State private var beamOpacity: Double = 0
    @State private var arrowOpacity: Double = 0
    @State private var arrowDrop: CGFloat = -22
    @State private var rgbSplit: CGFloat = 4
    @State private var glow: Double = 0
    @State private var wordShown = false
    @State private var tagShown = false
    @State private var done = false

    var body: some View {
        VStack(spacing: 18) {
            CRTVMark(bodyTrim: bodyTrim, antennaTrim: antennaTrim, screenOn: screenOn, flash: flash,
                     beamX: beamX, beamY: beamY, beamOpacity: beamOpacity, arrowOpacity: arrowOpacity,
                     arrowDrop: arrowDrop, rgbSplit: rgbSplit, glow: glow)
                .frame(width: 150, height: 150)
                .matchedGeometryEffect(id: "crtv-mark", in: namespace)

            Wordmark(size: 32)
                .opacity(wordShown ? 1 : 0)
                .offset(y: wordShown ? 0 : 10)

            Text("Baixe · Converta · Edite no Premiere")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, -8)
                .opacity(tagShown ? 1 : 0)
                .offset(y: tagShown ? 0 : 8)
        }
        .opacity(visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture(perform: skip)
        .task { await run() }
        .accessibilityLabel("Abrindo Downloader")
    }

    private func wait(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !done && !Task.isCancelled
    }

    private func setFinalState() {
        bodyTrim = 1; antennaTrim = 1; screenOn = 1; flash = 0
        beamOpacity = 0; arrowOpacity = 1; arrowDrop = 0; rgbSplit = 0; glow = 0
        wordShown = true; tagShown = true; visible = true
    }

    private func run() async {
        if reduceMotion {
            setFinalState()
            visible = false
            withAnimation(.easeOut(duration: 0.25)) { visible = true }
            guard await wait(0.9) else { return }
            finish()
            return
        }

        visible = true

        // 1. Carcaça e antenas se desenham
        guard await wait(0.08) else { return }
        withAnimation(.timingCurve(0.3, 0.7, 0.2, 1, duration: 0.56)) { bodyTrim = 1 }
        guard await wait(0.30) else { return }
        withAnimation(.timingCurve(0.3, 0.7, 0.2, 1, duration: 0.30)) { antennaTrim = 1 }

        // 2. Tubo liga: linha abre na horizontal, depois enche a tela
        guard await wait(0.24) else { return }
        withAnimation(.easeOut(duration: 0.17)) { beamX = 1; beamOpacity = 1 }
        guard await wait(0.17) else { return }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.15)) { beamY = 26 }
        flash = 1
        withAnimation(.easeOut(duration: 0.42)) { screenOn = 1; flash = 0 }
        withAnimation(.easeOut(duration: 0.3)) { glow = 1 }
        guard await wait(0.1) else { return }
        withAnimation(.easeOut(duration: 0.15)) { beamOpacity = 0 }

        // 3. Seta cai com peso; rastro RGB se alinha
        guard await wait(0.03) else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrowDrop = 0; arrowOpacity = 1 }
        withAnimation(.easeOut(duration: 0.38).delay(0.05)) { rgbSplit = 0 }
        withAnimation(.easeOut(duration: 0.8).delay(0.1)) { glow = 0 }

        // 4. Nome e plataformas sobem
        guard await wait(0.2) else { return }
        withAnimation(Motion.settle) { wordShown = true }
        guard await wait(0.1) else { return }
        withAnimation(Motion.settle) { tagShown = true }

        // 5. Segura um instante e entrega para o cabeçalho
        guard await wait(0.6) else { return }
        finish()
    }

    private func skip() {
        guard !done else { return }
        withAnimation(.easeOut(duration: 0.15)) { setFinalState() }
        finish()
    }

    private func finish() {
        guard !done else { return }
        done = true
        onFinish()
    }
}
