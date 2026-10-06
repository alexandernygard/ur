import SwiftUI
import AppKit

/// ⌘K. Type a project to start it; add a time range ("acme 9-11:30") or a duration ("acme 1h30")
/// to log time instead. Anything after the time becomes the note.
struct CommandPalette: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var index = 0
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id = UUID()
        var icon: String
        var color: Color?
        var title: String
        var detail: String = ""
        var hint: String = ""
        var run: () -> Void
    }

    var body: some View {
        let items = results()
        ZStack(alignment: .top) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "command")
                        .foregroundStyle(Theme.inkSoft)
                    TextField("Start a project, or log time like “design 9-11:30 review”", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 19))
                        .focused($focused)
                        .onSubmit { run(items) }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            if items.isEmpty {
                                Text("No matches. Press Return to create a project with this name.")
                                    .foregroundStyle(Theme.inkSoft)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            }
                            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                                row(item, selected: i == index)
                                    .id(i)
                                    .onTapGesture { item.run(); close() }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: index) { proxy.scrollTo(index) }
                }

                Divider()
                HStack(spacing: 14) {
                    Text("↑↓ choose")
                    Text("↩ run")
                    Text("esc close")
                    Spacer()
                    Text("Logs to \(targetDay.isToday ? "today" : Fmt.dayMonth.string(from: targetDay))")
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 70)
        }
        .onAppear {
            focused = true
            installKeys()
        }
        .onDisappear { removeKeys() }
        .onChange(of: query) { index = 0 }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if let c = item.color {
                Dot(color: c, size: 10).frame(width: 18)
            } else {
                Image(systemName: item.icon).frame(width: 18).foregroundStyle(Theme.inkSoft)
            }
            Text(item.title).foregroundStyle(Theme.ink)
            if !item.detail.isEmpty {
                Text(item.detail).foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            if !item.hint.isEmpty { KeyHint(text: item.hint) }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.gran.opacity(0.16) : .clear))
        .contentShape(Rectangle())
    }

    // MARK: Keys

    /// Arrow keys and Escape are caught before the text field sees them.
    private func installKeys() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: index += 1; return nil
            case 126: index = max(0, index - 1); return nil
            case 53: close(); return nil
            default: return event
            }
        }
    }

    private func removeKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func close() {
        removeKeys()
        store.showPalette = false
    }

    private func run(_ items: [Item]) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if items.isEmpty {
            if !q.isEmpty { store.start(store.addProject(q).id) }
        } else {
            items[min(index, items.count - 1)].run()
        }
        close()
    }

    // MARK: Parsing

    private var targetDay: Date {
        store.pane == .today || store.pane == .week ? store.selectedDay : Date().startOfDay
    }

    enum When {
        case now
        case range(Date, Date)
        case duration(TimeInterval)
    }

    private func parse(_ raw: String) -> (project: String, note: String, when: When) {
        var s = raw
        var when = When.now
        var note = ""
        if let r = TimeParse.range(in: s) {
            let day = targetDay
            let a = day.at(hour: r.start.0, minute: r.start.1)
            var b = day.at(hour: r.end.0, minute: r.end.1)
            if b <= a { b = b.adding(days: 1) }
            when = .range(a, b)
            note = String(s[r.span.upperBound...])
            s = String(s[..<r.span.lowerBound])
        } else if let d = TimeParse.duration(in: s) {
            when = .duration(d.seconds)
            note = String(s[d.span.upperBound...])
            s = String(s[..<d.span.lowerBound])
        }
        return (s.trimmingCharacters(in: .whitespaces), note.trimmingCharacters(in: .whitespaces), when)
    }

    private func durationSlot(_ seconds: TimeInterval) -> (Date, Date) {
        let day = targetDay
        if day.isToday {
            let end = Date().snapped(to: store.prefs.snapMinutes)
            return (end.addingTimeInterval(-seconds), end)
        }
        let start = store.entries(on: day).last?.end ?? store.workday(day)?.start ?? day.at(hour: 9, minute: 0)
        return (start, start.addingTimeInterval(seconds))
    }

    private func results() -> [Item] {
        let raw = query.trimmingCharacters(in: .whitespaces)
        let parsed = parse(raw)
        var items: [Item] = []

        // When there is no time in the query, words after the project name become the note.
        var projectQuery = parsed.project
        var note = parsed.note
        if case .now = parsed.when, !projectQuery.isEmpty {
            let words = projectQuery.split(separator: " ").map(String.init)
            for n in stride(from: words.count, through: 1, by: -1) {
                let head = words.prefix(n).joined(separator: " ")
                if store.activeProjects.contains(where: { Fuzzy.score($0.name, head) >= 40 }) {
                    projectQuery = head
                    note = words.dropFirst(n).joined(separator: " ")
                    break
                }
            }
        }

        let ranked = store.activeProjects.enumerated()
            .map { (i: $0.offset, p: $0.element, s: Fuzzy.score($0.element.name, projectQuery)) }
            .filter { $0.s > 0 }
            .sorted { $0.s != $1.s ? $0.s > $1.s : $0.i < $1.i }

        let noteSuffix = note.isEmpty ? "" : "“\(note)”"

        for r in ranked.prefix(projectQuery.isEmpty ? 12 : 6) {
            let p = r.p
            let color = Theme.project(p.colorIndex)
            switch parsed.when {
            case .now:
                let isRunning = store.running?.projectID == p.id
                items.append(Item(icon: "play", color: color,
                                  title: isRunning && note.isEmpty ? "Stop \(p.name)" : "Start \(p.name)",
                                  detail: noteSuffix, hint: r.i < 9 ? "⌘\(r.i + 1)" : "") {
                    if isRunning && note.isEmpty { store.stop() } else { store.start(p.id, note: note) }
                })
            case .range(let a, let b):
                items.append(Item(icon: "plus", color: color, title: "Log \(p.name)",
                                  detail: "\(Fmt.range(a, b))  \(Fmt.dur(b.timeIntervalSince(a)))  \(noteSuffix)") {
                    store.save(EntryDraft(projectID: p.id, start: a, end: b, note: note))
                    store.selectedDay = a.startOfDay
                })
            case .duration(let d):
                let (a, b) = durationSlot(d)
                items.append(Item(icon: "plus", color: color, title: "Log \(Fmt.dur(d)) on \(p.name)",
                                  detail: "\(Fmt.range(a, b))  \(noteSuffix)") {
                    store.save(EntryDraft(projectID: p.id, start: a, end: b, note: note))
                })
            }
        }

        let name = parsed.project
        if !name.isEmpty && !store.data.projects.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            items.append(Item(icon: "plus.square", title: "Create project “\(name)”", detail: "and start it") {
                store.start(store.addProject(name).id, note: parsed.note)
            })
        }

        if case .now = parsed.when {
            items += commands().filter { raw.isEmpty || Fuzzy.score($0.title, raw) >= 40 }
        }
        return items
    }

    private func commands() -> [Item] {
        var c: [Item] = []
        if store.running != nil {
            c.append(Item(icon: "stop.fill", title: "Stop timer", hint: "⌘.") { store.stop() })
        } else {
            c.append(Item(icon: "arrow.uturn.backward", title: "Resume last", hint: "⌘R") { store.resumeLast() })
        }
        c.append(Item(icon: "sunrise", title: store.dayToggleTitle, hint: "⌘D") { store.toggleDay() })
        c.append(Item(icon: "plus", title: "Add time", hint: "⌘N") {
            DispatchQueue.main.async { store.newEntry() }
        })
        for (i, p) in Pane.allCases.enumerated() {
            c.append(Item(icon: p.icon, title: "Go to \(p.title)", hint: "⌥⌘\(i + 1)") { store.pane = p })
        }
        c.append(Item(icon: "keyboard", title: "Keyboard shortcuts", hint: "⌘/") {
            DispatchQueue.main.async { store.showShortcuts = true }
        })
        return c
    }
}
