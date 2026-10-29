import SwiftUI

/// Janela única: cabeçalho com as abas Baixar / Converter e, abaixo, a tela de cada uma.
struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var showSplash = true
    @Namespace private var brand

    private var tint: Color { app.tab == .download ? app.downloads.tint : Brand.violet }

    var body: some View {
        VStack(spacing: 0) {
            Header(namespace: brand, showSplash: showSplash)
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)

            Group {
                switch app.tab {
                case .download: DownloaderView()
                case .convert: ConverterView()
                }
            }
            .frame(maxHeight: .infinity)
            .transition(.opacity)
            .introReveal(hidden: showSplash, delay: 0.24)
        }
        .animation(Motion.quick, value: app.tab)
        .background { Backdrop(tint: tint) }
        .overlay {
            if showSplash {
                SplashView(namespace: brand) {
                    withAnimation(.spring(response: 0.55, dampingFraction: 1)) { showSplash = false }
                }
                .transition(.opacity.animation(.easeOut(duration: 0.16)))
            }
        }
    }
}

// MARK: - Header

private struct Header: View {
    @Environment(AppState.self) private var app
    let namespace: Namespace.ID
    let showSplash: Bool

    var body: some View {
        @Bindable var app = app

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // O símbolo chega voando da abertura (mesmo id no SplashView).
                if showSplash {
                    Color.clear.frame(width: 40, height: 40)
                } else {
                    CRTVMark()
                        .frame(width: 40, height: 40)
                        .matchedGeometryEffect(id: "crtv-mark", in: namespace)
                }
                Wordmark(size: 30)
                    .introReveal(hidden: showSplash, delay: 0.18, axis: .horizontal)

                Spacer(minLength: 12)

                Picker("Modo", selection: $app.tab) {
                    ForEach(AppTab.allCases) { t in
                        Label(t.label, systemImage: t.symbol).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .fixedSize()
                .help("Baixar (⌘1) · Converter (⌘2)")
                .introReveal(hidden: showSplash, delay: 0.2)
            }
            Text(app.tab.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .introReveal(hidden: showSplash, delay: 0.22)
        }
    }
}

// MARK: - Backdrop

private struct Backdrop: View {
    let tint: Color
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [tint.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [tint.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
        }
        .animation(.easeInOut(duration: 0.6), value: tint)
        .ignoresSafeArea()
    }
}
