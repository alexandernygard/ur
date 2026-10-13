import SwiftUI
import UniformTypeIdentifiers

/// Projects laid out as cards, one per group. Drag a project to reorder it or move it to another
/// group, drag a group by its handle to reorder groups, and add projects right inside a group.
/// Selecting a project opens it in the inspector on the right.
struct ProjectsView: View {
    @Environment(Store.self) private var store
    @State private var selected: UUID?
    @State private var hovered: UUID?
    /// The card showing the new-project field: `.some(nil)` is the ungrouped card.
    @State private var addingIn: UUID??
    @State private var newName = ""
    @State private var addingGroup = false
    @State private var newGroupName = ""
    /// A project waiting to join the group being created from its "Move to" menu.
    @State private var groupFor: UUID?
    @State private var renamingGroup: UUID?
    @State private var renamingProject: UUID?
    @State private var dragging: Dragging?
    @State private var drop: Target?
    @State private var confirmDelete: Project?
    @State private var confirmDeleteGroup: ProjectGroup?
    @State private var showArchived = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case newProject, newGroup, renameGroup, renameProject }
    enum Dragging: Equatable { case project(UUID), group(UUID) }
    /// Where a drop would land: a project before another (or at the end of a group), or a
    /// group before another (or at the end).
    enum Target: Equatable {
        case project(before: UUID?, group: UUID?)
        case group(before: UUID?)
    }

    var body: some View {
        let facts = store.projectFacts()
        let sections = store.sections(store.activeProjects)
        let archived = store.data.projects.filter(\.archived)
        let hasGroups = !store.data.groups.isEmpty

        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(archived: archived.count)
                    ForEach(sections, id: \.group?.id) { section in
                        if section.group != nil || !section.projects.isEmpty || !hasGroups || addingIn == .some(nil) {
                            card(section.group, section.projects, facts: facts, hasGroups: hasGroups)
                        } else {
                            ungroupedDropZone
                        }
                    }
                    newGroupCard
                    if !archived.isEmpty { archivedCard(archived, facts: facts) }
                }
                .padding(28)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { deselect() })
            }
            if let id = selected, store.project(id) != nil {
                Divider()
                ProjectInspector(id: id, facts: facts[id], shortcut: shortcut(id),
                                 onDelete: { confirmDelete = store.project(id) },
                                 onNewGroup: { askForGroup(for: id) },
                                 onClose: { selected = nil })
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: selected)
        .navigationTitle("Projects")
        .onAppear { takeNewProjectRequest() }
        .onChange(of: store.wantsNewProject) { takeNewProjectRequest() }
        .onExitCommand { deselect() }
        .alert("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Project and Its Time", role: .destructive) {
                if let p = confirmDelete {
                    if selected == p.id { selected = nil }
                    store.deleteProject(p.id)
                }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("This removes \(Fmt.dur(store.totalTime(confirmDelete?.id ?? UUID()))) of tracked time. You can undo it with ⌘Z, or archive the project instead to keep its history.")
        }
        .alert("Delete the group “\(confirmDeleteGroup?.name ?? "")”?", isPresented: Binding(get: { confirmDeleteGroup != nil }, set: { if !$0 { confirmDeleteGroup = nil } })) {
            Button("Delete Group", role: .destructive) {
                if let g = confirmDeleteGroup { store.deleteGroup(g.id) }
                confirmDeleteGroup = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteGroup = nil }
        } message: {
            Text("Its projects and their time are kept, without a group.")
        }
    }

    // MARK: Header

    private func header(archived: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Projects")
                    .font(.system(size: 34, weight: .light).width(.compressed))
                    .foregroundStyle(Theme.ink)
                Text(archived == 0 ? "\(store.activeProjects.count) active" : "\(store.activeProjects.count) active, \(archived) archived")
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Button { askForGroup() } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                .controlSize(.large)
                Button { startAdding(in: selectedGroup) } label: {
                    Label("New Project", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.gran)
                .controlSize(.large)
                .help("New project (⌘N)")
            }
            Text("Drag a project to reorder it or move it to another group, and drag a group by its handle. The first nine projects get ⌘1–⌘9. Double-click a name to rename it.")
                .font(.callout)
                .foregroundStyle(Theme.inkSoft)
        }
        .padding(.bottom, 8)
    }

    // MARK: Cards

    @ViewBuilder
    private func card(_ group: ProjectGroup?, _ projects: [Project], facts: [UUID: ProjectFacts], hasGroups: Bool) -> some View {
        let gid = group?.id
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(group, projects, facts: facts, hasGroups: hasGroups)
                .zone(target(project: .project(before: projects.first?.id, group: gid),
                             group: group.map { .group(before: $0.id) }),
                      drop: $drop, perform: perform)

            if projects.isEmpty && addingIn != .some(gid) {
                Text(group == nil ? "No projects yet." : "Drag projects here, or add one.")
                    .font(.callout)
                    .foregroundStyle(Theme.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(drop == .project(before: nil, group: gid) ? Theme.gran : Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .zone(target(project: .project(before: nil, group: gid), group: nil), drop: $drop, perform: perform)
            }

            ForEach(projects) { p in
                row(p, facts: facts[p.id], group: gid)
                    .zone(target(project: .project(before: p.id, group: gid), group: nil), drop: $drop, perform: perform)
            }

            footer(gid)
                .zone(target(project: .project(before: nil, group: gid), group: nil), drop: $drop, perform: perform)
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .overlay(alignment: .top) { insertionLine(drop == .group(before: gid) && gid != nil).offset(y: -8) }
        .opacity(dragging == .group(gid ?? UUID()) ? 0.5 : 1)
    }

    @ViewBuilder
    private func cardHeader(_ group: ProjectGroup?, _ projects: [Project], facts: [UUID: ProjectFacts], hasGroups: Bool) -> some View {
        // Archived projects still count towards the group's time.
        let total = store.data.projects.filter { $0.groupID == group?.id && (group != nil || !$0.archived) }
            .reduce(0) { $0 + (facts[$1.id]?.total ?? 0) }
        HStack(spacing: 10) {
            if let g = group {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
                    .cursor(.openHand)
                    .help("Drag to reorder groups")
                    .onDrag {
                        dragging = .group(g.id)
                        return NSItemProvider(object: g.name as NSString)
                    } preview: {
                        Label(g.name, systemImage: "folder").padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                    }
                if renamingGroup == g.id {
                    TextField("Group name", text: groupName(g.id))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .focused($focus, equals: .renameGroup)
                        .onSubmit { renamingGroup = nil }
                        .onExitCommand { renamingGroup = nil }
                        .frame(maxWidth: 260)
                } else {
                    Text(g.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .onTapGesture(count: 2) { rename(group: g.id) }
                }
            } else {
                Image(systemName: hasGroups ? "tray" : "square.stack")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(width: 18, height: 24)
                Text(hasGroups ? "No group" : "All projects")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hasGroups ? Theme.inkSoft : Theme.ink)
            }
            Text("\(projects.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.inkSoft)
            Spacer()
            if total > 0 {
                Text(Fmt.dur(total))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .help(group.map { "All time in \($0.name), archived projects included" } ?? "All time")
            }
            if let g = group {
                Menu {
                    Button("Add Project to \(g.name)") { startAdding(in: g.id) }
                    Button("Rename") { rename(group: g.id) }
                    Divider()
                    Button("Delete Group…", role: .destructive) { confirmDeleteGroup = g }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 34)
                .help("Group actions")
            } else {
                Color.clear.frame(width: 34, height: 1)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .contextMenu {
            if let g = group {
                Button("Add Project to \(g.name)") { startAdding(in: g.id) }
                Button("Rename") { rename(group: g.id) }
                Divider()
                Button("Delete Group…", role: .destructive) { confirmDeleteGroup = g }
            }
        }
    }

    @ViewBuilder
    private func footer(_ gid: UUID?) -> some View {
        VStack(spacing: 0) {
            insertionLine(drop == .project(before: nil, group: gid) && hasProjects(gid))
                .padding(.horizontal, 10)
            if addingIn == .some(gid) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 12)
                    Dot(color: Theme.project(nextColor), size: 12)
                    TextField(gid.flatMap { store.group($0) }.map { "New project in \($0.name)" } ?? "New project", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .focused($focus, equals: .newProject)
                        .onSubmit { addProject(in: gid) }
                        .onExitCommand { stopAdding() }
                    Text("↩ add  esc done").font(.caption).foregroundStyle(Theme.inkSoft)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.gran.opacity(0.07)))
                .padding(.horizontal, 6)
            } else {
                Button { startAdding(in: gid) } label: {
                    Label("Add project", systemImage: "plus")
                        .font(.callout)
                        .foregroundStyle(Theme.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .padding(.leading, 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// When every project has a group, the ungrouped card shrinks to a place to drop one.
    private var ungroupedDropZone: some View {
        let active = drop == .project(before: nil, group: nil)
        return Label("Drop a project here to take it out of its group", systemImage: "tray")
            .font(.callout)
            .foregroundStyle(active ? Theme.gran : Theme.inkSoft)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(active ? Theme.gran : Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .opacity(dragging.map { if case .project = $0 { return 1 } else { return 0.5 } } ?? 0.5)
            .zone(target(project: .project(before: nil, group: nil), group: nil), drop: $drop, perform: perform)
    }

    @ViewBuilder
    private var newGroupCard: some View {
        Group {
            if addingGroup {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").foregroundStyle(Theme.gran)
                    TextField("Group name, such as a client", text: $newGroupName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .focused($focus, equals: .newGroup)
                        .onSubmit(createGroup)
                        .onExitCommand { addingGroup = false; groupFor = nil }
                    Button("Cancel") { addingGroup = false; groupFor = nil }
                    Button("Create Group", action: createGroup)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.gran)
                        .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.gran.opacity(0.6)))
            } else {
                Button { askForGroup() } label: {
                    Label(store.data.groups.isEmpty ? "New group, such as a client, to add up the time of its projects" : "New group", systemImage: "folder.badge.plus")
                        .font(.callout)
                        .foregroundStyle(Theme.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .top) { insertionLine(drop == .group(before: nil)).offset(y: -8) }
        .zone(target(project: nil, group: .group(before: nil)), drop: $drop, perform: perform)
    }

    private func archivedCard(_ archived: [Project], facts: [UUID: ProjectFacts]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showArchived.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showArchived ? 90 : 0))
                        .frame(width: 18)
                    Image(systemName: "archivebox")
                    Text("Archived").fontWeight(.semibold)
                    Text("\(archived.count)").foregroundStyle(Theme.inkSoft)
                    Spacer()
                    Text("Hidden from tracking, time kept").font(.caption).foregroundStyle(Theme.inkSoft)
                }
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showArchived {
                ForEach(archived) { p in row(p, facts: facts[p.id], group: p.groupID) }
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .padding(.top, 10)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ p: Project, facts f: ProjectFacts?, group gid: UUID?) -> some View {
        let color = Theme.project(p.colorIndex)
        let isSelected = selected == p.id
        let isHovered = hovered == p.id
        let isRunning = store.running?.projectID == p.id
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkSoft.opacity(p.archived ? 0 : isHovered ? 0.9 : 0.3))
                .frame(width: 12)
            Dot(color: color, size: 12)
            if renamingProject == p.id {
                TextField("Name", text: projectName(p.id))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused($focus, equals: .renameProject)
                    .onSubmit { finishRename() }
                    .onExitCommand { finishRename() }
            } else {
                Text(p.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            if isRunning {
                HStack(spacing: 4) {
                    Circle().fill(Theme.gran).frame(width: 6, height: 6)
                    Text("Tracking")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.gran)
            }
            if p.archived, let g = store.group(p.groupID) {
                Text(g.name).font(.caption).foregroundStyle(Theme.inkSoft)
            }
            Spacer(minLength: 16)
            WeekBars(weeks: f?.weeks ?? [], color: color)
                .frame(width: 84, height: 18)
                .help("Last 12 weeks")
            Text(isRunning ? "Now" : f?.last.map(Self.lastUsed) ?? "Never")
                .font(.callout)
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 92, alignment: .trailing)
                .help("Last tracked")
            Text(Fmt.dur(f?.total ?? 0))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(width: 80, alignment: .trailing)
            Group {
                if p.archived {
                    Button { store.setArchived(p.id, false) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Restore \(p.name)")
                } else if let s = shortcut(p.id) {
                    KeyHint(text: s)
                } else {
                    Color.clear
                }
            }
            .frame(width: 34)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? color.opacity(0.13) : isHovered ? Theme.ink.opacity(0.04) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? color.opacity(0.5) : .clear))
        .overlay(alignment: .top) { insertionLine(drop == .project(before: p.id, group: gid)).offset(y: -1) }
        .padding(.horizontal, 6)
        .opacity(p.archived ? 0.65 : dragging == .project(p.id) ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? p.id : (hovered == p.id ? nil : hovered) }
        .onTapGesture(count: 2) { rename(project: p.id) }
        .simultaneousGesture(TapGesture().onEnded { select(p.id) })
        .modifier(DragSource(enabled: !p.archived) {
            dragging = .project(p.id)
            return NSItemProvider(object: p.name as NSString)
        } preview: {
            HStack(spacing: 8) {
                Dot(color: color, size: 10)
                Text(p.name).fontWeight(.medium)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
        })
        .contextMenu { menu(p) }
    }

    @ViewBuilder
    private func menu(_ p: Project) -> some View {
        if !p.archived {
            Button(store.running?.projectID == p.id ? "Stop Timer" : "Start Timer") { store.toggle(p.id) }
            Divider()
        }
        Button("Rename") { rename(project: p.id) }
        Menu("Colour") {
            ForEach(Array(Theme.projectPalette.enumerated()), id: \.offset) { i, c in
                Button { setColor(p.id, i) } label: {
                    Label(c.name, systemImage: p.colorIndex == i ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Menu("Move To") {
            Button("No Group") { store.moveProject(p.id, to: nil) }.disabled(p.groupID == nil)
            ForEach(store.data.groups) { g in
                Button(g.name) { store.moveProject(p.id, to: g.id) }.disabled(p.groupID == g.id)
            }
            Divider()
            Button("New Group…") { askForGroup(for: p.id) }
        }
        Divider()
        Button(p.archived ? "Restore" : "Archive") { store.setArchived(p.id, !p.archived) }
        Button("Delete…", role: .destructive) { confirmDelete = p }
    }

    private func insertionLine(_ on: Bool) -> some View {
        Capsule()
            .fill(Theme.gran)
            .frame(height: 3)
            .opacity(on ? 1 : 0)
            .allowsHitTesting(false)
    }

    // MARK: Drag and drop

    /// Which drop a zone accepts depends on what is being dragged.
    private func target(project: Target?, group: Target?) -> () -> Target? {
        // Reads the drag as it is when the pointer arrives, not when the view was drawn.
        {
            switch dragging {
            case .project: project
            case .group: group
            case nil: nil
            }
        }
    }

    private func perform(_ t: Target) {
        switch (dragging, t) {
        case (.project(let id), .project(let before, let group)):
            store.moveProject(id, to: group, before: before)
        case (.group(let id), .group(let before)):
            store.moveGroup(id, before: before)
        default:
            break
        }
        dragging = nil
        drop = nil
    }

    // MARK: Actions

    private var selectedGroup: UUID? { store.project(selected)?.archived == false ? store.project(selected)?.groupID : nil }

    private var nextColor: Int {
        let used = Set(store.data.projects.map(\.colorIndex))
        return (0..<Theme.projectPalette.count).first { !used.contains($0) } ?? store.data.projects.count
    }

    private func hasProjects(_ gid: UUID?) -> Bool {
        store.activeProjects.contains { $0.groupID == gid }
    }

    private func shortcut(_ id: UUID) -> String? {
        guard let i = store.activeProjects.firstIndex(where: { $0.id == id }), i < 9 else { return nil }
        return "⌘\(i + 1)"
    }

    static func lastUsed(_ d: Date) -> String {
        if d.isToday { return "Today" }
        let days = cal.dateComponents([.day], from: d.startOfDay, to: Date().startOfDay).day ?? 0
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return Fmt.dayMonth.string(from: d) }
        return Fmt.monthYear.string(from: d)
    }

    private func select(_ id: UUID) {
        if renamingProject != nil && renamingProject != id { finishRename() }
        selected = id
    }

    private func deselect() {
        if renamingProject != nil { finishRename() }
        renamingGroup = nil
        selected = nil
    }

    private func startAdding(in gid: UUID?) {
        newName = ""
        addingIn = .some(gid)
        DispatchQueue.main.async { focus = .newProject }
    }

    private func stopAdding() {
        addingIn = nil
        newName = ""
    }

    private func addProject(in gid: UUID?) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { stopAdding(); return }
        store.addProject(name, group: gid)
        // Stay open for the next one.
        newName = ""
        DispatchQueue.main.async { focus = .newProject }
    }

    private func takeNewProjectRequest() {
        guard store.wantsNewProject else { return }
        store.wantsNewProject = false
        startAdding(in: selectedGroup)
    }

    private func askForGroup(for project: UUID? = nil) {
        newGroupName = ""
        groupFor = project
        addingGroup = true
        DispatchQueue.main.async { focus = .newGroup }
    }

    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let g = store.data.groups.first { $0.name.lowercased() == name.lowercased() } ?? store.addGroup(name)
        addingGroup = false
        if let p = groupFor {
            store.moveProject(p, to: g.id)
            groupFor = nil
        } else {
            // A new group is empty, so go straight on to its first project.
            startAdding(in: g.id)
        }
    }

    private func rename(group id: UUID) {
        renamingGroup = id
        DispatchQueue.main.async { focus = .renameGroup }
    }

    private func rename(project id: UUID) {
        selected = id
        renamingProject = id
        DispatchQueue.main.async { focus = .renameProject }
    }

    private func finishRename() {
        if let id = renamingProject { store.tidyName(id) }
        renamingProject = nil
    }

    private func setColor(_ id: UUID, _ i: Int) {
        if let j = store.data.projects.firstIndex(where: { $0.id == id }) { store.data.projects[j].colorIndex = i }
    }

    private func projectName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.project(id)?.name ?? "" },
            set: { new in if let i = store.data.projects.firstIndex(where: { $0.id == id }) { store.data.projects[i].name = new } }
        )
    }

    private func groupName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.group(id)?.name ?? "" },
            set: { new in if let i = store.data.groups.firstIndex(where: { $0.id == id }) { store.data.groups[i].name = new } }
        )
    }
}

// MARK: - Inspector

/// Everything about one project: name, colour, group, its numbers, and what you can do with it.
struct ProjectInspector: View {
    @Environment(Store.self) private var store
    let id: UUID
    let facts: ProjectFacts?
    let shortcut: String?
    let onDelete: () -> Void
    let onNewGroup: () -> Void
    let onClose: () -> Void

    var body: some View {
        if let p = store.project(id) {
            let color = Theme.project(p.colorIndex)
            let isRunning = store.running?.projectID == id
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text(p.archived ? "Archived project" : "Project")
                            .font(.callout)
                            .foregroundStyle(Theme.inkSoft)
                        Spacer()
                        Button(action: onClose) { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Close (Esc)")
                    }

                    HStack(spacing: 12) {
                        Circle().fill(color).frame(width: 22, height: 22)
                        TextField("Name", text: name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 22, weight: .semibold))
                            .onSubmit { store.tidyName(id) }
                            .onDisappear { store.tidyName(id) }
                    }

                    if !p.archived {
                        Button { store.toggle(id) } label: {
                            Label(isRunning ? "Stop Timer" : "Start Timer", systemImage: isRunning ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(color)
                        .controlSize(.large)
                    }

                    field("Colour") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
                            ForEach(Array(Theme.projectPalette.enumerated()), id: \.offset) { i, c in
                                Button { setColor(i) } label: {
                                    Circle()
                                        .fill(Theme.project(i))
                                        .frame(width: 22, height: 22)
                                        .padding(3)
                                        .overlay(Circle().strokeBorder(p.colorIndex == i ? Theme.ink : .clear, lineWidth: 2))
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help(c.name)
                            }
                        }
                    }

                    field("Group") {
                        Menu {
                            Button("No Group") { store.moveProject(id, to: nil) }
                            if !store.data.groups.isEmpty { Divider() }
                            ForEach(store.data.groups) { g in
                                Button(g.name) { store.moveProject(id, to: g.id) }
                            }
                            Divider()
                            Button("New Group…", action: onNewGroup)
                        } label: {
                            Text(store.group(p.groupID)?.name ?? "No group")
                        }
                        .fixedSize()
                    }

                    field("Time") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            fact("All time", Fmt.dur(facts?.total ?? 0))
                            fact("This week", Fmt.dur(facts?.thisWeek ?? 0))
                            fact("Last tracked", isRunning ? "Now" : facts?.last.map(ProjectsView.lastUsed) ?? "Never")
                            if let shortcut { fact("Shortcut", shortcut) }
                        }
                        .font(.callout)
                    }

                    field("Last 12 weeks") {
                        WeekBars(weeks: facts?.weeks ?? [], color: color, spacing: 4, labels: true)
                            .frame(height: 64)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Button { store.setArchived(id, !p.archived) } label: {
                            Label(p.archived ? "Restore Project" : "Archive Project",
                                  systemImage: p.archived ? "arrow.uturn.backward" : "archivebox")
                        }
                        .buttonStyle(.borderless)
                        Text(p.archived ? "Brings it back to the chips, shortcuts and command bar."
                                        : "Hides it from tracking but keeps its time in the calendar and stats.")
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete Project…", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .padding(.top, 6)
                    }
                }
                .padding(20)
            }
            .background(Theme.surface)
        }
    }

    private var name: Binding<String> {
        Binding(
            get: { store.project(id)?.name ?? "" },
            set: { new in if let i = store.data.projects.firstIndex(where: { $0.id == id }) { store.data.projects[i].name = new } }
        )
    }

    private func setColor(_ i: Int) {
        if let j = store.data.projects.firstIndex(where: { $0.id == id }) { store.data.projects[j].colorIndex = i }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.inkSoft)
            content()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.inkSoft)
            Text(value).monospacedDigit().foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Pieces

