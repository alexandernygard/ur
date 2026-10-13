import SwiftUI

struct EntryEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: EntryDraft
    @FocusState private var focus: Field?

    enum Field { case start, note }

    private var problem: String? {
        if draft.running { return draft.start > Date() ? "A running entry can't start in the future." : nil }
        return draft.end > draft.start ? nil : "The end must be after the start."
    }

    private var valid: Bool { draft.projectID != nil && problem == nil }

    /// Projects to pick from: the active ones, plus this entry's own if it has been archived.
    private var choices: [Project] {
        var ps = store.activeProjects
        if let p = store.project(draft.projectID), p.archived { ps.append(p) }
        return ps
    }

    /// What saving will cut into, so it's said before it happens rather than discovered after.
    private var overlapNote: String? {
        let end = draft.running ? Date() : draft.end
        guard end > draft.start else { return nil }
        let hit = store.overlapping(draft.start, end, except: draft.entryID)
        guard !hit.isEmpty else { return nil }
        let names = Array(Set(hit.map { store.name($0.projectID) })).sorted()
        let list = names.count > 2 ? "\(names[0]), \(names[1]) and \(names.count - 2) more" : names.joined(separator: " and ")
        let running = hit.contains { $0.isRunning } && !draft.running
        return "Overlaps \(list). That time will be replaced\(running ? ", and the running timer picks up after this ends" : "")."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.entryID == nil ? "Add time" : "Edit entry")
                    .font(.title2.weight(.semibold))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(draft.running ? Fmt.clock(max(0, ctx.date.timeIntervalSince(draft.start))) : Fmt.dur(draft.end.timeIntervalSince(draft.start)))
                        .font(Theme.clock(30))
                        .foregroundStyle(valid ? (draft.running ? Theme.gran : Theme.ink) : Theme.inkSoft)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Project").font(.callout.weight(.medium)).foregroundStyle(Theme.inkSoft)
                if choices.isEmpty {
                    HStack {
                        Text("There are no projects yet.").foregroundStyle(Theme.inkSoft)
                        Button("Create a Project") { dismiss(); store.askForNewProject() }
                    }
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { i, p in
                            projectButton(p, index: i)
                        }
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Date").foregroundStyle(Theme.inkSoft)
                    DatePicker("", selection: dayBinding, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                GridRow {
                    Text("Time").foregroundStyle(Theme.inkSoft)
                    HStack(spacing: 8) {
                        DatePicker("", selection: startBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .focused($focus, equals: .start)
                        Text("to").foregroundStyle(Theme.inkSoft)
                        if draft.running {
                            Text("now").foregroundStyle(Theme.gran)
                        } else {
                            if !cal.isDate(draft.end, inSameDayAs: draft.start) {
                                Text("next day").font(.caption).foregroundStyle(Theme.inkSoft)
                            }
                            DatePicker("", selection: endBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.field)
                        }
                    }
                }
                if !draft.running {
                    GridRow {
                        Text("Length").foregroundStyle(Theme.inkSoft)
                        HStack(spacing: 6) {
                            ForEach([15, 30, 45, 60, 90, 120, 240], id: \.self) { m in
                                Button(m < 60 ? "\(m)m" : Fmt.dur(Double(m * 60))) {
                                    draft.end = draft.start.addingTimeInterval(Double(m * 60))
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                GridRow {
                    Text("Note").foregroundStyle(Theme.inkSoft)
                    TextField("What did you work on?", text: $draft.note)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .note)
                }
            }

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let overlapNote {
                Label(overlapNote, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Theme.inkSoft)
            }

            HStack {
                if let id = draft.entryID {
                    Button("Delete", role: .destructive) {
                        store.delete(id)
                        dismiss()
                    }
                    .help("You can undo this with ⌘Z")
                }
                if draft.running {
                    Button("Stop Timer") {
                        store.save(draft)
                        store.stop()
                        dismiss()
                    }
                    .disabled(!valid)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.entryID == nil ? "Add" : "Save") {
                    store.save(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            // New time usually needs its times typed; an existing entry usually its note.
            DispatchQueue.main.async { focus = draft.entryID == nil ? .start : .note }
        }
    }

    private func projectButton(_ p: Project, index: Int) -> some View {
        let selected = draft.projectID == p.id
        let color = Theme.project(p.colorIndex)
        let button = Button { draft.projectID = p.id } label: {
            HStack(spacing: 6) {
                Dot(color: color)
                Text(p.name).foregroundStyle(Theme.ink)
                if index < 9 { KeyHint(text: "⌘\(index + 1)") }
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? color.opacity(0.18) : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? color : Theme.line, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        return Group {
            if index < 9 {
                button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            } else {
                button
            }
        }
    }

    /// Changing the date moves both start and end, keeping the times.
    private var dayBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { newDay in
            let shift = newDay.startOfDay.timeIntervalSince(draft.start.startOfDay)
            draft.start = draft.start.addingTimeInterval(shift)
            draft.end = draft.end.addingTimeInterval(shift)
        })
    }

    /// The end is a time of day on the start's day. One a little before the start reads as
    /// the next morning (23:00 to 01:00); anything longer is more likely a typo, and is flagged.
    private var endBinding: Binding<Date> {
        Binding(get: { draft.end }, set: { new in
            let c = cal.dateComponents([.hour, .minute], from: new)
            var end = draft.start.startOfDay.at(hour: c.hour ?? 0, minute: c.minute ?? 0)
            if end <= draft.start && end.adding(days: 1).timeIntervalSince(draft.start) <= 12 * 3600 { end = end.adding(days: 1) }
            draft.end = end
        })
    }

    /// Moving the start past the end pushes the end along, keeping the length.
    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { new in
            let length = draft.end.timeIntervalSince(draft.start)
            draft.start = new
            // Keep the end ahead of the start and within a day of it.
            if !draft.running && (draft.end <= new || draft.end.timeIntervalSince(new) > 24 * 3600) {
                draft.end = new.addingTimeInterval(min(max(length, 900), 12 * 3600))
            }
        })
    }
}
