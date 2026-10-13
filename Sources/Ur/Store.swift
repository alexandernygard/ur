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

struct ProjectFacts {
    var total: TimeInterval = 0
    var thisWeek: TimeInterval = 0
    /// Tracked time per week, oldest first, ending with this week.
    var weeks: [TimeInterval]
    var last: Date?
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
    var pane: Pane = .today {
        // ⌘E and ⌘⌫ act on the selection, so it shouldn't outlive the calendar.
        didSet { if pane != oldValue && pane != .today { selectedEntryID = nil } }
    }
    var selectedDay = Date().startOfDay
    var span: Span = Span(rawValue: UserDefaults.standard.string(forKey: "span") ?? "") ?? .day {
        didSet { UserDefaults.standard.set(span.rawValue, forKey: "span") }
    }
    var selectedEntryID: UUID?
    var editing: EntryDraft?
    var showPalette = false
    var showShortcuts = false
    /// Set when "New Project" is chosen, so the Projects page focuses its name field once shown.
    var wantsNewProject = false
    var tick = Date()

    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// The main window's undo manager, so ⌘Z works on entries and the work day.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var undoDepth = 0
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

    // MARK: Undo

    /// Runs a change as one undo step, named as it appears in the Edit menu ("Undo Move Entry").
    /// Nested calls fold into the outermost one.
    func undoable(_ name: String, _ body: () -> Void) {
        let outer = undoDepth == 0
        let before = data
        undoDepth += 1
        body()
        undoDepth -= 1
        guard outer, data != before else { return }
        let projects = data.projects != before.projects || data.groups != before.groups
        registerUndo(restoring: before, name, projects: projects)
    }

    /// Undo puts back time (entries and work days), and the projects and groups only when the
    /// action itself changed them, so undoing a timer stop doesn't revert a rename made since.
    private func registerUndo(restoring snapshot: AppData, _ name: String, projects: Bool) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { store in
            let current = store.data
            store.registerUndo(restoring: current, name, projects: projects)
            var restored = current
            restored.entries = snapshot.entries
            restored.days = snapshot.days
            if projects {
                restored.projects = snapshot.projects
                restored.groups = snapshot.groups
            }
            store.data = restored
            if let id = store.selectedEntryID, !restored.entries.contains(where: { $0.id == id }) { store.selectedEntryID = nil }
        }
        um.setActionName(name)
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

    func name(_ id: UUID?) -> String {
        guard let p = project(id) else { return "Unknown project" }
        let n = p.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Untitled project" : n
    }

    /// Opens Projects with the new-project field focused.
    func askForNewProject() {
        pane = .projects
        wantsNewProject = true
    }

    /// True while a text field is being typed in, so editing keys like ⌘⌫ go to the text.
    var isTyping: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

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

    /// What was set by hand: Start Day, End Day, or dragging the amber lines.
    func recordedDay(_ day: Date) -> WorkDay? { data.days[day.dayKey] }

    /// Earliest start and latest end of the time already under way on a day (plans don't count).
    func worked(_ day: Date, now: Date = .now) -> (start: Date, end: Date)? {
        let ds = day.startOfDay, de = ds.adding(days: 1)
        let es = data.entries.filter { $0.start >= ds && $0.start < de && $0.start <= now }
        guard let first = es.map(\.start).min(), let last = es.map({ min($0.effectiveEnd(now), now) }).max() else { return nil }
        return (first, last)
    }

    /// The work day as it should be shown: what was set by hand, widened to cover every entry
    /// that has started. A day with entries but nothing set starts with its first entry, and a
    /// past one ends with its last.
    func workday(_ day: Date, now: Date = .now) -> WorkDay? {
        let rec = recordedDay(day)
        guard let span = worked(day, now: now) else { return rec }
        // With automatic start turned off, today begins only when you say so.
        if day.isToday && !prefs.autoStartDay && rec?.start == nil { return rec }
        var w = rec ?? WorkDay(key: day.dayKey)
        w.start = min(w.start ?? span.start, span.start)
        if let e = w.end {
            w.end = max(e, span.end)
        } else if !day.isToday {
            w.end = span.end
        }
        return w
    }

    func dayState(_ day: Date) -> DayState {
        guard let w = workday(day), let s = w.start else { return .notStarted }
        if let e = w.end { return .ended(s, e) }
        return .active(s)
    }