/// Tracked time per week as small bars, scaled to the project's own busiest week.
struct WeekBars: View {
    let weeks: [TimeInterval]
    let color: Color
    var spacing: CGFloat = 2
    var labels = false

    var body: some View {
        let top = max(weeks.max() ?? 0, 1)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, v in
                    GeometryReader { g in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(v >= 60 ? color : Theme.line)
                                .frame(height: v >= 60 ? max(3, g.size.height * v / top) : 2)
                        }
                    }
                }
            }
            if labels {
                HStack {
                    Text("12 weeks ago")
                    Spacer()
                    Text("This week")
                }
                .font(.caption2)
                .foregroundStyle(Theme.inkSoft)
            }
        }
    }
}

/// `onDrag` only when enabled, so archived rows can't be dragged.
private struct DragSource<P: View>: ViewModifier {
    let enabled: Bool
    let data: () -> NSItemProvider
    @ViewBuilder let preview: () -> P

    func body(content: Content) -> some View {
        if enabled { content.onDrag(data, preview: preview) } else { content }
    }
}

private extension View {
    /// A drop zone. `target` says what a drop here would do with whatever is being dragged,
    /// or nil if it doesn't accept it.
    func zone(_ target: @escaping () -> ProjectsView.Target?, drop: Binding<ProjectsView.Target?>,
              perform: @escaping (ProjectsView.Target) -> Void) -> some View {
        onDrop(of: [.plainText], isTargeted: Binding(
            get: { false },
            set: { on in
                guard let t = target() else { return }
                if on { drop.wrappedValue = t } else if drop.wrappedValue == t { drop.wrappedValue = nil }
            }
        )) { _ in
            guard let t = target() else { return false }
            perform(t)
            return true
        }
    }
}
