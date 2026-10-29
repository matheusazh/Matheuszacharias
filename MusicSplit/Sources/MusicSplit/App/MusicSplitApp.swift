import SwiftUI

@main
struct MusicSplitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Music Split", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1240, height: 800)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Abrir áudio ou vídeo…") { model.openPanel() }
                .keyboardShortcut("o")
            Button("Colar link") { model.pasteLink() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Button("Exportar…") { if let p = model.currentProject { model.exportRequest = p.id } }
                .keyboardShortcut("e")
                .disabled(model.currentProject == nil)
        }
        CommandMenu("Reprodução") {
            // Teclas sem modificador (espaço, setas, I/O, L, K, [ ]) ficam no KeyboardRouter,
            // que ignora quando há texto sendo digitado.
            Button(model.player.isPlaying ? "Pausar  (espaço)" : "Tocar  (espaço)") { model.player.togglePlay() }
                .disabled(model.currentProject == nil)
            Button("Voltar 5 s  (←)") { model.player.skip(-5) }
                .disabled(model.currentProject == nil)
            Button("Avançar 5 s  (→)") { model.player.skip(5) }
                .disabled(model.currentProject == nil)
            Divider()
            Button("Marcar início do loop  (I)") { model.setLoopPoint(start: true) }
                .disabled(model.currentProject?.kind != .music)
            Button("Marcar fim do loop  (O)") { model.setLoopPoint(start: false) }
                .disabled(model.currentProject?.kind != .music)
            Button("Liga/desliga loop  (L)") { model.updateMix { $0.loopOn.toggle() } }
                .disabled(model.currentProject?.kind != .music)
            Button("Liga/desliga metrônomo  (K)") { model.updateMix { $0.metronome.toggle() } }
                .disabled(model.currentProject?.analysis == nil)
            Divider()
            Button("Subir meio tom") { model.updateMix { $0.pitch = min(12, $0.pitch + 1) } }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(model.currentProject?.kind != .music)
            Button("Descer meio tom") { model.updateMix { $0.pitch = max(-12, $0.pitch - 1) } }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(model.currentProject?.kind != .music)
            Button("Mais rápido  (])") { model.nudgeSpeed(0.05) }
                .disabled(model.currentProject?.kind != .music)
            Button("Mais devagar  ([)") { model.nudgeSpeed(-0.05) }
                .disabled(model.currentProject?.kind != .music)
            Divider()
            Button("Antes / depois  (B)") { model.updateSpeech { $0.compareOriginal.toggle() } }
                .disabled(model.currentProject?.kind != .speech)
            Divider()
            Button("Letra") { model.showLyrics.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(model.currentProject?.kind != .music)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let busy = MainActor.assumeIsolated { model.queue.activeCount }
        if busy > 0 {
            let alert = NSAlert()
            alert.messageText = busy == 1 ? "Há um arquivo sendo processado." : "Há \(busy) arquivos na fila."
            alert.informativeText = "Se sair agora, o processamento é cancelado."
            alert.addButton(withTitle: "Continuar processando")
            alert.addButton(withTitle: "Sair mesmo assim")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        MainActor.assumeIsolated { model.engine.shutdown() }
        return .terminateNow
    }
}
