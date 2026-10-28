import SwiftUI
import UniformTypeIdentifiers

struct ConverterView: View {
    @Environment(ConvertStore.self) private var store
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 16) {
            dropZone
            presetPicker
            if !store.jobs.isEmpty { queue }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            load(providers); return true
        }
        .animation(.smooth(duration: 0.25), value: store.jobs.count)
    }

    private var dropZone: some View {
        Button { store.chooseFiles() } label: {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(dropTargeted ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.secondary))
                Text(dropTargeted ? "Solte para converter" : "Arraste vídeos ou pastas aqui")
                    .font(.system(size: 15, weight: .semibold))
                Text("ou clique para escolher · WebM, MKV, VP9, AV1, HEVC 10-bit…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: store.jobs.isEmpty ? 220 : 120)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(dropTargeted ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.quaternary),
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 5]))
        }
        .scaleEffect(dropTargeted ? 1.01 : 1)
        .animation(.spring(duration: 0.25), value: dropTargeted)
    }

    private var presetPicker: some View {
        @Bindable var store = store
        return HStack(spacing: 8) {
            ForEach(Preset.allCases) { p in
                let selected = store.preset == p
                Button { store.preset = p } label: {
                    VStack(spacing: 2) {
                        Text(p.label).font(.system(size: 13, weight: .semibold))
                        Text(p.caption).font(.system(size: 10)).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(selected ? .white : .primary)
                    .background {
                        if selected { RoundedRectangle(cornerRadius: 14).fill(Brand.gradient) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
            }
        }
    }

    private var queue: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fila").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !store.autoStart, !store.pending.isEmpty {
                    Button("Converter \(store.pending.count)") { store.startAll() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
                if store.jobs.contains(where: { !$0.isActive }) {
                    Button("Limpar") { store.clearFinished() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.jobs) { job in
                        ConvertJobRow(job: job)
                        if job.id != store.jobs.last?.id { Divider().padding(.leading, 50) }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var footer: some View {
        @Bindable var store = store
        return HStack(spacing: 12) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(store.destination.map { "Salvar em \($0.lastPathComponent)" } ?? "Salvar ao lado do original")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Button("Alterar…") { store.chooseDestination() }.buttonStyle(.borderless).controlSize(.small)
            if store.destination != nil {
                Button("Original") { store.destination = nil }.buttonStyle(.borderless).controlSize(.small)
            }
            Spacer()
            Toggle("Converter ao soltar", isOn: $store.autoStart)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 12))
        }
        .overlay(alignment: .top) {
            if !store.ffmpegAvailable {
                Label("ffmpeg não encontrado no app.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange).offset(y: -24)
            }
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { store.add([url]) }
            }
        }
    }
}

struct ConvertJobRow: View {
    @Environment(ConvertStore.self) private var store
    let job: ConvertJob

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if job.state == .converting {
                    ProgressView(value: job.progress).progressViewStyle(.linear).tint(Brand.violet)
                }
                Text(job.detail).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var isFailed: Bool { if case .failed = job.state { true } else { false } }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .probing, .converting: ProgressView().controlSize(.small)
        case .ready: Image(systemName: "clock").foregroundStyle(.secondary)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "checkmark.seal").foregroundStyle(Brand.teal)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            switch job.state {
            case .done, .skipped:
                iconButton("magnifyingglass", "Mostrar no Finder") { job.reveal() }
            case .failed, .cancelled:
                iconButton("arrow.clockwise", "Tentar de novo") { store.retry(job) }
            default: EmptyView()
            }
            iconButton(job.isActive ? "xmark" : "trash", job.isActive ? "Cancelar" : "Remover") {
                if job.isActive && job.state == .converting { job.cancel() } else { store.remove(job) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless).help(help)
    }
}