    func startDay(at t: Date = .now) {
        undoable("Start Day") { recordStart(t) }
    }

    private func recordStart(_ t: Date) {
        let k = t.dayKey
        var w = data.days[k] ?? WorkDay(key: k)
        if w.start == nil { w.start = min(t, worked(t)?.start ?? t) }
        w.end = nil
        data.days[k] = w
    }

    func endDay(at t: Date = .now) {
        undoable("End Day") {
            stop(at: t)
            let k = t.dayKey
            var w = data.days[k] ?? WorkDay(key: k)
            if w.start == nil { w.start = worked(t)?.start ?? t }
            w.end = t
            data.days[k] = w
        }
    }

    func resumeDay() {
        undoable("Resume Day") {
            let k = Date().dayKey
            if data.days[k]?.start == nil { data.days[k]?.start = worked(.now)?.start }
            data.days[k]?.end = nil
        }
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
        undoable("Change Work Day") { recordBounds(day, start: start, end: end) }
    }

    private func recordBounds(_ day: Date, start: Date?, end: Date?) {
        let k = day.dayKey
        var w = data.days[k] ?? WorkDay(key: k)
        w.start = start
        w.end = end
        if w.start == nil && w.end == nil { data.days[k] = nil } else { data.days[k] = w }
    }

    func setDayStart(_ day: Date, _ t: Date?) { setDayBounds(day, start: t, end: recordedDay(day)?.end) }
    func setDayEnd(_ day: Date, _ t: Date?) { setDayBounds(day, start: recordedDay(day)?.start, end: t) }

    /// Start of the work day and its end (or now, if today and still open).
    func dayBounds(_ day: Date, now: Date = .now) -> (start: Date, end: Date)? {
        let w = workday(day, now: now)
        guard let s = w?.start else { return nil }
        let e = w?.end ?? (day.isToday ? now : worked(day, now: now)?.end ?? s)
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
        undoable("Start \(name(projectID))") { begin(projectID, note: note) }
    }

    private func begin(_ projectID: UUID, note: String) {
        let t = Date()
        stop(at: t)
        wakeDay(t)
        // A plan already under way ends where the timer starts; one that has barely begun
        // stays a plan and is pushed back by the timer like any other.
        for i in data.entries.indices where data.entries[i].start < t && (data.entries[i].end ?? t) > t {
            if t.timeIntervalSince(data.entries[i].start) < 120 { data.entries[i].start = t } else { data.entries[i].end = t }
        }
        data.entries.append(Entry(projectID: projectID, start: t, end: nil, note: note))
        selectedDay = t.startOfDay
    }

