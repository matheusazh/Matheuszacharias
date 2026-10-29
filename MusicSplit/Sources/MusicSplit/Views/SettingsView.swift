import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Geral", systemImage: "gearshape") }
            SeparationSettings().tabItem { Label("Separação", systemImage: "slider.horizontal.3") }
            ModelsSettings().tabItem { Label("Modelos", systemImage: "cpu") }
            AboutSettings().tabItem { Label("Sobre", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 400)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("libraryPath") private var libraryPath = ""
    @AppStorage("skipOpening") private var skipOpening = false
    @AppStorage("simpleChords") private var simpleChords = false

    var body: some View {
        Form {
            Section("Biblioteca") {
                LabeledContent("Pasta") {
                    HStack {
                        Text(model.library.root.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Alterar…") { choose() }
                        Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([model.library.libraryDir]) }
                    }
                }
                Text("Cada música ou fala fica numa pasta com as faixas em FLAC (sem perda).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Música") {
                Toggle("Mostrar acordes simplificados (só maior/menor)", isOn: $simpleChords)
            }
            Section("App") {
                Toggle("Pular a animação de abertura", isOn: $skipOpening)
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Usar esta pasta"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        libraryPath = url.path
        model.library.reload()
        model.selection = nil
    }
}

private struct SeparationSettings: View {
    @AppStorage("defaultStems") private var stems = 4
    @AppStorage("defaultBacking") private var backing = false
    @AppStorage("defaultQuality") private var quality: Quality = .max
    @AppStorage("speechDenoise") private var denoise = true
    @AppStorage("speechDereverb") private var dereverb = true
    @AppStorage("speechLoudness") private var loudness: LoudnessTarget = .podcast

    var body: some View {
        Form {
            Section("Música (padrão ao importar)") {
                Picker("Faixas", selection: $stems) {
                    Text("Voz + instrumental").tag(2)
                    Text("4 faixas").tag(4)
                    Text("6 faixas").tag(6)
                }
                Toggle("Separar voz principal e backing vocal", isOn: $backing)
                Picker("Qualidade", selection: $quality) {
                    ForEach(Quality.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Fala (padrão ao importar)") {
                Toggle("Tirar ruído", isOn: $denoise)
                Toggle("Tirar eco e reverb", isOn: $dereverb)
                Picker("Volume final", selection: $loudness) {
                    ForEach(LoudnessTarget.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var status: [String: Bool] = [:]
    @State private var whisper = false
    @State private var downloading: Double?
    @State private var error: String?

    private let names: [(String, String)] = [
        ("vocals", "Voz × instrumental (BS-RoFormer)"), ("multi", "4 e 6 faixas (BS-RoFormer SW)"),
        ("fast", "Qualidade rápida (Demucs)"), ("karaoke", "Voz principal × backing"),
        ("denoise", "Tirar ruído"), ("dereverb", "Tirar eco (MelBand De-Reverb)"),
    ]

    var body: some View {
        Form {
            Section("Motor de IA") {
                LabeledContent("Estado") {
                    switch model.engine.state {
                    case .ready: Text("Pronto · \(model.engine.device == "mps" ? "GPU do Mac" : "CPU")").foregroundStyle(.green)
                    case .starting: Text("Iniciando…").foregroundStyle(.secondary)
                    case .stopped: Text("Parado (inicia quando precisar)").foregroundStyle(.secondary)
                    case .failed(let m): Text(m).foregroundStyle(.orange)
                    }
                }
                ForEach(names, id: \.0) { key, title in
                    LabeledContent(title) {
                        Image(systemName: status[key] == true ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(status[key] == true ? .green : .secondary)
                            .help(status[key] == true ? "Instalado" : "Baixa na primeira vez que for usado")
                    }
                }
            }
            Section("Letra (Whisper)") {
                LabeledContent("Modelo de transcrição (~1,5 GB)") {
                    if whisper {
                        Label("Instalado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let downloading {
                        ProgressView(value: downloading).frame(width: 120)
                    } else {
                        Button("Baixar agora") { download() }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("Mostrar pasta dos modelos") { NSWorkspace.shared.activateFileViewerSelecting([Toolchain.modelsDir]) }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        guard let data = try? await model.engine.call("status"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        status = json["models"] as? [String: Bool] ?? [:]
        whisper = json["whisper"] as? Bool ?? false
    }

    private func download() {
        downloading = 0
        error = nil
        Task {
            do {
                _ = try await model.engine.call("download_lyrics_model") { p in downloading = p.fraction }
                downloading = nil
                await refresh()
            } catch {
                downloading = nil
                self.error = error.localizedDescription
            }
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            PrismBadge(size: 84)
            Text("Music Split").font(.system(size: 20, weight: .bold))
            Text("Versão \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Separação por BS-RoFormer (viperx, SW por jarredou, karaokê por frazer e becruily), MelBand De-Reverb (anvuew), Demucs (Meta) via audio-separator; batidas por Beat This! (CPJKU); acordes por lv-chordia (Music X Lab); letra por Whisper (OpenAI) em MLX.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Tudo roda no seu Mac. Nenhum áudio sai do computador.")
                .font(.caption.weight(.semibold))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
