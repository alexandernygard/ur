import SwiftUI

struct ProjectsView: View {
    @Environment(Store.self) private var store
    @State private var newName = ""
    @State private var newClient = ""
    @State private var confirmDelete: Project?
    @FocusState private var newFocused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TextField("New project", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($newFocused)
                    .onSubmit(add)
                TextField("Client (optional)", text: $newClient)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(add)
                Button("Add project", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)

            Text("Drag to reorder. The first nine active projects get ⌘1–⌘9.")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            List {
                ForEach($store.data.projects) { $p in
                    ProjectRow(project: $p, shortcut: shortcut(for: p), total: store.totalTime(p.id)) {
                        confirmDelete = p
                    }
                }
                .onMove { store.data.projects.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Projects")
        .navigationSubtitle("\(store.activeProjects.count) active")
        .onReceive(NotificationCenter.default.publisher(for: .focusNewProject)) { _ in
            DispatchQueue.main.async { newFocused = true }
        }
        .alert("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete project and its time", role: .destructive) {
                if let p = confirmDelete { store.deleteProject(p.id) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("This removes \(Fmt.dur(store.totalTime(confirmDelete?.id ?? UUID()))) of tracked time. Archive the project instead to keep its history.")
        }
    }

    private func shortcut(for p: Project) -> String? {
        guard let i = store.activeProjects.firstIndex(where: { $0.id == p.id }), i < 9 else { return nil }
        return "⌘\(i + 1)"
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.addProject(name, client: newClient.trimmingCharacters(in: .whitespaces))
        newName = ""
        newClient = ""
        newFocused = true
    }
}

struct ProjectRow: View {
    @Binding var project: Project
    let shortcut: String?
    let total: TimeInterval
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Array(Theme.projectPalette.enumerated()), id: \.offset) { i, c in
                    Button {
                        project.colorIndex = i
                    } label: {
                        Label(c.name, systemImage: project.colorIndex == i ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                Dot(color: Theme.project(project.colorIndex), size: 14)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Colour")

            TextField("Name", text: $project.name)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .frame(minWidth: 160)
            TextField("Client", text: $project.client)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 160)
            Spacer()
            Text(Fmt.hmm(total))
                .monospacedDigit()
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 70, alignment: .trailing)
            Group {
                if let shortcut { KeyHint(text: shortcut) } else { Color.clear }
            }
            .frame(width: 34)
            Button(project.archived ? "Restore" : "Archive") { project.archived.toggle() }
                .buttonStyle(.borderless)
                .frame(width: 60)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete project")
        }
        .padding(.vertical, 4)
        .opacity(project.archived ? 0.5 : 1)
    }
}