    /// A timer starting means the day is on, unless that's switched off in Settings.
    private func wakeDay(_ t: Date) {
        guard prefs.autoStartDay else { return }
        if recordedDay(t)?.start == nil { recordStart(t) } else if recordedDay(t)?.end != nil { data.days[t.dayKey]?.end = nil }
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
        undoable("Stop Timer") {
            let start = data.entries[i].start
            // Switching within half a minute is treated as a correction, not time spent.
            // Stopping at a chosen time never throws the entry away.
            let live = abs(t.timeIntervalSinceNow) < 5
            if live && t.timeIntervalSince(start) < 30 {
                data.entries.remove(at: i)
            } else {
                data.entries[i].end = live ? t : max(t, start.addingTimeInterval(60))
            }
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
        guard let last = data.entries.filter({ $0.end != nil && $0.end! <= now }).max(by: { $0.end! < $1.end! })
        else { return }
        start(last.projectID, note: last.note)
    }

    /// What ⌘R or the play button would pick up: the selected entry, otherwise the last finished one.
    var resumeCandidate: Entry? {
        if let id = selectedEntryID, let x = data.entries.first(where: { $0.id == id }), !x.isRunning { return x }
        let now = Date()
        return data.entries.filter { $0.end != nil && $0.end! <= now }.max { $0.end! < $1.end! }
    }

    /// ⌘↩ and the big round button: stop the timer, or pick the last thing back up.
    func toggleTimer() {
        if running != nil { stop() } else if resumeCandidate != nil { resumeSelectedOrLast() } else { showPalette = true }
    }

    /// ⌘R: the selected entry if there is one, otherwise the last one.
    func resumeSelectedOrLast() {
        if let id = selectedEntryID, let x = data.entries.first(where: { $0.id == id }), !x.isRunning {
            resume(x.id)
        } else {
            resumeLast()
        }
    }

    // MARK: Keyboard selection

    /// ↑ and ↓ step through entries in time order, across days. With nothing selected, ↑ picks
    /// the last thing you did and ↓ the first entry on screen.
    func selectAdjacentEntry(_ dir: Int) {
        let now = Date()
        let all = data.entries.sorted { ($0.start, $0.effectiveEnd(now)) < ($1.start, $1.effectiveEnd(now)) }
        guard !all.isEmpty else { return }
        let next: Entry?
        if let id = selectedEntryID, let i = all.firstIndex(where: { $0.id == id }) {
            let j = i + dir
            next = all.indices.contains(j) ? all[j] : nil
        } else {
            let shown = visibleDays.flatMap { entries(on: $0) }.sorted { $0.start < $1.start }
            if dir < 0 {
                next = shown.last { $0.start <= now } ?? shown.last ?? all.last { $0.start <= now }
            } else {
                next = shown.first ?? all.first { $0.start >= selectedDay } ?? all.last
            }
        }
        if let next { selectEntry(next) }
    }

    /// ← and → move to the entry on the previous or next day nearest the same time of day,
    /// skipping days with nothing on them.
    func selectEntryOnAdjacentDay(_ dir: Int) {
        let now = Date()
        let from = data.entries.first { $0.id == selectedEntryID }
        let day = from?.start.startOfDay ?? selectedDay
        let time = from?.start.hoursIntoDay ?? (day.isToday ? now.hoursIntoDay : 9)
        for k in 1...60 {
            let d = day.adding(days: dir * k)
            let candidates = entries(on: d)
            if let best = candidates.min(by: { abs($0.start.hoursIntoDay - time) < abs($1.start.hoursIntoDay - time) }) {
                selectEntry(best)
                return
            }
        }
    }

    /// Selects the entry and brings its day into view.
    private func selectEntry(_ x: Entry) {
        selectedEntryID = x.id
        let d = x.start.startOfDay
        if !visibleDays.contains(d) { selectedDay = d }
    }

    /// Return on the calendar: pick the selected entry back up. A running one opens in the editor.
    func returnOnSelection() {
        guard let id = selectedEntryID, let x = data.entries.first(where: { $0.id == id }) else { return }
        if x.isRunning { edit(id) } else { resume(id) }
    }

    /// Starts a new timer on the entry's project, with its note.
    func resume(_ id: UUID) {
        guard let x = data.entries.first(where: { $0.id == id }) else { return }
        start(x.projectID, note: x.note)
    }

    /// An entry that ended earlier today with nothing logged since can carry on as if it never stopped.
    func canContinue(_ id: UUID) -> Bool {
        let now = Date()
        guard running == nil, let x = data.entries.first(where: { $0.id == id }),
              let end = x.end, end <= now, end.isToday else { return false }
        return !data.entries.contains { $0.id != id && $0.start >= end && $0.start < now }
    }

    /// Reopens the entry so the time since it ended counts too.
    func continueEntry(_ id: UUID) {
        guard canContinue(id), let i = data.entries.firstIndex(where: { $0.id == id }) else { return }
        undoable("Resume Entry") {
            wakeDay(Date())
            data.entries[i].end = nil
        }
        selectedEntryID = id
    }

    // MARK: Zoom

    static let hourHeights: ClosedRange<Double> = 24...288
    static let defaultHourHeight: Double = 64

    func setHourHeight(_ h: Double) {
        let h = min(max(h, Self.hourHeights.lowerBound), Self.hourHeights.upperBound)
        if abs(h - prefs.hourHeight) > 0.01 { data.preferences.hourHeight = h }
    }

    func zoom(_ factor: Double) { setHourHeight(prefs.hourHeight * factor) }

    // MARK: Editing

    func newEntry(start: Date? = nil, end: Date? = nil, projectID: UUID? = nil) {
        let now = Date()
        var s = start, e = end
        if s == nil {
            let day = selectedDay
            let slot = suggestedSlot(on: day, now: now)
            s = slot.start
            e = slot.end
        }
        editing = EntryDraft(projectID: projectID ?? running?.projectID ?? activeProjects.first?.id,
                             start: s!, end: e ?? s!.addingTimeInterval(3600))
    }

    /// Where new time most likely belongs. Today: the stretch since the last finished entry, up to
    /// now, or up to the running timer, which is left alone. Other days: after the last entry.
    func suggestedSlot(on day: Date, now: Date = .now) -> (start: Date, end: Date) {
        let ds = day.startOfDay, de = ds.adding(days: 1)
        if day.isToday {
            let finished = data.entries.compactMap(\.end).filter { $0 >= ds && $0 <= now }
            if let r = running {
                let last = finished.filter { $0 <= r.start }.max()
                if let last, r.start.timeIntervalSince(last) >= 300 { return (last, r.start) }
                // No gap before the timer: the half hour before it, without reaching back past the last entry.
                return (max(last ?? .distantPast, r.start.addingTimeInterval(-1800)), r.start)
            }
            let last = finished.max()
            let end = max(now.floored(to: prefs.snapMinutes), last ?? .distantPast)
            if let last, end.timeIntervalSince(last) >= 300 { return (last, end) }
            // Nothing to fill in: offer the next half hour.
            return (end, min(end.addingTimeInterval(1800), de))
        }
        var start = latestEnd(on: day) ?? workday(day)?.start ?? day.at(hour: 9, minute: 0)
        if start >= de.addingTimeInterval(-900) { start = workday(day)?.start ?? day.at(hour: 9, minute: 0) }
        return (start, min(start.addingTimeInterval(3600), de))
    }

    /// Where a block of `length` goes when only its length is given ("design 1h30").
    func slot(lasting length: TimeInterval, on day: Date, now: Date = .now) -> (start: Date, end: Date) {
        if day.isToday {
            let end = running?.start ?? now.floored(to: prefs.snapMinutes)
            return (end.addingTimeInterval(-length), end)
        }
        let de = day.startOfDay.adding(days: 1)
        let start = min(latestEnd(on: day) ?? workday(day)?.start ?? day.at(hour: 9, minute: 0), de.addingTimeInterval(-length))
        return (start, start.addingTimeInterval(length))
    }

    private func latestEnd(on day: Date) -> Date? {
        let ds = day.startOfDay, de = ds.adding(days: 1)
        return data.entries.compactMap(\.end).filter { $0 > ds && $0 <= de }.max()
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
                // The running timer is never thrown away: the part before the new time is kept as
                // its own entry, and the timer carries on (same entry) from where the new time ends.
                if x.start < s && s.timeIntervalSince(x.start) >= minimum {
                    var finished = x
                    finished.id = UUID()
                    finished.end = s
                    out.append(finished)
                }
                x.start = max(x.start, min(e, now))
                out.append(x)
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

    /// Time logged while a timer runs can't reach past now, so the timer keeps running.
    private func clampToTimer(_ start: Date, _ end: Date?, except id: UUID?) -> Date? {
        guard let end, let r = running, r.id != id, end > r.start, start < Date() else { return end }
        return max(start.addingTimeInterval(60), min(end, Date()))
    }

    func save(_ d: EntryDraft) {
        guard let pid = d.projectID else { return }
        undoable(d.entryID == nil ? "Add Time" : "Edit Entry") { commitDraft(d, pid) }
        selectedDay = d.start.startOfDay
    }

    private func commitDraft(_ d: EntryDraft, _ pid: UUID) {
        let end: Date? = d.running ? nil : clampToTimer(d.start, d.end, except: d.entryID)
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

    func setTimes(_ id: UUID, start: Date, end: Date?, action: String = "Move Entry") {
        let end = clampToTimer(start, end, except: id)
        let effectiveEnd = end ?? Date()
        guard effectiveEnd.timeIntervalSince(start) >= 60 else { return }
        undoable(action) {
            carve(start, effectiveEnd, except: id)
            guard let j = data.entries.firstIndex(where: { $0.id == id }) else { return }
            data.entries[j].start = start
            data.entries[j].end = end
        }
    }

    /// Entries that adding or moving time to `[s, e)` would cut into, for a warning before it happens.
    func overlapping(_ s: Date, _ e: Date, except id: UUID?) -> [Entry] {
        entries(from: s, to: e).filter { $0.id != id }
    }

    func setProject(_ entryID: UUID, _ projectID: UUID) {
        guard let i = data.entries.firstIndex(where: { $0.id == entryID }) else { return }
        undoable("Change Project") { data.entries[i].projectID = projectID }
    }

    func setNote(_ entryID: UUID, _ note: String) {
        guard let i = data.entries.firstIndex(where: { $0.id == entryID }) else { return }
        undoable("Edit Note") { data.entries[i].note = note }
    }

    func delete(_ id: UUID) {
        undoable("Delete Entry") { data.entries.removeAll { $0.id == id } }
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
        undoable("New Project") {
            data.projects.append(p)
            normalizeProjectOrder()
        }
        return p
    }

    /// A name can't be left blank or padded; a blank one becomes "Untitled project".
    func tidyName(_ id: UUID) {
        guard let i = data.projects.firstIndex(where: { $0.id == id }) else { return }
        let n = data.projects[i].name.trimmingCharacters(in: .whitespaces)
        let tidy = n.isEmpty ? "Untitled project" : n
        if tidy != data.projects[i].name { data.projects[i].name = tidy }
    }

    /// Archived projects keep their history but leave the chips, shortcuts and menus.
    func setArchived(_ id: UUID, _ archived: Bool) {
        guard let i = data.projects.firstIndex(where: { $0.id == id }) else { return }
        undoable(archived ? "Archive Project" : "Restore Project") {
            if archived, running?.projectID == id { stop() }
            data.projects[i].archived = archived
        }
    }

    func deleteProject(_ id: UUID) {
        undoable("Delete Project") {
            if running?.projectID == id { stop() }
            data.entries.removeAll { $0.projectID == id }
            data.projects.removeAll { $0.id == id }
        }
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
        undoable("New Group") { data.groups.append(g) }
        return g
    }

    /// Removes the group. Its projects stay, ungrouped.
    func deleteGroup(_ id: UUID) {
        undoable("Delete Group") {
            for i in data.projects.indices where data.projects[i].groupID == id { data.projects[i].groupID = nil }
            data.groups.removeAll { $0.id == id }
            normalizeProjectOrder()
        }
    }

    /// Moves a project into a group (nil for none), just before `before`, or to the end of the group.
    func moveProject(_ id: UUID, to groupID: UUID?, before: UUID? = nil) {
        guard id != before, let i = data.projects.firstIndex(where: { $0.id == id }) else { return }
        undoable("Move Project") {
            var p = data.projects.remove(at: i)
            p.groupID = groupID
            if let before, let j = data.projects.firstIndex(where: { $0.id == before }) {
                data.projects.insert(p, at: j)
            } else if let last = data.projects.lastIndex(where: { $0.groupID == groupID && !$0.archived }) {
                data.projects.insert(p, at: last + 1)
            } else {
                data.projects.append(p)
            }
            normalizeProjectOrder()
        }
    }

    /// Moves a group to just before another, or to the end.
    func moveGroup(_ id: UUID, before: UUID?) {
        guard id != before, let i = data.groups.firstIndex(where: { $0.id == id }) else { return }
        undoable("Move Group") {
            let g = data.groups.remove(at: i)
            if let before, let j = data.groups.firstIndex(where: { $0.id == before }) {
                data.groups.insert(g, at: j)
            } else {
                data.groups.append(g)
            }
            normalizeProjectOrder()
        }
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

    /// Totals, recent weeks and last use for every project, in one pass over the entries.
    func projectFacts(weeks: Int = 12, now: Date = .now) -> [UUID: ProjectFacts] {
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let first = thisWeek.adding(days: -7 * (weeks - 1))
        var out: [UUID: ProjectFacts] = [:]
        for e in data.entries where e.start <= now {
            var f = out[e.projectID] ?? ProjectFacts(weeks: Array(repeating: 0, count: weeks))
            let d = e.duration(now: now)
            f.total += d
            f.last = max(f.last ?? .distantPast, e.effectiveEnd(now))
            if e.start >= first {
                let days = cal.dateComponents([.day], from: first, to: e.start.startOfDay).day ?? 0
                let w = min(weeks - 1, max(0, days / 7))
                f.weeks[w] += d
                if e.start >= thisWeek { f.thisWeek += d }
            }
            out[e.projectID] = f
        }
        return out
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
            // A day still under way has no end yet.
            let w = workday(d, now: now)
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
