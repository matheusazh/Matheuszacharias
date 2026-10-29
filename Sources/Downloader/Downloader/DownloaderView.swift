import SwiftUI
import UniformTypeIdentifiers

enum Motion {
    /// Criticamente amortecido: sem overshoot, para UI que não vem de gesto com momento.
    static let settle = Animation.spring(response: 0.4, dampingFraction: 1.0)
    static let quick = Animation.spring(response: 0.3, dampingFraction: 1.0)
}

struct DownloaderView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTarget = false

    private var tint: Color { store.tint }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !store.missingTools.isEmpty { MissingToolBanner(missing: store.missingTools) }
                URLBar()
                content
                QueueSection()
                    .id("queue")
                    .tint(tint)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .safeAreaInset(edge: .bottom) { FooterBar() }
        .onChange(of: store.jobs.first?.id) { _, new in
            guard new != nil else { return }
            withAnimation(reduceMotion ? nil : Motion.settle) { proxy.scrollTo("queue", anchor: .bottom) }
        }
        }
        .overlay(alignment: .top) {
            if let status = store.updateStatus {
                HStack(spacing: 8) {
                    if store.isUpdating { ProgressView().controlSize(.small) }
                    else { Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint) }
                    Text(status).font(.system(size: 12, weight: .medium))
                    if !store.isUpdating {
                        Button { store.updateStatus = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: store.updateStatus)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.settle, value: store.info?.id)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.settle, value: store.isFetching)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.settle, value: store.fetchError)
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.isFetching {
            LoadingCard()
                .transition(entering)
        } else if let error = store.fetchError {
            ErrorCard(message: error)
                .transition(entering)
        } else if let info = store.info {
            VStack(alignment: .leading, spacing: 14) {
                PreviewCard(info: info)
                OptionsPanel(info: info)
            }
            .tint(info.platform.tint)
            .transition(entering)
        } else {
            EmptyHint()
                .transition(.opacity)
        }
    }

    private var entering: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.98, anchor: .top))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    // Arquivo do Finder não é link para baixar: vai direto para a aba Converter.
                    if url.isFileURL { app.convert([url]); return }
                    store.urlText = url.absoluteString; store.analyze()
                }
            }
            return true
        }
        _ = p.loadObject(ofClass: String.self) { s, _ in
            guard let s else { return }
            DispatchQueue.main.async { store.urlText = s; store.analyze() }
        }
        return true
    }
}

// MARK: - Intro

private struct IntroReveal: ViewModifier {
    let hidden: Bool
    let delay: Double
    let axis: Axis
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shift: CGFloat = hidden && !reduceMotion ? 10 : 0
        content
            .opacity(hidden ? 0 : 1)
            .offset(x: axis == .horizontal ? -shift : 0, y: axis == .vertical ? shift : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.25) : Motion.settle.delay(delay), value: hidden)
    }
}

extension View {
    func introReveal(hidden: Bool, delay: Double, axis: Axis = .vertical) -> some View {
        modifier(IntroReveal(hidden: hidden, delay: delay, axis: axis))
    }
}

// MARK: - URL bar

private struct URLBar: View {
    @Environment(DownloadStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        let platform = store.platform

        HStack(spacing: 12) {
            PlatformIcon(platform: platform ?? .other, size: 17)
                .foregroundStyle(platform.map { $0.tint } ?? .secondary)
                .frame(width: 24)

            TextField("Cole o link do vídeo…", text: $store.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit { store.analyze() }
                .onChange(of: store.urlText) { store.urlChanged() }

            if !store.urlText.isEmpty {
                Button {
                    store.urlText = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Limpar")
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }

            Button {
                store.pasteFromClipboard()
            } label: {
                Label("Colar", systemImage: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("Colar link da área de transferência (⇧⌘V)")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .overlay {
            Capsule().strokeBorder((platform?.tint ?? .accentColor).opacity(focused ? 0.5 : 0), lineWidth: 1.5)
        }
        .animation(Motion.quick, value: store.urlText.isEmpty)
        .animation(Motion.quick, value: focused)
        .onAppear { focused = true }
    }
}

// MARK: - States

private struct EmptyHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Platform.featured, id: \.self) { p in
                    Label { Text(p.name) } icon: { PlatformIcon(platform: p, size: 12) }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(p.tint.opacity(0.1), in: .capsule)
                }
            }
            Text("Também funciona com Facebook, Reddit, Twitch, SoundCloud, Pinterest, LinkedIn e centenas de outros sites. Cole ou arraste o link.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

/// Ícone da plataforma. O X não tem SF Symbol, então usa o caractere 𝕏.
struct PlatformIcon: View {
    let platform: Platform
    var size: CGFloat

    var body: some View {
        if platform == .x {
            Text("𝕏")
                .font(.system(size: size * 1.05, weight: .bold))
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        } else {
            Image(systemName: platform.symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

private struct LoadingCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
                .frame(width: 208, height: 117)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 70, height: 10)
                RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(height: 16)
                RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: 220, height: 16)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 120, height: 12)
                Spacer(minLength: 0)
                Label("Lendo informações do link…", systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(pulse ? 0.55 : 1)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct ErrorCard: View {
    @Environment(DownloadStore.self) private var store
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Não consegui ler esse link")
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Tentar de novo") { store.analyze() }
                .buttonStyle(.glass)
        }
        .padding(16)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 22))
    }
}

private struct MissingToolBanner: View {
    let missing: [String]
    @State private var copied = false

    private var command: String {
        let brew = "brew install \(missing.joined(separator: " "))"
        return YTDLP.find("brew") == nil
            ? #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && "# + brew
            : brew
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Falta instalar: \(missing.joined(separator: ", "))")
                    .font(.system(size: 13, weight: .semibold))
                Text("Cole no Terminal, rode e depois reabra o app:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Button(copied ? "Copiado" : "Copiar") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .buttonStyle(.glass)
        }
        .padding(14)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 16))
    }
}

