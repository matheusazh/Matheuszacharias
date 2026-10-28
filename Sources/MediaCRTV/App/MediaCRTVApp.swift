import SwiftUI

@main
struct MediaCRTVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let app = delegate.app
        Window("MediaCRTV", id: "main") {
            RootView()
                .environment(app)
                .environment(app.downloads)
                .environment(app.converter)
                .frame(minWidth: 620, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Adicionar arquivos para converter…") {
                    app.tab = .convert
                    app.converter.chooseFiles()
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .appInfo) {
                Button("Atualizar yt-dlp") {
                    app.tab = .download
                    app.downloads.updateYTDLP()
                }
                .disabled(app.downloads.isUpdating || !app.downloads.ytdlpAvailable)
            }
            CommandGroup(after: .pasteboard) {
                Button("Colar link e analisar") {
                    app.tab = .download
                    app.downloads.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(before: .toolbar) {
                ForEach(AppTab.allCases) { t in
                    Button(t.label) { app.tab = t }
                        .keyboardShortcut(t.shortcut)
                }
                Divider()
            }
        }
    }
}

// MARK: - Estado do app

enum AppTab: String, CaseIterable, Identifiable {
    case download, convert
    var id: String { rawValue }

    var label: String { self == .download ? "Baixar" : "Converter" }
    var symbol: String { self == .download ? "arrow.down.circle" : "arrow.triangle.2.circlepath" }
    var shortcut: KeyEquivalent { self == .download ? "1" : "2" }

    var subtitle: String {
        switch self {
        case .download: "Baixe vídeos e áudios do YouTube, Instagram, TikTok, X e muito mais."
        case .convert: "Converta vídeos para abrirem no Premiere com imagem e som."
        }
    }
}

/// Junta os dois apps: cada aba tem seu store, e os downloads podem seguir para o conversor.
@MainActor @Observable
final class AppState {
    var tab: AppTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab") }
    }
    // Ordem importa: o DownloadStore prepara as ferramentas embutidas que o ConvertStore também usa.
    let downloads = DownloadStore()
    let converter = ConvertStore()

    init() {
        tab = AppTab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .download
    }

    /// Manda arquivos para a fila do conversor e mostra a aba.
    func convert(_ urls: [URL]) {
        converter.add(urls)
        tab = .convert
    }
}

/// Dock com a soma de downloads e conversões em andamento.
enum DockBadge {
    private static var counts: [String: Int] = [:]

    static func set(_ source: String, _ n: Int) {
        counts[source] = n
        let total = counts.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Botão direito no Finder › Serviços/Ações Rápidas › "Converter p/ Premiere" (declarado no Info.plist).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Arquivos soltos no ícone do Dock ou abertos com "Abrir com".
    func application(_ application: NSApplication, open urls: [URL]) {
        app.convert(urls)
    }

    @objc func convertFiles(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if let p = Preset(rawValue: userData) { app.converter.preset = p }
        app.convert(urls)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
