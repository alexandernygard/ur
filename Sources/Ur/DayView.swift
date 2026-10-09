import SwiftUI

/// The calendar: the running clock and the day's bookends on top, then one day or a week of
/// editable timelines, with a month overview and the totals beside it.
struct DayView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let day = store.selectedDay
        let days = store.visibleDays
        VStack(spacing: 0) {
            DayHero(day: day)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 18)
            Divider()
            HStack(spacing: 0) {
                CalendarCanvas(days: days)
                Divider()
                VStack(spacing: 0) {
                    MiniMonth()
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                    Divider()
                    DaySummary(days: days)
                }
                .frame(width: 280)
                .background(Theme.surface)
            }
        }
        .navigationTitle(days.count == 1 ? Fmt.dayTitle.string(from: day) : "Week \(day.weekNumber)")
        .navigationSubtitle(days.count == 1
            ? (day.isToday ? "Today, week \(day.weekNumber)" : "Week \(day.weekNumber)")
            : "\(Fmt.dayMonth.string(from: days[0])) – \(Fmt.dayMonth.string(from: days[days.count - 1]))")
        .toolbar {
            DayToolbar()
            SpanPicker()
        }
    }
}

struct SpanPicker: ToolbarContent {
    @Environment(Store.self) private var store

    var body: some ToolbarContent {
        @Bindable var store = store
        ToolbarItem(placement: .principal) {
            Picker("Days", selection: $store.span) {
                ForEach(Span.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Show one day, the work week or the whole week (⌃⌘1–3)")
        }
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

/// Note for the running entry. Shown as text until clicked, so it never steals keyboard focus.
struct RunningNote: View {
    @Environment(Store.self) private var store
    let entry: Entry
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Add a note", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear { text = entry.note; focused = true }
                    .onSubmit { commit() }
                    .onChange(of: focused) { if !focused { commit() } }
                    .onExitCommand { editing = false }
            } else {
                Text(entry.note.isEmpty ? "Add a note" : entry.note)
                    .opacity(entry.note.isEmpty ? 0.6 : 1)
                    .onTapGesture { editing = true }
                    .help("Click to edit the note")
            }
        }
        .foregroundStyle(Theme.inkSoft)
        .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
    }

    private func commit() {
        store.setNote(entry.id, text)
        editing = false
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
                bookend(w?.end == nil && w?.start != nil && day.isToday ? "In progress" : "Ended", w?.end)
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
                .font(.system(size: 26, weight: .regular).width(.condensed).monospacedDigit())
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
        .contextMenu {
            Button(isRunning ? "Stop \(project.name)" : "Start \(project.name)") { store.toggle(project.id) }
            Button("Archive \(project.name)") { store.setArchived(project.id, true) }
            Divider()
            Button("Edit Projects…") { store.pane = .projects }
        }
    }
}

// MARK: Summary column

struct DaySummary: View {
    @Environment(Store.self) private var store
    let days: [Date]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let now = ctx.date
            let stats = store.dayStats(from: days[0], to: days[days.count - 1].adding(days: 1), now: now)
            let per = stats.reduce(into: [UUID: TimeInterval]()) { acc, d in
                for (k, v) in d.perProject { acc[k, default: 0] += v }
            }.filter { $0.value >= 60 }
            let total = per.values.reduce(0, +)
            let unallocated = days.reduce(0.0) { acc, d in
                acc + store.gaps(d, now: now).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            }
            let atWork = days.reduce(0.0) { acc, d in
                acc + (store.dayBounds(d, now: now).map { $0.end.timeIntervalSince($0.start) } ?? 0)
            }
            let planned = days.reduce(0.0) { $0 + store.planned(on: $1, now: now) }
            let day = store.selectedDay
            let gaps = days.contains(day) ? store.gaps(day, now: now) : []

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(days.count == 1 ? "By project" : "This week by project").font(.headline)
                        if per.isEmpty {
                            Text("No time yet. Start a timer, or drag on the timeline to log time after the fact.")
                                .font(.callout)
                                .foregroundStyle(Theme.inkSoft)
                        }
                        Breakdown(tallies: store.tally(per), barHeight: 3)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Tracked").foregroundStyle(Theme.inkSoft)
                            Text(Fmt.dur(total)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                        if days.count > 1 {
                            GridRow {
                                Text("At work").foregroundStyle(Theme.inkSoft)
                                Text(Fmt.dur(atWork)).monospacedDigit()
                            }
                        }
                        GridRow {
                            Text("Unallocated").foregroundStyle(Theme.inkSoft)
                            Text(Fmt.dur(unallocated)).monospacedDigit()
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
                            Text(days.count == 1 ? "Unallocated time" : "Unallocated on \(Fmt.weekday.string(from: day))")
                                .font(.headline)
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
    }
}

/// The month around the selected day. The days on screen are banded, days with tracked time get a dot,
/// and clicking a day (or a week number) goes there.
struct MiniMonth: View {
    @Environment(Store.self) private var store
    @State private var month = Date().startOfMonth