// MARK: - Preview

private struct PreviewCard: View {
    let info: MediaInfo

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Thumbnail(url: info.thumbnail, vertical: info.isVertical, duration: info.duration)

            VStack(alignment: .leading, spacing: 6) {
                Label { Text(info.sourceName) } icon: { PlatformIcon(platform: info.platform, size: 11) }
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .foregroundStyle(info.platform.tint)

                Text(info.title)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let u = info.uploader {
                    Text(u).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if let h = info.heights.first {
                        MetaPill(text: "até \(h)p · \(Fmt.resolution(h))", symbol: "sparkles.tv")
                    }
                    if info.entryCount > 1 {
                        MetaPill(text: "\(info.entryCount) itens", symbol: "square.stack")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

private struct Thumbnail: View {
    let url: URL?
    let vertical: Bool
    let duration: Double?

    var body: some View {
        let size = vertical ? CGSize(width: 96, height: 170) : CGSize(width: 208, height: 117)
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill().transition(.opacity)
            default: Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let d = duration, d > 0 {
                Text(Fmt.duration(d))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: .rect(cornerRadius: 6, style: .continuous))
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

private struct MetaPill: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

// MARK: - Options

private struct OptionsPanel: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let info: MediaInfo

    var body: some View {
        @Bindable var store = store
        let o = store.effectiveOptions(for: info)

        VStack(alignment: .leading, spacing: 18) {
            if info.hasVideo {
                Picker("Tipo", selection: $store.options.mode) {
                    ForEach(DownloadMode.allCases) { m in
                        Label(m.label, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
            } else {
                Label("Este link só tem áudio", systemImage: "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Group {
                if o.mode == .video { videoOptions } else { audioOptions }
            }
            .transition(.opacity)

            Divider().opacity(0.5)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.summary)
                        .font(.system(size: 13, weight: .semibold))
                    if let size = info.estimatedSize(mode: o.mode, height: o.height, compat: o.preferH264) {
                        Text("≈ \(Fmt.bytes(size))")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                Spacer()
                Button {
                    store.download()
                } label: {
                    Label("Baixar", systemImage: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.ytdlpAvailable)
                .help("Baixar (⌘↩)")
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.quick, value: o.mode)
        .animation(Motion.quick, value: o.height)
        .animation(Motion.quick, value: o.audioFormat)
    }

    @ViewBuilder private var videoOptions: some View {
        @Bindable var store = store
        let heights = info.heights

        OptionRow(title: "Resolução") {
            ChipGroup(
                items: [Int?.none] + heights.map(Optional.some),
                selection: $store.options.height,
                label: { h in h.map { "\($0)p" } ?? "Melhor" },
                caption: { h in h.map { Fmt.resolution($0) } ?? info.bestHeight(preferH264: store.options.preferH264 && store.options.container != .webm).map { "\($0)p" } }
            )
        }

        OptionRow(title: "Formato") {
            ChipGroup(items: VideoContainer.allCases, selection: $store.options.container,
                      label: { $0.label }, caption: { _ in nil })
        }

        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $store.options.preferH264) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Compatível com Premiere")
                        .font(.system(size: 13, weight: .medium))
                    Text("Baixa em H.264; se não existir, converte depois do download.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(store.options.container == .webm)

            if store.options.preferH264, store.options.container != .webm, !info.hasH264(atOrBelow: store.options.height) {
                Label("Essa resolução não existe em H.264 — será convertida após o download.", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var audioOptions: some View {
        @Bindable var store = store

        OptionRow(title: "Formato") {
            ChipGroup(items: AudioFormat.allCases, selection: $store.options.audioFormat,
                      label: { $0.label }, caption: { $0.isLossless ? "Sem perdas" : nil })
        }

        if !store.options.audioFormat.isLossless {
            OptionRow(title: "Qualidade") {
                ChipGroup(items: [320, 256, 192, 128], selection: $store.options.audioKbps,
                          label: { "\($0)" }, caption: { _ in "kbps" })
            }
            .transition(.opacity)
        }
    }
}

private struct OptionRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            content
        }
    }
}
