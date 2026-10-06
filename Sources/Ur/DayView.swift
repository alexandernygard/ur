import SwiftUI

struct DayView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let day = store.selectedDay
        VStack(spacing: 0) {
            DayHero(day: day)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 18)
            Divider()
            HStack(spacing: 0) {
                DayCanvas(day: day)
                Divider()
                DaySummary(day: day)
                    .frame(width: 280)
            }
        }
        .navigationTitle(Fmt.dayTitle.string(from: day))
        .navigationSubtitle(day.isToday ? "Today, week \(day.weekNumber)" : "Week \(day.weekNumber)")
        .toolbar { DayToolbar() }
    }
}

struct DayToolbar: ToolbarContent {
    @Environment(Store.self) private var store

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous (⌘[)")
                Button("Today") { store.goToday() }
                    .help("Today (⌘T)")
                    .disabled(store.selectedDay.isToday && store.pane == .today)
                Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next (⌘])")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.showPalette = true } label: { Label("Command bar", systemImage: "command") }
                .help("Command bar (⌘K)")
            Button { store.newEntry() } label: { Label("Add time", systemImage: "plus") }
                .help("Add time (⌘N)")
        }
    }
}

// MARK: Hero

struct DayHero: View {
    @Environment(Store.self) private var store
    let day: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        clock(now)
                        status(now)
                    }
                    Spacer(minLength: 16)
                    DayBookends(day: day, now: now)
                        .frame(width: 320)
                }
                if day.isToday {
                    ProjectChips(now: now)
                }
            }
        }
    }

    @ViewBuilder private func clock(_ now: Date) -> some View {
        if day.isToday, let r = store.running {
            Text(Fmt.clock(now.timeIntervalSince(r.start)))
                .font(Theme.clock(72))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
        } else if day.isToday {
            Text("0:00:00")
                .font(Theme.clock(72))
                .foregroundStyle(Theme.inkSoft.opacity(0.35))
        } else {
            Text(Fmt.hmm(store.tracked(on: day, now: now)))
                .font(Theme.clock(72))
                .foregroundStyle(Theme.ink)
        }
    }

    @ViewBuilder private func status(_ now: Date) -> some View {
        if day.isToday, let r = store.running {
            HStack(spacing: 10) {
                Dot(color: store.color(r.projectID), size: 10)
                Text(store.name(r.projectID)).font(.title3.weight(.semibold))
                Text("since \(Fmt.time(r.start))").foregroundStyle(Theme.inkSoft)
                RunningNote(entry: r)
                Button("Stop") { store.stop() }
                    .help("Stop (⌘.)")
            }
        } else if day.isToday {
            Text("Not tracking. Pick a project, press ⌘1–9, or ⌘K to search.")
                .font(.title3)
                .foregroundStyle(Theme.inkSoft)
        } else {
            Text("Tracked. Drag on the timeline or press ⌘N to add time.")
                .font(.title3)
                .foregroundStyle(Theme.inkSoft)
        }
    }
}

/// Inline note for the running entry; commits on Return or when focus leaves.
struct RunningNote: View {
    @Environment(Store.self) private var store
    let entry: Entry
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Add a note", text: $text)
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.inkSoft)
            .frame(minWidth: 120, maxWidth: 260)
            .focused($focused)
            .onAppear { text = entry.note }
            .onChange(of: entry.id) { text = entry.note }
            .onSubmit { store.setNote(entry.id, text); focused = false }
            .onChange(of: focused) { if !focused { store.setNote(entry.id, text) } }
    }
}

/// Start and end of the work day. The amber marks are the two moments the app treats as most important.
struct DayBookends: View {
    @Environment(Store.self) private var store
    let day: Date
    let now: Date
    @State private var editing = false

    var body: some View {
        let w = store.workday(day)
        let bounds = store.dayBounds(day, now: now)
        let tracked = store.tracked(on: day, now: now)
        let atWork = bounds.map { $0.end.timeIntervalSince($0.start) } ?? 0
        let target = store.prefs.targetHours * 3600

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                bookend("Started", w?.start)
                Spacer()
                Rectangle().fill(Theme.line).frame(height: 1).frame(maxWidth: 60).alignmentGuide(.firstTextBaseline) { _ in -6 }
                Spacer()
                bookend("Ended", w?.end, placeholder: w?.start != nil && day.isToday ? "In progress" : "–")
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
            .popover(isPresented: $editing, arrowEdge: .bottom) { DayBoundsEditor(day: day) }
            .help("Click to adjust the start and end of the day")

            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(Theme.gran)
                            .frame(width: target > 0 ? min(1, tracked / target) * geo.size.width : 0)
                    }
                }
                .frame(height: 5)
                HStack {
                    Text("\(Fmt.dur(tracked)) tracked of \(Fmt.dur(target))")
                    Spacer()
                    Text("\(Fmt.dur(atWork)) at work")
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            }

            if day.isToday {
                Button(store.dayToggleTitle) { store.toggleDay() }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("⌘D")
            }
        }
    }

    private func bookend(_ label: String, _ date: Date?, placeholder: String = "–") -> some View {
        VStack(alignment: label == "Started" ? .leading : .trailing, spacing: 2) {
            Text(date.map { Fmt.time($0) } ?? placeholder)
                .font(.system(size: date == nil ? 17 : 26, weight: .regular).width(.condensed).monospacedDigit())
                .foregroundStyle(date == nil ? Theme.inkSoft : Theme.molte)
            Text(label).font(.caption).foregroundStyle(Theme.inkSoft)
        }
    }
}

