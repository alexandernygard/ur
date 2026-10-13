import SwiftUI

struct ProjectsView: View {
    @Environment(Store.self) private var store
    @State private var newName = ""
    @State private var newGroup: UUID?
    @State private var confirmDelete: Project?
    @State private var confirmDeleteGroup: ProjectGroup?
    @State private var naming: GroupNaming?
    @State private var groupName = ""
    @State private var showArchived = false
    @FocusState private var newFocused: Bool

    /// The "New group" prompt. `project` joins the group once it's created.
    struct GroupNaming { var project: UUID? }

    var body: some View {
        let sections = store.sections(store.activeProjects)
        let archived = store.data.projects.filter(\.archived)
        let hasGroups = !store.data.groups.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TextField("New project", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($newFocused)
                    .onSubmit(add)
                if hasGroups {
                    Picker("Group", selection: $newGroup) {
                        Text("No group").tag(UUID?.none)
                        Divider()
                        ForEach(store.data.groups) { g in Text(g.name).tag(UUID?.some(g.id)) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .help("Group for the new project")
                }
                Button("Add project", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("New group…") { askForGroup() }
            }
            .padding(20)

            Text(hasGroups
                 ? "Drag to reorder within a group, and use the group menu on a row to move a project. The first nine active projects get ⌘1–⌘9."
                 : "Drag to reorder. The first nine active projects get ⌘1–⌘9. Groups, such as a client, add up the time of the projects in them.")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            List {
                ForEach(sections, id: \.group?.id) { section in
                    if let g = section.group {
                        Section {
                            rows(section.projects, group: g.id)
                            if section.projects.isEmpty {
                                Text("No projects yet. Pick \(g.name) in a project's group menu, or choose it next to New project.")
                                    .font(.callout)
                                    .foregroundStyle(Theme.inkSoft)
                                    .padding(.vertical, 4)
                            }
                        } header: {
                            GroupHeader(group: g, projects: section.projects,
                                        onAdd: { newGroup = g.id; newFocused = true },
                                        onDelete: { confirmDeleteGroup = g })
                        }
                    } else if !section.projects.isEmpty || !hasGroups {
                        Section {
                            rows(section.projects, group: nil)
                        } header: {
                            if hasGroups { Text("Not in a group").font(.callout.weight(.semibold)).foregroundStyle(Theme.inkSoft) }
                        }
                    }
                }
                if !archived.isEmpty {
                    Section {
                        if showArchived {
                            ForEach(archived) { p in
                                ProjectRow(project: binding(p.id), shortcut: nil, total: store.totalTime(p.id)) {
                                    confirmDelete = p
                                }
                            }
                        }
                    } header: {
                        Button {
                            showArchived.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(showArchived ? 90 : 0))
                                    .frame(width: 12)
                                Image(systemName: "archivebox")
                                Text("Archived").fontWeight(.semibold)
                                Text("\(archived.count)").foregroundStyle(Theme.inkSoft)
                            }
                            .font(.callout)
                            .foregroundStyle(Theme.ink)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 14)
                        .help(showArchived ? "Hide archived projects" : "Show archived projects")
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Projects")
        .navigationSubtitle(archived.isEmpty ? "\(store.activeProjects.count) active" : "\(store.activeProjects.count) active, \(archived.count) archived")
        .onAppear { takeNewProjectRequest() }
        .onChange(of: store.wantsNewProject) { takeNewProjectRequest() }
        .onReceive(NotificationCenter.default.publisher(for: .newGroup)) { note in
            askForGroup(for: note.object as? UUID)
        }
        .alert("New group", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $groupName)
            Button("Create group") { createGroup() }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text("For example a client. The group shows the combined time of its projects.")
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
        .alert("Delete the group “\(confirmDeleteGroup?.name ?? "")”?", isPresented: Binding(get: { confirmDeleteGroup != nil }, set: { if !$0 { confirmDeleteGroup = nil } })) {
            Button("Delete group", role: .destructive) {
                if let g = confirmDeleteGroup {
                    if newGroup == g.id { newGroup = nil }
                    store.deleteGroup(g.id)
                }
                confirmDeleteGroup = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteGroup = nil }
        } message: {
            Text("Its projects and their time are kept, without a group.")
        }
    }

    @ViewBuilder
    private func rows(_ projects: [Project], group: UUID?) -> some View {
        ForEach(projects) { p in
            ProjectRow(project: binding(p.id), shortcut: shortcut(for: p), total: store.totalTime(p.id)) {
                confirmDelete = p
            }
        }
        .onMove { store.moveProjects(in: group, from: $0, to: $1) }
    }

    private func binding(_ id: UUID) -> Binding<Project> {
        Binding(
            get: { store.project(id) ?? Project(id: id, name: "", colorIndex: 0) },
            set: { new in
                if let i = store.data.projects.firstIndex(where: { $0.id == id }) { store.data.projects[i] = new }
            }
        )
    }

    private func shortcut(for p: Project) -> String? {
        guard let i = store.activeProjects.firstIndex(where: { $0.id == p.id }), i < 9 else { return nil }
        return "⌘\(i + 1)"
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.addProject(name, group: newGroup)
        newName = ""
        newFocused = true
    }

    private func takeNewProjectRequest() {
        guard store.wantsNewProject else { return }
        store.wantsNewProject = false
        DispatchQueue.main.async { newFocused = true }
    }

    private func askForGroup(for project: UUID? = nil) {
        groupName = ""
        naming = GroupNaming(project: project)
    }

    private func createGroup() {
        let name = groupName.trimmingCharacters(in: .whitespaces)
        let project = naming?.project
        naming = nil
        guard !name.isEmpty else { return }
        let g = store.data.groups.first { $0.name.lowercased() == name.lowercased() } ?? store.addGroup(name)
        if let project { store.setGroup(project, to: g.id) } else { newGroup = g.id }
    }
}

/// A group's name (editable), its combined time and its actions.
struct GroupHeader: View {
    @Environment(Store.self) private var store
    let group: ProjectGroup
    let projects: [Project]
    let onAdd: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let i = store.data.groups.firstIndex { $0.id == group.id } ?? 0
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(Theme.inkSoft)
            TextField("Group name", text: Binding(
                get: { group.name },
                set: { new in
                    if let i = store.data.groups.firstIndex(where: { $0.id == group.id }) { store.data.groups[i].name = new }
                }
            ))
            .textFieldStyle(.plain)
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .frame(minWidth: 160)
            Text("\(projects.count) \(projects.count == 1 ? "project" : "projects")")
                .font(.callout)
                .foregroundStyle(Theme.inkSoft)
            Spacer()
            // Archived projects still count towards the group's time.
            Text(Fmt.hmm(store.data.projects.filter { $0.groupID == group.id }.reduce(0) { $0 + store.totalTime($1.id) }))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 70, alignment: .trailing)
                .help("Total time in \(group.name)")
            // Line the total up with the project totals below.
            Color.clear.frame(width: 34, height: 1)
            Menu {
                Button("Add a project to \(group.name)", action: onAdd)
                Divider()
                Button("Move group up") { store.moveGroup(group.id, by: -1) }.disabled(i == 0)
                Button("Move group down") { store.moveGroup(group.id, by: 1) }.disabled(i == store.data.groups.count - 1)
                Divider()
                Button("Delete group…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 60)
            .help("Group actions")
            Color.clear.frame(width: 16, height: 1)
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

struct ProjectRow: View {
    @Environment(Store.self) private var store
    @Binding var project: Project
    let shortcut: String?
    let total: TimeInterval
    let onDelete: () -> Void

    /// A name can't be left blank; it goes back to "Untitled project".
    private func tidyName() {
        let n = project.name.trimmingCharacters(in: .whitespaces)
        if n != project.name { project.name = n.isEmpty ? "Untitled project" : n }
        else if n.isEmpty { project.name = "Untitled project" }
    }

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
                .onSubmit { tidyName() }
                .onDisappear { tidyName() }
                .font(.body.weight(.medium))
                .frame(minWidth: 160)
            Menu {
                Picker("Group", selection: Binding(get: { project.groupID }, set: { store.setGroup(project.id, to: $0) })) {
                    Text("No group").tag(UUID?.none)
                    ForEach(store.data.groups) { g in Text(g.name).tag(UUID?.some(g.id)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("New group…") {
                    NotificationCenter.default.post(name: .newGroup, object: project.id)
                }
            } label: {
                Text(store.group(project.groupID)?.name ?? "No group")
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(Theme.inkSoft)
            .frame(width: 150, alignment: .leading)
            .help("Group")
            Spacer()
            Text(Fmt.hmm(total))
                .monospacedDigit()
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 70, alignment: .trailing)
            Group {
                if let shortcut { KeyHint(text: shortcut) } else { Color.clear }
            }
            .frame(width: 34)
            Button {
                store.setArchived(project.id, !project.archived)
            } label: {
                Image(systemName: project.archived ? "arrow.uturn.backward.circle" : "archivebox")
            }
            .buttonStyle(.borderless)
            .frame(width: 28)
            .help(project.archived ? "Restore \(project.name)" : "Archive \(project.name): hide it from tracking but keep its time")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete project")
        }
        .padding(.vertical, 4)
        .opacity(project.archived ? 0.6 : 1)
        .contextMenu {
            Button(project.archived ? "Restore" : "Archive") { store.setArchived(project.id, !project.archived) }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }
}
