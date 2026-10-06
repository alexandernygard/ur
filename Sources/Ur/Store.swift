import SwiftUI
import Observation

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case today, week, stats, projects
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Day"
        case .week: "Week"
        case .stats: "Stats"
        case .projects: "Projects"
        }
    }
    var icon: String {
        switch self {
        case .today: "sun.horizon"
        case .week: "calendar"
        case .stats: "chart.bar.xaxis"
        case .projects: "square.stack"
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
        // A plan in progress ends where the timer starts.
        for i in data.entries.indices where data.entries[i].start < t && (data.entries[i].end ?? t) > t {
            data.entries[i].end = t
        }
        data.entries.append(Entry(projectID: projectID, start: t, end: nil, note: note))
        selectedDay = t.startOfDay
    }

    /// A running timer owns the time it covers: plans it runs into are pushed back as it goes,
    /// and dropped once they have been fully overtaken. Prevents counting the same minutes twice.
    private func yieldPlansToTimer(_ now: Date) {
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
    }

    func setTimes(_ id: UUID, start: Date, end: Date?) {
        let effectiveEnd = end ?? Date()
        guard effectiveEnd.timeIntervalSince(start) >= 60 else { return }
        carve(start, effectiveEnd, except: id)
        guard let j = data.entries.firstIndex(where: { $0.id == id }) else { return }
        data.entries[j].start = start
        data.entries[j].end = end
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
    func addProject(_ name: String, client: String = "") -> Project {
        let used = Set(data.projects.map(\.colorIndex))
        let color = (0..<Theme.projectPalette.count).first { !used.contains($0) } ?? data.projects.count
        let p = Project(name: name.trimmingCharacters(in: .whitespaces), colorIndex: color, client: client)
        data.projects.append(p)
        return p
    }

    func deleteProject(_ id: UUID) {
        if running?.projectID == id { stop() }
        data.entries.removeAll { $0.projectID == id }
        data.projects.removeAll { $0.id == id }
    }

    func totalTime(_ projectID: UUID) -> TimeInterval {
        data.entries.filter { $0.projectID == projectID }.reduce(0) { $0 + $1.duration() }
    }

    // MARK: Navigation

    func goToday() { selectedDay = Date().startOfDay }

    func step(_ dir: Int) {
        switch pane {
        case .week: selectedDay = selectedDay.adding(days: 7 * dir)
        default: selectedDay = selectedDay.adding(days: dir)
        }
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
        var rows = ["date,start,end,hours,project,client,note"]
        for x in entries(from: from, to: to) {
            let p = project(x.projectID)
            let end = x.effectiveEnd()
            rows.append([
                x.start.dayKey, Fmt.time(x.start), Fmt.time(end),
                String(format: "%.2f", end.timeIntervalSince(x.start) / 3600),
                csv(p?.name ?? ""), csv(p?.client ?? ""), csv(x.note),
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
