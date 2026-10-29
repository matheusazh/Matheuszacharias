import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var confirmDelete: Project?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if !model.queue.jobs.isEmpty {
                Section {
                    ForEach(model.queue.jobs) { job in
                        JobRow(job: job)
                            .tag(AppModel.Selection.job(job.id))
                            .contextMenu {
                                if job.isActive {
                                    Button("Cancelar") { model.queue.cancel(job) }
                                } else {
                                    if case .failed = job.status { Button("Tentar de novo") { model.queue.retry(job) } }
                                    if job.status == .cancelled { Button("Tentar de novo") { model.queue.retry(job) } }
                                    Button("Remover da fila") { model.queue.remove(job) }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Fila")
                        Spacer()
                        if model.queue.jobs.contains(where: { !$0.isActive }) {
                            Button("Limpar") {
                                withAnimation(Motion.standard(reduceMotion)) { model.queue.clearFinished() }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(ProjectKind.allCases) { kind in
                Section(kind.plural) {
                    let items = model.library.projects(of: kind)
                    if items.isEmpty {
                        Text(kind == .music ? "Nenhuma música ainda" : "Nenhuma fala ainda")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .selectionDisabled()
                    }
                    ForEach(items) { project in
                        ProjectRow(project: project, renaming: renaming == project.id, newName: $newName) {
                            model.library.rename(project.id, to: newName)
                            renaming = nil
                        }
                        .tag(AppModel.Selection.project(project.id))
                        .contextMenu {
                            Button("Renomear") { newName = project.title; renaming = project.id }
                            Button("Exportar…") { model.exportRequest = project.id }
                            Button("Mostrar no Finder") { model.library.reveal(project.id) }
                            Divider()
                            Button("Apagar…", role: .destructive) { confirmDelete = project }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(Motion.standard(reduceMotion), value: model.queue.jobs.map(\.id))
        .animation(Motion.standard(reduceMotion), value: model.library.projects.map(\.id))
        .safeAreaInset(edge: .bottom) { AddBar() }
        .confirmationDialog("Apagar \"\(confirmDelete?.title ?? "")\"?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Mover para o Lixo", role: .destructive) {
                if let p = confirmDelete { model.deleteProject(p.id) }
                confirmDelete = nil
            }
        } message: {
            Text("As faixas separadas vão para o Lixo. Dá para recuperar pelo Finder.")
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    let renaming: Bool
    @Binding var newName: String
    let commit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(project.kind == .music ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.teal.gradient))
                Image(systemName: project.hasVideo ? "video.fill" : project.kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Nome", text: $newName)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onAppear { focused = true }
                        .onChange(of: focused) { _, f in if !f { commit() } }
                } else {
                    Text(project.title).lineLimit(1)
                }
                Text(project.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch job.status {
                case .running:
                    ProgressRing(progress: job.progress, lineWidth: 3)
                case .waiting:
                    Circle().strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .cancelled:
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 18))
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        switch job.status {
        case .running: "\(job.stage) · \(Int(job.progress * 100))%"
        case .waiting: "Na fila · \(job.kind.title)"
        case .done: "Pronto"
        case .failed(let m): m
        case .cancelled: "Cancelado"
        }
    }
}

private struct AddBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Button { model.openPanel() } label: {
                Label("Abrir", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .help("Abrir áudio ou vídeo (⌘O)")
            Button { model.pasteLink() } label: {
                Label("Colar link", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .help("Colar link do YouTube, Instagram… (⇧⌘V)")
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
        .padding(12)
    }
}
