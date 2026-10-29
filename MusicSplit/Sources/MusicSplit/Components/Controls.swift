import AppKit
import SwiftUI

// MARK: - Botões

/// Feedback no pointer-down, instantâneo.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Botão redondo do transporte (play etc.).
struct RoundIconButton: View {
    let symbol: String
    var size: CGFloat = 34
    var prominent = false
    var active = false
    var tint: Color = .accentColor
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: size, height: size)
                .foregroundStyle(prominent || active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background {
                    Circle().fill(prominent ? AnyShapeStyle(tint) : active ? AnyShapeStyle(tint.opacity(0.9)) : AnyShapeStyle(.quaternary.opacity(0.8)))
                }
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .help(help)
        .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
    }
}

/// Botão pequeno de liga/desliga (M e S das faixas).
struct ToggleChip: View {
    let title: String
    let on: Bool
    var tint: Color = .accentColor
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 22, height: 20)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.7))))
                .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Pílula de informação (tom, BPM…).
struct InfoChip: View {
    let symbol: String
    let text: String
    var help: String = ""

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .help(help)
    }
}

// MARK: - Fader

/// Fader horizontal com manipulação direta: arrastar move 1:1 a partir de onde pegou;
/// clique pula para o ponto; duplo clique volta a 100%.
struct Fader: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1.25
    var tint: Color = .accentColor
    var dimmed = false
    var help = ""

    @State private var dragStart: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let unity = (1 - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.8)).frame(height: 5)
                Capsule().fill(dimmed ? AnyShapeStyle(.secondary.opacity(0.5)) : AnyShapeStyle(tint))
                    .frame(width: max(5, w * frac), height: 5)
                Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: 9)
                    .offset(x: w * unity)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: dragStart != nil ? 15 : 13, height: dragStart != nil ? 15 : 13)
                    .offset(x: w * frac - (dragStart != nil ? 7.5 : 6.5))
                    .animation(.easeOut(duration: 0.1), value: dragStart != nil)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil {
                            // pegou no botão? arrasta relativo; senão pula para o ponto
                            let knobX = w * frac
                            if abs(g.startLocation.x - knobX) > 10 {
                                value = clamp(range.lowerBound + Double(g.startLocation.x / w) * span)
                            }
                            dragStart = value
                        }
                        let v = (dragStart ?? value) + Double(g.translation.width / w) * span
                        value = snapToUnity(clamp(v))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 1 })
        }
        .frame(height: 18)
        .help(help.isEmpty ? "\(Int((value * 100).rounded()))%" : help)
        .accessibilityElement()
        .accessibilityLabel(help)
        .accessibilityValue("\(Int((value * 100).rounded())) por cento")
        .accessibilityAdjustableAction { dir in
            value = clamp(value + (dir == .increment ? 0.05 : -0.05))
        }
    }

    private var span: Double { range.upperBound - range.lowerBound }
    private func clamp(_ v: Double) -> Double { min(range.upperBound, max(range.lowerBound, v)) }

    /// Imã suave em 100%, com toque no trackpad (causalidade: sente quando encaixa).
    private func snapToUnity(_ v: Double) -> Double {
        if abs(v - 1) < 0.025 {
            if value != 1 { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            return 1
        }
        return v
    }
}

// MARK: - Progresso

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 3
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: progress)
        }
    }
}

// MARK: - Segmentado com indicador que desliza

struct SlidingSegments<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String
    var fontSize: CGFloat = 13

    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    withAnimation(Motion.quick(reduceMotion)) { selection = item }
                } label: {
                    Text(label(item))
                        .font(.system(size: fontSize, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(PressStyle(scale: 0.97))
            }
        }
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }
}
