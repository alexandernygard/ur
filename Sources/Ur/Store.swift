import SwiftUI
import Observation

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case today, week, stats, projects
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Calendar"
        case .week: "Timesheet"
        case .stats: "Stats"
        case .projects: "Projects"
        }
    }
    var icon: String {
        switch self {
        case .today: "calendar"
        case .week: "tablecells"
        case .stats: "chart.bar.xaxis"
        case .projects: "square.stack"
        }
    }
}

/// How many days the calendar shows side by side.
enum Span: String, CaseIterable, Identifiable {
    case day, workdays, week
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "Day"
        case .workdays: "Workdays"
        case .week: "Full week"
        }
    }
}

struct EntryDraft: Identifiable {
    var id = UUID()
    var entryID: UUID?
    var projectID: UUID?
    var start: Date
    var end: Date
    var note = ""
    var running = false
}

struct ProjectTime: Identifiable {
    var id: UUID
    var time: TimeInterval
}

/// One top-level line in a breakdown: a group with its projects, or a project on its own.
struct Tally: Identifiable {
    var id: UUID
    var group: ProjectGroup?
    var projects: [ProjectTime]
    var total: TimeInterval
}

struct DayStat: Identifiable {
    var day: Date
    var perProject: [UUID: TimeInterval]
    var total: TimeInterval
    var start: Date?
    var end: Date?
    var id: Date { day }
    var span: TimeInterval? {
        guard let start, let end, end > start else { return nil }
        return end.timeIntervalSince(start)
    }
}

enum DayState {
    case notStarted
    case active(Date)
    case ended(Date, Date)
}

@Observable
final class Store {
    static let shared = Store()

    var data: AppData { didSet { scheduleSave() } }

    // UI state
    var pane: Pane = .today
    var selectedDay = Date().startOfDay
    var span: Span = Span(rawValue: UserDefaults.standard.string(forKey: "span") ?? "") ?? .day {
        didSet { UserDefaults.standard.set(span.rawValue, forKey: "span") }
    }
    var selectedEntryID: UUID?
    var editing: EntryDraft?
    var showPalette = false
    var showShortcuts = false
    var tick = Date()

    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastDayKey = Date().dayKey

