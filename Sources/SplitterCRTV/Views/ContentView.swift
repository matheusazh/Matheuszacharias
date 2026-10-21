import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false
    @State private var keyboard = KeyboardRouter()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay { if dropTargeted { DropHighlight() } }
        .animation(Motion.quick(reduceMotion), value: dropTargeted)
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .sheet(item: $model.importRequest) { request in
            ImportSheet(request: request)
        }
        .sheet(item: Binding(get: { model.exportRequest.map(ExportTarget.init) }, set: { model.exportRequest = $0?.id })) { target in
            if let project = model.library.project(target.id) { ExportSheet(project: project) }
        }
        .alert("Atenção", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .overlay {
            if model.showOpening {
                OpeningView { model.showOpening = false }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .toolbar(removing: .title)   // o título fica no cabeçalho do conteúdo, não repetido na barra
        .background(WindowAccessor { model.mainWindow = $0 })
        .onAppear { keyboard.install(model: model) }
    }

    @ViewBuilder private var detail: some View {
        if let project = model.currentProject {
            switch project.kind {
            case .music: MusicDetailView(project: project).id(project.id)
            case .speech: SpeechDetailView(project: project).id(project.id)
            }
        } else if let job = model.currentJob {
            JobDetailView(job: job)
        } else {
            EmptyStateView()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in collect(url) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.requestImport(link: url.absoluteString) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in model.requestImport(link: text) }
                }
            }
        }
        return handled
    }

    /// Junta os arquivos soltos juntos num único pedido (o NSItemProvider entrega um a um).
    @MainActor private func collect(_ url: URL) {
        if var request = model.importRequest, request.sources.allSatisfy({ if case .file = $0 { true } else { false } }) {
            if !request.sources.contains(.file(url)), MediaTools.isMedia(url) { request.sources.append(.file(url)) }
            model.importRequest = request
        } else {
            model.requestImport(urls: [url])
        }
    }
}

private struct ExportTarget: Identifiable { let id: UUID }

/// Borda e recado quando há algo sendo arrastado sobre a janela.
private struct DropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Brand.gradient, lineWidth: 3)
                .padding(10)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 30, weight: .semibold))
                Text("Solte para separar")
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Entrega a NSWindow que contém a view (para saber qual é a janela principal).
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window != nil { DispatchQueue.main.async { onWindow(nsView.window) } }
    }
}