    var body: some View {
        let first = month.startOfWeek
        let last = month.adding(months: 1).adding(days: -1).startOfWeek.adding(days: 7)
        let weeks = Int((last.timeIntervalSince(first) / 86400 / 7).rounded())
        let tracked = Dictionary(uniqueKeysWithValues: store.dayStats(from: first, to: last).map { ($0.day, $0.total) })
        let visible = Set(store.visibleDays)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Fmt.monthYear.string(from: month)).font(.callout.weight(.semibold))
                Spacer()
                Button { month = month.adding(months: -1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous month")
                Button { month = month.adding(months: 1) } label: { Image(systemName: "chevron.right") }
                    .help("Next month")
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 2)

            Grid(horizontalSpacing: 0, verticalSpacing: 2) {
                GridRow {
                    Text("").frame(width: 22)
                    ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                        Text(["M", "T", "W", "T", "F", "S", "S"][i])
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.inkSoft)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<weeks, id: \.self) { w in
                    let monday = first.adding(days: 7 * w)
                    GridRow {
                        Button { store.selectedDay = monday; if store.span == .day { store.span = .workdays } } label: {
                            Text("\(monday.weekNumber)")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(Theme.inkSoft.opacity(0.7))
                                .frame(width: 22, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help("Show week \(monday.weekNumber)")
                        ForEach(0..<7, id: \.self) { i in
                            let d = monday.adding(days: i)
                            cell(d, tracked: tracked[d] ?? 0,
                                 inMonth: cal.isDate(d, equalTo: month, toGranularity: .month),
                                 band: visible.count > 1 && visible.contains(d),
                                 bandStart: d == store.visibleDays.first, bandEnd: d == store.visibleDays.last)
                        }
                    }
                }
            }
        }
        .onAppear { month = store.selectedDay.startOfMonth }
        .onChange(of: store.selectedDay) { month = store.selectedDay.startOfMonth }
    }

    private func cell(_ d: Date, tracked: TimeInterval, inMonth: Bool, band: Bool, bandStart: Bool, bandEnd: Bool) -> some View {
        let selected = d == store.selectedDay
        return Button { store.selectedDay = d } label: {
            ZStack {
                if band {
                    UnevenRoundedRectangle(topLeadingRadius: bandStart ? 13 : 0, bottomLeadingRadius: bandStart ? 13 : 0,
                                           bottomTrailingRadius: bandEnd ? 13 : 0, topTrailingRadius: bandEnd ? 13 : 0)
                        .fill(Theme.gran.opacity(0.12))
                }
                if selected {
                    Circle().fill(Theme.gran).frame(width: 24, height: 24)
                }
                Text("\(cal.component(.day, from: d))")
                    .font(.system(size: 11, weight: d.isToday || selected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : d.isToday ? Theme.gran : Theme.ink.opacity(inMonth ? 1 : 0.35))
                if tracked >= 60 {
                    Circle().fill(selected ? Color.white : Theme.inkSoft)
                        .frame(width: 3, height: 3)
                        .offset(y: 8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tracked >= 60 ? "\(Fmt.dayTitle.string(from: d)): \(Fmt.dur(tracked)) tracked" : Fmt.dayTitle.string(from: d))
    }
}
