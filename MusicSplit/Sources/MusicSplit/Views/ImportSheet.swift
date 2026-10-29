import SwiftUI

/// Escolha do modo e das opções antes de processar.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: AppModel.ImportRequest

    @State private var kind: ProjectKind
    @State private var userPicked = false
    @AppStorage("defaultStems") private var stems = 4
    @AppStorage("defaultBacking") private var backing = false
    @AppStorage("defaultQuality") private var quality: Quality = .max
    @AppStorage("speechDenoise") private var denoise = true
    @AppStorage("speechDereverb") private var dereverb = true

    init(request: AppModel.ImportRequest) {
        self.request = request
        let last = ProjectKind(rawValue: UserDefaults.standard.string(forKey: "lastKind") ?? "") ?? .music
        _kind = State(initialValue: request.suggested ?? last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            HStack(spacing: 12) {
                ForEach(ProjectKind.allCases) { k in
                    ModeCard(kind: k, selected: kind == k, suggested: currentSuggestion == k) {
                        userPicked = true
                        withAnimation(Motion.quick(reduceMotion)) { kind = k }
                    }
                }
            }
            Group {
                if kind == .music { musicOptions } else { speechOptions }
            }
            .transition(.opacity)
            HStack {
                Spacer()
                Button("Cancelar") { model.importRequest = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(kind == .music ? "Separar" : "Limpar") {
                    model.confirmImport(kind: kind,
                                        separation: SeparationOptions(stems: stems, backing: backing, quality: quality),
                                        speech: SpeechOptions(denoise: denoise, dereverb: dereverb))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
        .animation(Motion.standard(reduceMotion), value: kind)
        .onChange(of: model.importRequest?.suggested) { _, suggestion in
            if let suggestion, !userPicked { withAnimation(Motion.quick(reduceMotion)) { kind = suggestion } }
        }
    }

    private var currentSuggestion: ProjectKind? { model.importRequest?.suggested ?? request.suggested }

    private var sources: [Job.Source] { model.importRequest?.sources ?? request.sources }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("O que fazer com \(sources.count == 1 ? "este arquivo" : "estes \(sources.count) arquivos")?")
                .font(.system(size: 18, weight: .semibold))
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var summary: String {
        let names = sources.map { s -> String in
            switch s {
            case .file(let u): u.lastPathComponent
            case .link(let l): l
            }
        }
        return names.count <= 3 ? names.joined(separator: ", ") : names.prefix(2).joined(separator: ", ") + " e mais \(names.count - 2)"
    }

    private var musicOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionRow(title: "Faixas") {
                SlidingSegments(items: [2, 4, 6], selection: $stems) { n in
                    switch n {
                    case 2: "Voz + instrumental"
                    case 4: "4 faixas"
                    default: "6 faixas"
                    }
                }
            }
            Text(stemsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 96)
            OptionRow(title: "Vozes") {
                Toggle("Separar voz principal e backing vocal", isOn: $backing)
            }
            OptionRow(title: "Qualidade") {
                SlidingSegments(items: Quality.allCases, selection: $quality) { $0.title }
                    .frame(width: 220)
                Spacer()
            }
            Text(quality == .max ? "Melhor separação. Uma música de 4 min leva cerca de 1 min num Mac M5."
                                 : "Umas 4 vezes mais rápida, com um pouco mais de vazamento entre as faixas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 96)
        }
    }

    private var stemsCaption: String {
        switch stems {
        case 2: "Voz e todo o resto junto. É a separação mais limpa."
        case 4: "Voz, bateria, baixo e outros instrumentos."
        default: "Voz, bateria, baixo, guitarra, piano e outros. Guitarra e piano saem menos precisos."
        }
    }

    private var speechOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            OptionRow(title: "Limpeza") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Tirar música de fundo", isOn: .constant(true))
                        .disabled(true)
                    Toggle("Tirar ruído (ar-condicionado, chiado, conversa)", isOn: $denoise)
                    Toggle("Tirar eco e reverb (igreja, salão)", isOn: $dereverb)
                }
            }
            Text("Depois dá para devolver parte da trilha e ajustar a intensidade da limpeza, ouvindo antes e depois.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 96)
        }
    }
}

private struct OptionRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            content
        }
    }
}

private struct ModeCard: View {
    let kind: ProjectKind
    let selected: Bool
    let suggested: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(kind == .music ? Brand.magenta : Brand.teal))
                    Spacer()
                    if suggested {
                        Text("Sugerido")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(selected ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.quaternary)))
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    }
                }
                Text(kind == .music ? "Música" : "Fala")
                    .font(.system(size: 16, weight: .semibold))
                Text(kind == .music ? "Separar voz e instrumentos" : "Isolar e limpar a voz")
                    .font(.system(size: 12))
                    .opacity(0.8)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? AnyShapeStyle(kind == .music ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.teal.gradient))
                                   : AnyShapeStyle(.quaternary.opacity(0.5)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.25 : 0), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }
}