    init() {
        Persistence.backup()
        data = Persistence.load() ?? .starter
        normalizeProjectOrder()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.tick = now
            // Follow midnight if the user was looking at "today".
            if now.dayKey != self.lastDayKey {
                if self.selectedDay.dayKey == self.lastDayKey { self.selectedDay = now.startOfDay }
                self.lastDayKey = now.dayKey
            }
            self.yieldPlansToTimer(now)
        }
    }

    var prefs: Preferences {
        get { data.preferences }
        set { data.preferences = newValue }
    }

    var isModal: Bool { editing != nil || showPalette || showShortcuts }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Persistence.save(self.data)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        Persistence.save(data)
    }

    // MARK: Lookup

    var activeProjects: [Project] { data.projects.filter { !$0.archived } }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return data.projects.first { $0.id == id }
    }

    func color(_ id: UUID?) -> Color {
        guard let p = project(id) else { return Theme.inkSoft }
        return Theme.project(p.colorIndex)
    }

    func name(_ id: UUID?) -> String { project(id)?.name ?? "Unknown project" }

    var running: Entry? { data.entries.first { $0.end == nil } }

    func entries(from: Date, to: Date, now: Date = .now) -> [Entry] {
        data.entries
            .filter { $0.start < to && $0.effectiveEnd(now) > from }
            .sorted { $0.start < $1.start }
    }

    func entries(on day: Date, now: Date = .now) -> [Entry] {
        let s = day.startOfDay
        return entries(from: s, to: s.adding(days: 1), now: now)
    }

    func tracked(on day: Date, project: UUID? = nil, now: Date = .now) -> TimeInterval {
        let s = day.startOfDay, e = s.adding(days: 1)
        return entries(from: s, to: e, now: now)
            .filter { project == nil || $0.projectID == project }
            .reduce(0) { $0 + $1.duration(from: s, to: e, now: now) }
    }

    /// Time booked in the future (plans) on a day.
    func planned(on day: Date, now: Date = .now) -> TimeInterval {
        let s = max(day.startOfDay, now), e = day.startOfDay.adding(days: 1)
        guard e > s else { return 0 }
        return entries(from: s, to: e, now: now).reduce(0) { acc, x in
            guard let end = x.end else { return acc }
            return acc + max(0, min(end, e).timeIntervalSince(max(x.start, s)))
        }
    }

    // MARK: Work day

    func workday(_ day: Date) -> WorkDay? { data.days[day.dayKey] }

    func dayState(_ day: Date) -> DayState {
        guard let w = workday(day), let s = w.start else { return .notStarted }
        if let e = w.end { return .ended(s, e) }
        return .active(s)
    }

    func startDay(at t: Date = .now) {
        let k = t.dayKey
        var w = data.days[k] ?? WorkDay(key: k)
        if w.start == nil { w.start = t }
        w.end = nil
        data.days[k] = w
    }

    func endDay(at t: Date = .now) {
        stop(at: t)
        let k = t.dayKey
        var w = data.days[k] ?? WorkDay(key: k)
        if w.start == nil { w.start = entries(on: t).first?.start ?? t }
        w.end = t
        data.days[k] = w
    }

    func resumeDay() {
        data.days[Date().dayKey]?.end = nil
    }

    /// ⌘D: start the day, end it, or resume it if it was ended by mistake.
    func toggleDay() {
        switch dayState(.now) {
        case .notStarted: startDay()
        case .active: endDay()
        case .ended: resumeDay()
        }
    }

    var dayToggleTitle: String {
        switch dayState(.now) {
        case .notStarted: "Start Day"
        case .active: "End Day"
        case .ended: "Resume Day"
        }
    }

    func setDayBounds(_ day: Date, start: Date?, end: Date?) {
        let k = day.dayKey
        var w = data.days[k] ?? WorkDay(key: k)
        w.start = start
        w.end = end
        if w.start == nil && w.end == nil { data.days[k] = nil } else { data.days[k] = w }
    }

    /// Start of the work day and its end (or now / last entry if still open).
    func dayBounds(_ day: Date, now: Date = .now) -> (start: Date, end: Date)? {
        let w = workday(day)
        let es = entries(on: day, now: now).filter { $0.start <= now }
        guard let s = w?.start ?? es.first?.start else { return nil }
        let e: Date
        if let end = w?.end { e = end } else if day.isToday { e = now } else {
            e = es.map { $0.effectiveEnd(now) }.max() ?? s
        }
        return e > s ? (s, e) : nil
    }

    /// Unallocated stretches inside the work day, at least five minutes long.
    func gaps(_ day: Date, now: Date = .now) -> [(start: Date, end: Date)] {
        guard let (s, e) = dayBounds(day, now: now) else { return [] }
        var cursor = s
        var out: [(Date, Date)] = []
        for x in entries(on: day, now: now) where x.start < e {
            let xs = max(x.start, s)
            if xs.timeIntervalSince(cursor) >= 300 { out.append((cursor, xs)) }
            cursor = max(cursor, x.effectiveEnd(now))
        }
        if e.timeIntervalSince(cursor) >= 300 { out.append((cursor, e)) }
        return out
    }

    // MARK: Tracking

    func start(_ projectID: UUID, note: String = "") {
        let t = Date()
        stop(at: t)
        if prefs.autoStartDay {
            if workday(t)?.start == nil { startDay(at: t) } else if workday(t)?.end != nil { resumeDay() }
        }
        // A plan already under way ends where the timer starts; one that has barely begun
        // stays a plan and is pushed back by the timer like any other.
        for i in data.entries.indices where data.entries[i].start < t && (data.entries[i].end ?? t) > t {
            if t.timeIntervalSince(data.entries[i].start) < 120 { data.entries[i].start = t } else { data.entries[i].end = t }
        }
        data.entries.append(Entry(projectID: projectID, start: t, end: nil, note: note))
        selectedDay = t.startOfDay
    }

    /// A running timer owns the time it covers: plans it runs into are pushed back as it goes,
    /// and dropped once they have been fully overtaken. Prevents counting the same minutes twice.
    func yieldPlansToTimer(_ now: Date) {
        guard let r = running else { return }
        let hit = data.entries.indices.filter { i in
            let x = data.entries[i]
            guard let end = x.end else { return false }
            return x.start >= r.start && x.start < now.addingTimeInterval(-30) && end > x.start
        }
        guard !hit.isEmpty else { return }
        var entries = data.entries
        for i in hit {
            if entries[i].end! <= now.addingTimeInterval(60) { entries[i].end = nil } else { entries[i].start = now }
        }
        entries.removeAll { $0.end == nil && $0.id != r.id }
        data.entries = entries
    }

    func stop(at t: Date = .now) {
        guard let i = data.entries.firstIndex(where: { $0.end == nil }) else { return }
        // Switching within half a minute is treated as a correction, not time spent.
        if t.timeIntervalSince(data.entries[i].start) < 30 {
            data.entries.remove(at: i)
        } else {
            data.entries[i].end = t
        }
    }

    func toggle(_ projectID: UUID) {
        if running?.projectID == projectID { stop() } else { start(projectID) }
    }

    func startProject(at index: Int) {
        let ps = activeProjects
        guard ps.indices.contains(index) else { return }
        toggle(ps[index].id)
    }

    func resumeLast() {
        let now = Date()
        guard let last = data.entries.filter({ $0.end != nil && $0.start <= now }).max(by: { $0.effectiveEnd() < $1.effectiveEnd() })
        else { return }
        start(last.projectID, note: last.note)
    }

    // MARK: Editing

    func newEntry(start: Date? = nil, end: Date? = nil, projectID: UUID? = nil) {
        let now = Date()
        var s = start, e = end
        if s == nil {
            let day = selectedDay
            if day.isToday {
                let last = entries(on: day).filter { $0.end != nil && $0.end! <= now }.last?.end
                s = (last ?? now.addingTimeInterval(-3600)).snapped(to: prefs.snapMinutes)
                e = now.snapped(to: prefs.snapMinutes)
                if e! <= s! { e = s!.addingTimeInterval(1800) }
            } else {
                let last = entries(on: day).last?.end
                s = last ?? day.at(hour: 9, minute: 0)
                e = s!.addingTimeInterval(3600)
            }
        }
        editing = EntryDraft(projectID: projectID ?? running?.projectID ?? activeProjects.first?.id,
                             start: s!, end: e ?? s!.addingTimeInterval(3600))
    }

    func edit(_ id: UUID) {
        guard let x = data.entries.first(where: { $0.id == id }) else { return }
        editing = EntryDraft(entryID: x.id, projectID: x.projectID, start: x.start,
                             end: x.end ?? Date(), note: x.note, running: x.isRunning)
    }

    func editSelectedOrRunning() {
        if let id = selectedEntryID ?? running?.id { edit(id) }
    }

    /// Remove whatever overlaps `[s, e)` so the new time replaces it.
    private func carve(_ s: Date, _ e: Date, except id: UUID?) {
        let now = Date()
        let minimum: TimeInterval = 60
        var out: [Entry] = []
        for var x in data.entries {
            let xe = x.effectiveEnd(now)
            guard x.id != id, x.start < e, xe > s else { out.append(x); continue }
            if x.end == nil {
                if x.start < s {
                    var finished = x
                    finished.end = s
                    out.append(finished)
                    if e < now { out.append(Entry(projectID: x.projectID, start: e, end: nil, note: x.note)) }
                } else if e < now {
                    x.start = e
                    out.append(x)
                }
                continue
            }
            if x.start >= s && xe <= e { continue }
            if x.start < s && xe > e {
                var a = x; a.end = s
                var b = x; b.id = UUID(); b.start = e
                if s.timeIntervalSince(a.start) >= minimum { out.append(a) }
                if xe.timeIntervalSince(e) >= minimum { out.append(b) }
            } else if x.start < s {
                x.end = s
                if s.timeIntervalSince(x.start) >= minimum { out.append(x) }
            } else {
                x.start = e
                if xe.timeIntervalSince(e) >= minimum { out.append(x) }
            }
        }
        data.entries = out
    }

    /// Time logged outside the recorded work day means the day was longer than recorded.
    private func extendDay(_ start: Date, _ end: Date) {
        guard end <= Date().addingTimeInterval(60) else { return }
        let k = start.dayKey
        guard var w = data.days[k] else { return }
        if let s = w.start, start < s { w.start = start }
        if let e = w.end, end > e, end.dayKey == k { w.end = end }
        if w != data.days[k] { data.days[k] = w }
    }

    func save(_ d: EntryDraft) {
        guard let pid = d.projectID else { return }
        let end: Date? = d.running ? nil : d.end
        let effectiveEnd = end ?? Date()
        guard effectiveEnd > d.start else { return }
        carve(d.start, effectiveEnd, except: d.entryID)
        if let id = d.entryID, let i = data.entries.firstIndex(where: { $0.id == id }) {
            data.entries[i].projectID = pid
            data.entries[i].start = d.start
            data.entries[i].end = end
            data.entries[i].note = d.note
        } else {
            let x = Entry(projectID: pid, start: d.start, end: end, note: d.note)
            data.entries.append(x)
            selectedEntryID = x.id
        }
        extendDay(d.start, effectiveEnd)
    }

    func setTimes(_ id: UUID, start: Date, end: Date?) {
        let effectiveEnd = end ?? Date()
        guard effectiveEnd.timeIntervalSince(start) >= 60 else { return }
        carve(start, effectiveEnd, except: id)
        guard let j = data.entries.firstIndex(where: { $0.id == id }) else { return }
        data.entries[j].start = start
        data.entries[j].end = end
        extendDay(start, effectiveEnd)
    }

    func setProject(_ entryID: UUID, _ projectID: UUID) {
        guard let i = data.entries.firstIndex(where: { $0.id == entryID }) else { return }
        data.entries[i].projectID = projectID
    }

    func setNote(_ entryID: UUID, _ note: String) {
        guard let i = data.entries.firstIndex(where: { $0.id == entryID }) else { return }
        data.entries[i].note = note
    }

    func delete(_ id: UUID) {
        data.entries.removeAll { $0.id == id }
        if selectedEntryID == id { selectedEntryID = nil }
    }

    func deleteSelected() {
        if let id = selectedEntryID { delete(id) }
    }

    // MARK: Projects

    @discardableResult
    func addProject(_ name: String, group: UUID? = nil) -> Project {
        let used = Set(data.projects.map(\.colorIndex))
        let color = (0..<Theme.projectPalette.count).first { !used.contains($0) } ?? data.projects.count
        let p = Project(name: name.trimmingCharacters(in: .whitespaces), colorIndex: color, groupID: group)
        data.projects.append(p)
        normalizeProjectOrder()
        return p
    }

    /// Archived projects keep their history but leave the chips, shortcuts and menus.
    func setArchived(_ id: UUID, _ archived: Bool) {
        guard let i = data.projects.firstIndex(where: { $0.id == id }) else { return }
        if archived, running?.projectID == id { stop() }
        data.projects[i].archived = archived
    }

    func deleteProject(_ id: UUID) {
        if running?.projectID == id { stop() }
        data.entries.removeAll { $0.projectID == id }
        data.projects.removeAll { $0.id == id }
    }

    // MARK: Groups

    func group(_ id: UUID?) -> ProjectGroup? {
        guard let id else { return nil }
        return data.groups.first { $0.id == id }
    }

    func groupName(of projectID: UUID?) -> String? { group(project(projectID)?.groupID)?.name }

    @discardableResult
    func addGroup(_ name: String) -> ProjectGroup {
        let g = ProjectGroup(name: name.trimmingCharacters(in: .whitespaces))
        data.groups.append(g)
        return g
    }

    /// Removes the group. Its projects stay, ungrouped.
    func deleteGroup(_ id: UUID) {
        for i in data.projects.indices where data.projects[i].groupID == id { data.projects[i].groupID = nil }
        data.groups.removeAll { $0.id == id }
        normalizeProjectOrder()
    }

    func setGroup(_ projectID: UUID, to groupID: UUID?) {
        guard let i = data.projects.firstIndex(where: { $0.id == projectID }), data.projects[i].groupID != groupID else { return }
        // Join the new group at the end.
        var p = data.projects.remove(at: i)
        p.groupID = groupID
        data.projects.append(p)
        normalizeProjectOrder()
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        guard let i = data.groups.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard data.groups.indices.contains(j) else { return }
        data.groups.swapAt(i, j)
        normalizeProjectOrder()
    }

    /// Reorders projects within one group (or among the ungrouped), with offsets local to that group.
    func moveProjects(in groupID: UUID?, from: IndexSet, to: Int) {
        // Indices are into the visible list, which leaves out archived projects.
        let isMember = { (p: Project) in p.groupID == groupID && !p.archived }
        var members = data.projects.filter(isMember)
        members.move(fromOffsets: from, toOffset: to)
        var next = members.makeIterator()
        var all = data.projects
        for i in all.indices where isMember(all[i]) { all[i] = next.next()! }
        data.projects = all
    }

    /// Projects are kept in display order: ungrouped first, then each group in turn.
    /// This order also sets the ⌘1–⌘9 shortcuts.
    func normalizeProjectOrder() {
        let rank = Dictionary(uniqueKeysWithValues: data.groups.enumerated().map { ($0.element.id, $0.offset) })
        let sorted = data.projects.enumerated().sorted { a, b in
            let ra = a.element.groupID.flatMap { rank[$0] } ?? -1
            let rb = b.element.groupID.flatMap { rank[$0] } ?? -1
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        // Drop references to groups that no longer exist.
        let fixed = sorted.map { p -> Project in
            var p = p
            if let g = p.groupID, rank[g] == nil { p.groupID = nil }
            return p
        }
        if fixed != data.projects { data.projects = fixed }
    }

    /// Projects split into the ungrouped ones followed by each group, in display order.
    func sections(_ projects: [Project]) -> [(group: ProjectGroup?, projects: [Project])] {
        var out: [(group: ProjectGroup?, projects: [Project])] = [(nil, projects.filter { group($0.groupID) == nil })]
        for g in data.groups { out.append((g, projects.filter { $0.groupID == g.id })) }
        return out
    }

    /// Rolls per-project times up into groups. Ungrouped projects stand alone.
    /// `byTotal` sorts largest first; otherwise the project order is kept.
    func tally(_ per: [UUID: TimeInterval], byTotal: Bool = true) -> [Tally] {
        let order = Dictionary(uniqueKeysWithValues: data.projects.enumerated().map { ($0.element.id, $0.offset) })
        var out: [Tally] = []
        var groupIndex: [UUID: Int] = [:]
        let ids = per.keys.filter { (per[$0] ?? 0) > 0 }.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
        for id in ids {
            let t = per[id] ?? 0
            if let g = group(project(id)?.groupID) {
                if let i = groupIndex[g.id] {
                    out[i].projects.append(ProjectTime(id: id, time: t))
                    out[i].total += t
                } else {
                    groupIndex[g.id] = out.count
                    out.append(Tally(id: g.id, group: g, projects: [ProjectTime(id: id, time: t)], total: t))
                }
            } else {
                out.append(Tally(id: id, group: nil, projects: [ProjectTime(id: id, time: t)], total: t))
            }
        }
        guard byTotal else { return out }
        return out.map { var x = $0; x.projects.sort { $0.time > $1.time }; return x }
            .sorted { $0.total > $1.total }
    }

    func totalTime(_ projectID: UUID) -> TimeInterval {
        data.entries.filter { $0.projectID == projectID }.reduce(0) { $0 + $1.duration() }
    }

    // MARK: Navigation

    func goToday() { selectedDay = Date().startOfDay }

    /// The days the calendar shows: the selected day, or the week around it.
    var visibleDays: [Date] {
        let monday = selectedDay.startOfWeek
        switch span {
        case .day: return [selectedDay]
        case .workdays: return (0..<5).map { monday.adding(days: $0) }
        case .week: return (0..<7).map { monday.adding(days: $0) }
        }
    }

    func step(_ dir: Int) {
        let byWeek = pane == .week || (pane == .today && span != .day)
        selectedDay = selectedDay.adding(days: byWeek ? 7 * dir : dir)
    }

    // MARK: Stats

    func dayStats(from: Date, to: Date, now: Date = .now) -> [DayStat] {
        var out: [DayStat] = []
        let all = entries(from: from, to: to, now: now)
        var d = from.startOfDay
        while d < to {
            let e = d.adding(days: 1)
            var per: [UUID: TimeInterval] = [:]
            for x in all where x.start < e && x.effectiveEnd(now) > d {
                per[x.projectID, default: 0] += x.duration(from: d, to: e, now: now)
            }
            let w = workday(d)
            out.append(DayStat(day: d, perProject: per.filter { $0.value > 0 },
                               total: per.values.reduce(0, +), start: w?.start, end: w?.end))
            d = e
        }
        return out
    }

    func csvEntries(from: Date, to: Date) -> String {
        var rows = ["date,start,end,hours,project,group,note"]
        for x in entries(from: from, to: to) {
            let p = project(x.projectID)
            let end = x.effectiveEnd()
            rows.append([
                x.start.dayKey, Fmt.time(x.start), Fmt.time(end),
                String(format: "%.2f", end.timeIntervalSince(x.start) / 3600),
                csv(p?.name ?? ""), csv(group(p?.groupID)?.name ?? ""), csv(x.note),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    func csvDays(from: Date, to: Date) -> String {
        var rows = ["date,day_start,day_end,at_work_hours,tracked_hours"]
        for s in dayStats(from: from, to: to) where s.start != nil || s.total > 0 {
            rows.append([
                s.day.dayKey, Fmt.time(s.start), Fmt.time(s.end),
                s.span.map { String(format: "%.2f", $0 / 3600) } ?? "",
                String(format: "%.2f", s.total / 3600),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func csv(_ s: String) -> String {
        guard s.contains(where: { ",\"\n".contains($0) }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
