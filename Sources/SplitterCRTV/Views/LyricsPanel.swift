import AppKit
import SwiftUI

/// Letra sincronizada no painel lateral. Toque numa linha para ir até ela.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var followPlayback = true

    var body: some View {
        VStack(spacing: 0) {
            if let lines = project.lyrics, !lines.isEmpty {
                lyrics(lines)
            } else if let work = model.lyricsWork, work.projectID == project.id {
                progress(work)
            } else {
                intro
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func lyrics(_ lines: [LyricLine]) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                TimelineView(.animation(minimumInterval: 0.2, paused: !model.player.isPlaying)) { _ in
                    let t = model.scrubTime ?? model.player.displayTime()
                    let current = lines.lastIndex { $0.start <= t + 0.15 }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                Text(line.text)
                                    .font(.system(size: i == current ? 19 : 17, weight: i == current ? .bold : .medium))
                                    .foregroundStyle(i == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                    .opacity(current.map { i < $0 ? 0.55 : 1 } ?? 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                                    .onTapGesture { model.player.seek(to: line.start) }
                                    .animation(Motion.quick, value: current)
                                    .id(i)
                            }
                        }
                        .padding(18)
                    }
                    .onChange(of: current) { _, newValue in
                        guard followPlayback, let newValue else { return }
                        withAnimation(Motion.standard) { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Acompanhar", isOn: $followPlayback)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Menu {
                    Button("Copiar letra") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
                    }
                    Button("Exportar letra sincronizada (.lrc)…") { exportLRC(lines) }
                    Divider()
                    Button("Transcrever de novo") {
                        model.updateProject(project.id) { $0.lyrics = nil }
                        model.transcribeLyrics(for: project)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func progress(_ work: AppModel.LyricsWork) -> some View {
        VStack(spacing: 14) {
            Spacer()
            if let error = work.error {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.orange)
                Text(error).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Tentar de novo") {
                    model.lyricsWork = nil
                    model.transcribeLyrics(for: project)
                }
                .buttonStyle(.glass)
            } else {
                ProgressRing(progress: work.fraction, lineWidth: 5, tint: Brand.magenta)
                    .frame(width: 54, height: 54)
                Text(work.stage).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Brand.magenta)
            Text("Letra sincronizada")
                .font(.system(size: 17, weight: .semibold))
            Text("O Whisper transcreve a voz isolada e marca cada linha no tempo. Na primeira vez baixa um modelo de ~1,5 GB.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Transcrever letra") { model.transcribeLyrics(for: project) }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            Text("Música cantada pode ter erros; dá para corrigir no arquivo exportado.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    private func exportLRC(_ lines: [LyricLine]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.title).lrc"
        panel.allowedContentTypes = [.init(filenameExtension: "lrc") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = lines.map { line -> String in
            let m = Int(line.start) / 60, s = line.start - Double(m * 60)
            return String(format: "[%02d:%05.2f]%@", m, s, line.text)
        }.joined(separator: "\n")
        try? ("[ti:\(project.title)]\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