struct DayBoundsEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let day: Date
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Work day").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Toggle("Started", isOn: $hasStart)
                    DatePicker("", selection: $start, displayedComponents: .hourAndMinute).labelsHidden().disabled(!hasStart)
                }
                GridRow {
                    Toggle("Ended", isOn: $hasEnd)
                    DatePicker("", selection: $end, displayedComponents: .hourAndMinute).labelsHidden().disabled(!hasEnd)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.setDayBounds(day, start: hasStart ? onDay(start) : nil, end: hasEnd ? onDay(end) : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hasStart && hasEnd && onDay(end) <= onDay(start))
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear {
            let w = store.workday(day)
            hasStart = w?.start != nil
            hasEnd = w?.end != nil
            start = w?.start ?? store.entries(on: day).first?.start ?? day.at(hour: 8, minute: 0)
            end = w?.end ?? (day.isToday ? Date() : day.at(hour: 16, minute: 0))
        }
    }

    private func onDay(_ t: Date) -> Date {
        let c = cal.dateComponents([.hour, .minute], from: t)
        return day.at(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
}

// MARK: Project chips

struct ProjectChips: View {
    @Environment(Store.self) private var store
    let now: Date

    var body: some View {
        let projects = store.activeProjects
        if projects.isEmpty {
            Button("Create your first project") {
                store.pane = .projects
                NotificationCenter.default.post(name: .focusNewProject, object: nil)
            }
        } else {
            FlowLayout(spacing: 8) {
                ForEach(Array(projects.enumerated()), id: \.element.id) { i, p in
                    ProjectChip(project: p, index: i, now: now)
                }
            }
        }
    }
}

struct ProjectChip: View {
    @Environment(Store.self) private var store
    let project: Project
    let index: Int
    let now: Date
    @State private var hover = false

    var body: some View {
        let isRunning = store.running?.projectID == project.id
        let color = Theme.project(project.colorIndex)
        let total = store.tracked(on: now, project: project.id, now: now)
        Button { store.toggle(project.id) } label: {
            HStack(spacing: 8) {
                if isRunning {
                    Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(color)
                } else {
                    Dot(color: color)
                }
                Text(project.name).font(.callout.weight(.medium)).foregroundStyle(Theme.ink)
                if total >= 60 {
                    Text(Fmt.hmm(total)).font(Theme.mono).foregroundStyle(Theme.inkSoft)
                }
                if index < 9 { KeyHint(text: "⌘\(index + 1)") }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isRunning ? color.opacity(0.16) : (hover ? Theme.raised : Theme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isRunning ? color : Theme.line, lineWidth: isRunning ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(isRunning ? "Stop \(project.name)" : "Start \(project.name)")
    }
}

// MARK: Summary column

struct DaySummary: View {
    @Environment(Store.self) private var store
    let day: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let now = ctx.date
            let entries = store.entries(on: day, now: now)
            let ids = Array(Set(entries.map(\.projectID)))
            let rows = ids.map { (id: $0, t: store.tracked(on: day, project: $0, now: now)) }
                .filter { $0.t >= 60 }
                .sorted { $0.t > $1.t }
            let total = rows.reduce(0) { $0 + $1.t }
            let gaps = store.gaps(day, now: now)
            let planned = store.planned(on: day, now: now)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By project").font(.headline)
                        if rows.isEmpty {
                            Text("No time yet. Start a timer, or drag on the timeline to log time after the fact.")
                                .font(.callout)
                                .foregroundStyle(Theme.inkSoft)
                        }
                        ForEach(rows, id: \.id) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Dot(color: store.color(row.id))
                                    Text(store.name(row.id)).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.dur(row.t)).monospacedDigit().foregroundStyle(Theme.inkSoft)
                                }
                                .font(.callout)
                                GeometryReader { g in
                                    Capsule().fill(store.color(row.id))
                                        .frame(width: max(3, g.size.width * row.t / max(total, 1)))
                                }
                                .frame(height: 3)
                            }
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Tracked").foregroundStyle(Theme.inkSoft)
                            Text(Fmt.dur(total)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                        GridRow {
                            Text("Unallocated").foregroundStyle(Theme.inkSoft)
                            Text(Fmt.dur(gaps.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) })).monospacedDigit()
                        }
                        if planned > 0 {
                            GridRow {
                                Text("Planned").foregroundStyle(Theme.inkSoft)
                                Text(Fmt.dur(planned)).monospacedDigit()
                            }
                        }
                    }
                    .font(.callout)

                    if !gaps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Unallocated time").font(.headline)
                            ForEach(gaps, id: \.start) { g in
                                Button { store.newEntry(start: g.start, end: g.end) } label: {
                                    HStack {
                                        Text(Fmt.range(g.start, g.end)).monospacedDigit()
                                        Spacer()
                                        Text(Fmt.dur(g.end.timeIntervalSince(g.start))).foregroundStyle(Theme.inkSoft)
                                        Image(systemName: "plus.circle").foregroundStyle(Theme.inkSoft)
                                    }
                                    .font(.callout)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Assign this time to a project")
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.surface)
    }
}
