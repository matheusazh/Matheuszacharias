import SwiftUI

// MARK: - Chips

/// Grupo de opções com indicador que desliza entre as escolhas (continuidade espacial).
struct ChipGroup<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String
    let caption: (Item) -> String?

    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.quick) { selection = item }
                } label: {
                    HStack(spacing: 5) {
                        Text(label(item))
                            .font(.system(size: 13, weight: selected ? .semibold : .medium).monospacedDigit())
                        if let c = caption(item) {
                            Text(c)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                        }
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule()
                                .fill(.tint)
                                .matchedGeometryEffect(id: "selection", in: ns)
                                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                        } else {
                            Capsule().fill(.quaternary.opacity(0.7))
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
            }
        }
    }
}

/// Feedback no pointer-down, instantâneo.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? s.width : s.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let r = rows.count - 1
            rows[r].width += rows[r].indices.isEmpty ? s.width : s.width + spacing
            rows[r].height = max(rows[r].height, s.height)
            rows[r].indices.append(i)
        }
        return rows
    }
}

// MARK: - Queue

struct QueueSection: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !store.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Downloads")
                        .font(.system(size: 15, weight: .semibold))
                    if store.activeCount > 0 {
                        Text("\(store.activeCount) em andamento")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    if store.jobs.contains(where: { !$0.isActive }) {
                        Button("Limpar concluídos") {
                            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Motion.settle) { store.clearFinished() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)

                VStack(spacing: 0) {
                    ForEach(store.jobs) { job in
                        DownloadJobRow(job: job)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            ))
                        if job.id != store.jobs.last?.id {
                            Divider().padding(.leading, 86).opacity(0.5)
                        }
                    }
                }
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.settle, value: store.jobs.map(\.id))
        }
    }
}

struct DownloadJobRow: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppState.self) private var app
    let job: DownloadJob
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: job.thumbnail) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 62, height: 40)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Image(systemName: job.options.mode.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.6), in: .circle)
                    .padding(3)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(job.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(job.options.summary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }

                if job.isActive {
                    ProgressTrack(value: job.progress, indeterminate: job.state == .processing || (job.state == .downloading && job.progress == 0),
                                  tint: job.platform.tint)
                }

                statusLine
            }

            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
        .contextMenu {
            if job.state == .done {
                Button("Abrir") { job.open() }
                Button("Mostrar no Finder") { job.reveal() }
                if let f = job.fileURL { Button("Converter…") { app.convert([f]) } }
            }
            Button("Copiar link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.url, forType: .string)
            }
            Divider()
            Button(job.isActive ? "Cancelar" : "Remover da lista", role: .destructive) { store.remove(job) }
        }
        .onTapGesture(count: 2) { if job.state == .done { job.open() } }
    }

    @ViewBuilder private var statusLine: some View {
        switch job.state {
        case .done:
            Label(job.detail, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(msg)
        case .cancelled:
            Text("Cancelado").font(.system(size: 11)).foregroundStyle(.secondary)
        default:
            Text(job.detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            switch job.state {
            case .done:
                IconButton(symbol: "play.fill", help: "Abrir") { job.open() }
                IconButton(symbol: "magnifyingglass", help: "Mostrar no Finder") { job.reveal() }
                if let f = job.fileURL {
                    IconButton(symbol: "arrow.triangle.2.circlepath", help: "Enviar para o Converter") { app.convert([f]) }
                }
            case .failed, .cancelled:
                IconButton(symbol: "arrow.clockwise", help: "Tentar de novo") { store.retry(job) }
                IconButton(symbol: "xmark", help: "Remover") { store.remove(job) }
            default:
                IconButton(symbol: "xmark", help: "Cancelar") { job.cancel() }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
    }
}

struct ProgressTrack: View {
    let value: Double
    let indeterminate: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if indeterminate {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0), tint, tint.opacity(0)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: geo.size.width * phase)
                        .opacity(reduceMotion ? 0.6 : 1)
                } else {
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(4, geo.size.width * value))
                        .animation(.linear(duration: 0.25), value: value)
                }
            }
            .clipShape(.capsule)
        }
        .frame(height: 5)
        .onAppear(perform: startShimmer)
        .onChange(of: indeterminate) { startShimmer() }
    }

    private func startShimmer() {
        guard indeterminate, !reduceMotion else { return }
        phase = -0.3
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.0 }
    }
}

// MARK: - Footer

struct FooterBar: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        @Bindable var store = store

        HStack(spacing: 10) {
            Button {
                store.chooseDestination()
            } label: {
                Label(abbreviated(store.destination.path), systemImage: "folder.fill")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.glass)
            .help("Pasta de destino — clique para trocar")

            Button {
                NSWorkspace.shared.open(store.destination)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.glass)
            .help("Abrir pasta no Finder")

            Spacer()

            Menu {
                Picker("Cookies do navegador", selection: $store.cookies) {
                    ForEach(CookieSource.allCases) { c in Text(c.label).tag(c) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(store.cookies == .none ? "Sem login" : "Login: \(store.cookies.label)", systemImage: "person.crop.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Usa a sessão de um navegador para posts privados ou que exigem login (comum no Instagram).")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
