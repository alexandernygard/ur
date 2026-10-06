import SwiftUI

struct EntryEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: EntryDraft
    @FocusState private var noteFocused: Bool

    private var valid: Bool {
        draft.projectID != nil && (draft.running || draft.end > draft.start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.entryID == nil ? "Add time" : "Edit entry")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(draft.running ? "Running" : Fmt.dur(draft.end.timeIntervalSince(draft.start)))
                    .font(Theme.clock(30))
                    .foregroundStyle(valid ? (draft.running ? Theme.gran : Theme.ink) : Theme.inkSoft)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Project").font(.callout.weight(.medium)).foregroundStyle(Theme.inkSoft)
                FlowLayout(spacing: 6) {
                    ForEach(Array(store.activeProjects.enumerated()), id: \.element.id) { i, p in
                        projectButton(p, index: i)
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
                        Text("to").foregroundStyle(Theme.inkSoft)
                        if draft.running {
                            Text("now").foregroundStyle(Theme.gran)
                        } else {
                            DatePicker("", selection: $draft.end, displayedComponents: .hourAndMinute)
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
                        .focused($noteFocused)
                }
            }

            if !valid && draft.projectID != nil {
                Text("The end time must be after the start time.")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text("Time that overlaps other entries will be reassigned to this one.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }

            HStack {
                if let id = draft.entryID {
                    Button("Delete", role: .destructive) {
                        store.delete(id)
                        dismiss()
                    }
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
        .onAppear { noteFocused = draft.projectID != nil }
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

    /// Moving the start past the end pushes the end along, keeping the length.
    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { new in
            let length = draft.end.timeIntervalSince(draft.start)
            draft.start = new
            if !draft.running && draft.end <= new { draft.end = new.addingTimeInterval(max(length, 900)) }
        })
    }
}
