import SwiftUI

/// Tela inicial: área de soltar grande, com o prisma no centro.
struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 22) {
                PrismBadge(size: 112)
                    .shadow(color: Brand.violet.opacity(0.35), radius: 24, y: 10)
                VStack(spacing: 8) {
                    Text("Solte um áudio, vídeo ou link")
                        .font(.system(size: 26, weight: .bold))
                        .tracking(-0.3)
                    Text("Separe voz e instrumentos de uma música ou limpe a voz de uma fala.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button { model.openPanel() } label: {
                        Label("Escolher arquivo", systemImage: "folder")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    Button { model.pasteLink() } label: {
                        Label("Colar link", systemImage: "link")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: 560)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .foregroundStyle(.quaternary)
            }
            HStack(spacing: 28) {
                Hint(symbol: "music.note", title: "Música", text: "2, 4 ou 6 faixas, backing vocal, tom, BPM e acordes")
                Hint(symbol: "waveform.and.mic", title: "Fala", text: "Tira música de fundo, ruído e eco de igreja")
                Hint(symbol: "film", title: "Vídeo", text: "Devolve o vídeo com o áudio novo")
            }
            .frame(maxWidth: 720)
            Spacer()
            Text("MP3, WAV, M4A, FLAC, MP4, MOV · links do YouTube, Instagram, TikTok…")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 32)
    }
}

private struct Hint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Acompanhamento de um arquivo na fila.
struct JobDetailView: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                ProgressRing(progress: job.status == .done ? 1 : job.progress, lineWidth: 10,
                             tint: job.kind == .music ? Brand.magenta : Brand.teal)
                    .frame(width: 150, height: 150)
                VStack(spacing: 2) {
                    switch job.status {
                    case .running, .done:
                        Text("\(Int((job.status == .done ? 1 : job.progress) * 100))%")
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                    case .waiting:
                        Image(systemName: "hourglass").font(.system(size: 34, weight: .medium))
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 38)).foregroundStyle(.orange)
                    case .cancelled:
                        Image(systemName: "xmark").font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .animation(.easeOut(duration: 0.3), value: job.progress)
            VStack(spacing: 6) {
                Text(job.title)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(statusText)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                if let r = job.remaining, r > 5 {
                    Text("Faltam cerca de \(Formatters.duration(r))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 460)
            HStack(spacing: 10) {
                if job.isActive {
                    Button("Cancelar", role: .cancel) { model.queue.cancel(job) }
                        .buttonStyle(.glass)
                } else if job.status != .done {
                    Button("Tentar de novo") { model.queue.retry(job) }
                        .buttonStyle(.glassProminent)
                    Button("Remover") { model.queue.remove(job) }
                        .buttonStyle(.glass)
                }
            }
            .controlSize(.large)
            Spacer()
            if job.isActive {
                Text("Pode continuar usando o app: o resultado aparece na biblioteca quando terminar.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 18)
            }
        }
        .padding(32)
    }

    private var statusText: String {
        switch job.status {
        case .waiting: "Na fila, esperando o arquivo anterior"
        case .running: job.stage
        case .done: "Pronto"
        case .failed(let m): m
        case .cancelled: "Cancelado"
        }
    }
}
