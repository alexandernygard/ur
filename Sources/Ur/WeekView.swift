import SwiftUI
import AppKit

/// The timesheet: hours per project for a week or a month, with how the period is going,
/// what the time went to, and what still needs filling in. Editing happens in the calendar.
struct WeekView: View {
    @Environment(Store.self) private var store
    @AppStorage("sheetFormat") private var format: HourFormat = .clock
    @AppStorage("sheetRounding") private var rounding = 0

    var body: some View {
        let iv = store.sheetInterval
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let sheet = store.sheet(iv, period: store.sheetPeriod, rounding: rounding, now: ctx.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(sheet)
                    SheetSummary(sheet: sheet, format: format, now: ctx.date)
                    Timesheet(sheet: sheet, format: format)
                    HStack(alignment: .top, spacing: 20) {
                        WorkDigest(sheet: sheet, format: format)
                        LooseEnds(sheet: sheet, now: ctx.date)
                            .frame(width: 320)
                    }
                }
                .frame(maxWidth: 1180, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(store.sheetPeriod == .week ? "Week \(iv.start.weekNumber)" : Fmt.monthYear.string(from: iv.start))
        .navigationSubtitle(store.sheetPeriod == .week
            ? "\(Fmt.dayMonth.string(from: iv.start)) – \(Fmt.dayMonth.string(from: iv.end.adding(days: -1)))"
            : "Weeks \(iv.start.weekNumber)–\(iv.end.adding(days: -1).weekNumber)")
        .toolbar { DayToolbar() }
    }

    private func header(_ sheet: SheetModel) -> some View {
        @Bindable var store = store
        return HStack(spacing: 12) {
            Picker("Period", selection: $store.sheetPeriod) {
                ForEach(SheetPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Menu {
                Picker("Show hours as", selection: $format) {
                    Text("h:mm, like 7:45").tag(HourFormat.clock)
                    Text("Decimal, like 7.75").tag(HourFormat.decimal)
                }
                .pickerStyle(.inline)
                Picker("Round each day to", selection: $rounding) {
                    Text("The minute").tag(0)
                    Text("6 minutes (0.1 h)").tag(6)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                .pickerStyle(.inline)
            } label: {
                Text(rounding == 0 ? "Hours as \(format.title)" : "Hours as \(format.title), rounded to \(rounding)m")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("How hours are written and rounded here and when copied")
            Menu {
                Button("Copy for Spreadsheet") { copy(store.sheetTSV(sheet, format: format)) }
                Button("Copy Summary") { copy(store.sheetSummary(sheet, format: format)) }
                Divider()
                Button("Export Entries as CSV…") { export(sheet) }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .help("Copy the timesheet for a spreadsheet, or a written summary for a status update or invoice")
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func export(_ sheet: SheetModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ur-entries-\(sheet.interval.start.dayKey).csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? store.csvEntries(from: sheet.interval.start, to: sheet.interval.end)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: Model

/// One column of the timesheet: a day in a week, or a week in a month.
struct SheetColumn: Identifiable {
    var interval: DateInterval
    var title: String
    var subtitle: String
    var days: [DayStat]
    var id: Date { interval.start }
    var per: [UUID: TimeInterval] {
        days.reduce(into: [:]) { acc, d in for (k, v) in d.perProject { acc[k, default: 0] += v } }
    }
    var total: TimeInterval { days.reduce(0) { $0 + $1.total } }
    var atWork: TimeInterval { days.reduce(0) { $0 + ($1.span ?? 0) } }
}

struct SheetModel {
    var interval: DateInterval
    var period: SheetPeriod
    /// Days with their time rounded as chosen.
    var days: [DayStat]
    /// The same days unrounded, for time at work and unallocated time.
    var raw: [DayStat]
    var columns: [SheetColumn]
    var totals: [UUID: TimeInterval]
    /// The previous period's time per project, up to the same point when this period is under way.
    var previous: [UUID: TimeInterval]
    var previousName: String
    var entries: [Entry]
    var flex: TimeInterval
    var target: TimeInterval
    var isCurrent: Bool
    var total: TimeInterval { days.reduce(0) { $0 + $1.total } }
    var previousTotal: TimeInterval { previous.values.reduce(0, +) }
    var name: String {
        period == .week
            ? "Week \(interval.start.weekNumber), \(Fmt.dayMonth.string(from: interval.start)) – \(Fmt.dayMonth.string(from: interval.end.adding(days: -1)))"
            : Fmt.monthYear.string(from: interval.start)
    }
}

extension Store {
    func sheet(_ iv: DateInterval, period: SheetPeriod, rounding: Int, now: Date) -> SheetModel {
        let raw = dayStats(from: iv.start, to: iv.end, now: now)
        let days = raw.map { rounded($0, to: rounding) }
        let isCurrent = iv.contains(now)

        var columns: [SheetColumn] = []
        switch period {
        case .week:
            columns = days.map { d in
                SheetColumn(interval: DateInterval(start: d.day, end: d.day.adding(days: 1)),
                            title: Fmt.weekday.string(from: d.day),
                            subtitle: "\(cal.component(.day, from: d.day))", days: [d])
            }
        case .month:
            for d in days {
                if let last = columns.last, last.interval.start.startOfWeek == d.day.startOfWeek {
                    columns[columns.count - 1].days.append(d)
                    columns[columns.count - 1].interval.end = d.day.adding(days: 1)
                } else {
                    columns.append(SheetColumn(interval: DateInterval(start: d.day, end: d.day.adding(days: 1)),
                                               title: "W\(d.day.weekNumber)", subtitle: "", days: [d]))
                }
            }
            for i in columns.indices {
                let a = cal.component(.day, from: columns[i].interval.start)
                let b = cal.component(.day, from: columns[i].interval.end.adding(days: -1))
                columns[i].subtitle = a == b ? "\(a)" : "\(a)–\(b)"
            }
        }

        let prevStart = period == .week ? iv.start.adding(days: -7) : iv.start.adding(months: -1)
        let cut = isCurrent ? (period == .week ? now.addingTimeInterval(-7 * 86400) : cal.date(byAdding: .month, value: -1, to: now)!) : iv.start
        let prevDays = dayStats(from: prevStart, to: iv.start, now: cut).map { rounded($0, to: rounding) }
        let previous = prevDays.reduce(into: [UUID: TimeInterval]()) { acc, d in
            for (k, v) in d.perProject { acc[k, default: 0] += v }
        }

        return SheetModel(
            interval: iv, period: period, days: days, raw: raw, columns: columns,
            totals: days.reduce(into: [:]) { acc, d in for (k, v) in d.perProject { acc[k, default: 0] += v } },
            previous: previous,
            previousName: period == .week ? "week \(prevStart.weekNumber)" : Fmt.monthName.string(from: prevStart),
            entries: entries(from: iv.start, to: iv.end, now: now).filter { $0.start <= now },
            flex: flex(days, now: now),
            target: days.reduce(0) { $0 + target(on: $1.day) },
            isCurrent: isCurrent)
    }

    private func rounded(_ d: DayStat, to minutes: Int) -> DayStat {
        guard minutes > 0 else { return d }
        let step = Double(minutes * 60)
        var d = d
        d.perProject = d.perProject.mapValues { ($0 / step).rounded() * step }.filter { $0.value > 0 }
        d.total = d.perProject.values.reduce(0, +)
        return d
    }

    /// Tab-separated rows that paste straight into Numbers, Excel or Google Sheets.
    func sheetTSV(_ s: SheetModel, format: HourFormat) -> String {
        let cols = s.columns
        func v(_ t: TimeInterval) -> String { t >= 60 ? format.string(t) : "" }
        var rows = [(["Project", "Group"] + cols.map { "\($0.title) \($0.subtitle)" } + ["Total"]).joined(separator: "\t")]
        for t in tally(s.totals, byTotal: false) {
            for p in t.projects {
                rows.append(([name(p.id), t.group?.name ?? ""] + cols.map { v($0.per[p.id] ?? 0) } + [v(p.time)])
                    .joined(separator: "\t"))
            }
        }
        rows.append((["Total", ""] + cols.map { v($0.total) } + [v(s.total)]).joined(separator: "\t"))
        return rows.joined(separator: "\n") + "\n"
    }

    /// A short written account of the period: time per project and what it went to, from the notes.
    func sheetSummary(_ s: SheetModel, format: HourFormat) -> String {
        var out = ["\(s.name): \(format.string(s.total)) tracked", ""]
        for t in tally(s.totals) {
            for p in t.projects {
                let group = t.group.map { " (\($0.name))" } ?? ""
                out.append("- \(name(p.id))\(group): \(format.string(p.time))")
                for n in noteDigest(s, project: p.id) where !n.text.isEmpty {
                    out.append("  - \(n.text): \(format.string(n.time))")
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Time per note for one project in the period, largest first. Unnoted time has empty text.
    func noteDigest(_ s: SheetModel, project: UUID) -> [NoteLine] {
        var lines: [String: NoteLine] = [:]
        for x in s.entries where x.projectID == project {
            let text = x.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = text.lowercased()
            let d = x.duration(from: s.interval.start, to: s.interval.end)
            var line = lines[key] ?? NoteLine(text: text, time: 0, days: [])
            line.time += d
            line.days.insert(x.start.startOfDay)
            lines[key] = line
        }
        return lines.values.filter { $0.time >= 60 }.sorted { $0.time > $1.time }
    }
}

struct NoteLine: Hashable {
    var text: String
    var time: TimeInterval
    var days: Set<Date>
}

extension Fmt {
    static let monthName = DateFormatter.ur("MMMM")
    static let weekdayDay = DateFormatter.ur("EEE d MMM")
}

extension DateFormatter {
    static func ur(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }
}

/// "+1:20", "−0:45"
func signed(_ t: TimeInterval, _ format: HourFormat) -> String {
    (t < 0 ? "−" : "+") + format.string(abs(t))
}

// MARK: Summary

/// The figures above the table: progress towards the target, flex, today, and the pace against
/// the previous period.
struct SheetSummary: View {
    @Environment(Store.self) private var store
    let sheet: SheetModel
    let format: HourFormat
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            figure("Tracked", format.string(sheet.total)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(sheet.target > 0 ? "of \(format.string(sheet.target)) target" : "No target this period")
                    progress
                }
            }
            .help("Your target is \(Fmt.hours(store.prefs.targetHours * 3600)) hours each weekday. Change it in Settings.")
            divider
            figure("Flex", signed(sheet.flex, format)) {
                if Date().startOfDay.adding(days: -1) >= cal.dateInterval(of: .year, for: now)!.start, sheet.isCurrent {
                    Text("\(signed(store.yearFlex(now: now), format)) since 1 January")
                } else {
                    Text(sheet.flex >= 0 ? "over target" : "under target")
                }
            }
            .help("Time tracked beyond the target on the days you worked. Days with nothing tracked count as days off, and today counts once you end the day.")
            divider
            if sheet.isCurrent {
                today
            } else {
                busiest
            }
            divider
            pace
        }
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1).padding(.vertical, 2)
    }

    private func figure<C: View>(_ label: String, _ value: String, @ViewBuilder detail: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(Theme.inkSoft)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            detail().font(.caption).foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One segment per column, filled by how much of its target was tracked.
    private var progress: some View {
        HStack(spacing: 3) {
            ForEach(sheet.columns) { c in
                let target = c.days.reduce(0) { $0 + store.target(on: $1.day) }
                let share = target > 0 ? min(1, c.total / target) : (c.total > 0 ? 1 : 0)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line.opacity(target > 0 ? 0.9 : 0.35))
                        Capsule().fill(share >= 1 ? Theme.gran : Theme.inkSoft.opacity(0.7))
                            .frame(width: g.size.width * share)
                    }
                }
                .frame(height: 4)
                .help("\(c.title) \(c.subtitle): \(format.string(c.total))" + (target > 0 ? " of \(format.string(target))" : ""))
            }
        }
        .frame(maxWidth: 220)
    }

    private var today: some View {
        let day = sheet.raw.first { $0.day.isToday }
        let tracked = day?.total ?? 0
        let target = store.target(on: now)
        let left = target - tracked
        let value = target > 0 ? "\(format.string(tracked)) of \(format.string(target))" : format.string(tracked)
        return figure("Today", value) {
            if target == 0 {
                Text("A day off by the target")
            } else if left <= 0 {
                Text("Target met, \(format.string(-left)) over")
            } else if store.running != nil, now.addingTimeInterval(left).isToday {
                Text("Reaches \(format.string(target)) at \(Fmt.time(now.addingTimeInterval(left))) if you keep going")
            } else {
                Text("\(format.string(left)) to go")
            }
        }
    }

    private var busiest: some View {
        let top = sheet.days.max { $0.total < $1.total }
        return figure("Longest day", format.string(top?.total ?? 0)) {
            if let top, top.total > 0 {
                Text(Fmt.weekdayDay.string(from: top.day))
            } else {
                Text("Nothing tracked")
            }
        }
    }

    private var pace: some View {
        let diff = sheet.total - sheet.previousTotal
        return figure("Versus \(sheet.previousName)", signed(diff, format)) {
            if sheet.isCurrent {
                Text("\(format.string(sheet.previousTotal)) at this point then")
            } else {
                Text("\(format.string(sheet.previousTotal)) in all")
            }
        }
        .help(sheet.isCurrent
            ? "Compared with the same point in \(sheet.previousName), so a period under way is measured fairly"
            : "Compared with all of \(sheet.previousName)")
    }
}

// MARK: Table

/// Hours per project per column, like a classic timesheet, shaded by how much each cell holds.
struct Timesheet: View {
    @Environment(Store.self) private var store
    let sheet: SheetModel
    let format: HourFormat
    @State private var collapsed: Set<UUID> = []
    @State private var hoverColumn: Date?

    private var width: CGFloat { sheet.period == .week ? 66 : 84 }
    private let totalWidth: CGFloat = 76

    var body: some View {
        let tallies = store.tally(sheet.totals, byTotal: false)
        let hottest = sheet.columns.flatMap { $0.per.values }.max() ?? 1
        Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(sheet.columns) { c in columnHeader(c) }
                Text("Total").foregroundStyle(Theme.inkSoft).frame(width: totalWidth, alignment: .trailing)
                Text("vs \(sheet.period == .week ? "last wk" : "last mo")")
                    .foregroundStyle(Theme.inkSoft).frame(width: totalWidth, alignment: .trailing)
                    .help("Change from \(sheet.previousName)" + (sheet.isCurrent ? " at the same point" : ""))
            }
            .font(.caption.weight(.medium))
            .padding(.bottom, 6)

            Divider().gridCellUnsizedAxes(.horizontal)

            if tallies.isEmpty {
                GridRow {
                    Text(sheet.period == .week ? "No time tracked this week." : "No time tracked this month.")
                        .foregroundStyle(Theme.inkSoft)
                        .gridCellColumns(sheet.columns.count + 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10)
            }

            ForEach(tallies) { t in
                if let g = t.group {
                    groupRow(g, t)
                    if !collapsed.contains(g.id) {
                        ForEach(t.projects) { p in projectRow(p.id, indent: true, hottest: hottest) }
                    }
                } else {
                    projectRow(t.id, indent: false, hottest: hottest)
                }
            }

            GridRow {
                Text("Tracked").fontWeight(.semibold).gridColumnAlignment(.leading)
                ForEach(sheet.columns) { c in cell(c.total, bold: true) }
                cell(sheet.total, bold: true).frame(width: totalWidth, alignment: .trailing)
                delta(sheet.total, sheet.previousTotal)
            }
            .padding(.vertical, 6)
            footerRow("At work", help: "From the start to the end of each work day") { c in
                cell(c.atWork).foregroundStyle(Theme.molte)
            } total: {
                cell(sheet.raw.reduce(0) { $0 + ($1.span ?? 0) }).foregroundStyle(Theme.molte)
            }
            footerRow("Unallocated", help: "Time at work that isn't in any entry. Click a day in the calendar's gaps to fill it in.") { c in
                cell(unallocated(c.days, raw: true), soft: true)
            } total: {
                cell(unallocated(sheet.raw, raw: true), soft: true)
            }
            footerRow("Flex", help: "Tracked time against your target of \(Fmt.hours(store.prefs.targetHours * 3600)) hours each weekday. Days with nothing tracked count as days off.") { c in
                flexCell(c.days)
            } total: {
                flexCell(sheet.days)
            }
        }
        .font(.callout)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private func unallocated(_ days: [DayStat], raw: Bool) -> TimeInterval {
        let byDay = Dictionary(uniqueKeysWithValues: sheet.raw.map { ($0.day, $0) })
        return days.reduce(0) { acc, d in
            let r = byDay[d.day] ?? d
            return acc + max(0, (r.span ?? 0) - r.total)
        }
    }

    @ViewBuilder
    private func flexCell(_ days: [DayStat]) -> some View {
        let counted = days.contains { $0.total > 0 && ($0.day < Date().startOfDay || ($0.day.isToday && $0.end != nil)) }
        let f = store.flex(days)
        Text(counted ? signed(f, format) : "·")
            .monospacedDigit()
            .foregroundStyle(counted ? (f < 0 ? Theme.inkSoft : Theme.gran) : Theme.line)
            .frame(width: width, alignment: .trailing)
    }

    private func footerRow<A: View, B: View>(_ label: String, help: String,
                                              @ViewBuilder _ value: @escaping (SheetColumn) -> A,
                                              @ViewBuilder total: () -> B) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.inkSoft).help(help)
            ForEach(sheet.columns) { c in value(c) }
            total().frame(width: totalWidth, alignment: .trailing)
            Text("")
        }
        .padding(.vertical, 5)
    }

    private func columnHeader(_ c: SheetColumn) -> some View {
        let today = c.interval.contains(Date())
        let target = c.days.reduce(0) { $0 + store.target(on: $1.day) }
        let share = target > 0 ? min(1, c.total / target) : 0
        return Button { openColumn(c) } label: {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    Text(c.title).foregroundStyle(today ? Theme.gran : Theme.inkSoft)
                    Text(c.subtitle).foregroundStyle(today ? Theme.gran : Theme.ink)
                }
                // How far the column got towards its target.
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line.opacity(target > 0 ? 1 : 0))
                    Capsule().fill(share >= 1 ? Theme.gran : Theme.inkSoft.opacity(0.6))
                        .frame(width: 36 * share)
                }
                .frame(width: 36, height: 3)
            }
            .frame(width: width, alignment: .trailing)
            .padding(.vertical, 2)
            .background(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 5).fill(Theme.line.opacity(hoverColumn == c.id ? 0.6 : 0))
                    .frame(width: width - 8)
                    .padding(.trailing, -4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverColumn = $0 ? c.id : (hoverColumn == c.id ? nil : hoverColumn) }
        .help(sheet.period == .week
            ? "Open \(Fmt.dayTitle.string(from: c.interval.start)) in the calendar"
            : "Show week \(c.interval.start.weekNumber)")
    }

    private func openColumn(_ c: SheetColumn, project: UUID? = nil) {
        if sheet.period == .week {
            store.open(c.interval.start, project: project)
        } else {
            store.sheetPeriod = .week
            store.selectedDay = c.interval.start
        }
    }

    @ViewBuilder
    private func groupRow(_ g: ProjectGroup, _ t: Tally) -> some View {
        let open = !collapsed.contains(g.id)
        let ids = t.projects.map(\.id)
        GridRow {
            Button {
                if open { collapsed.insert(g.id) } else { collapsed.remove(g.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.inkSoft)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text(g.name).fontWeight(.semibold).lineLimit(1)
                }
                .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the projects in \(g.name)" : "Show the projects in \(g.name)")
            ForEach(sheet.columns) { c in
                cell(ids.reduce(0) { $0 + (c.per[$1] ?? 0) }, bold: true)
            }
            cell(t.total, bold: true).frame(width: totalWidth, alignment: .trailing)
            delta(t.total, ids.reduce(0) { $0 + (sheet.previous[$1] ?? 0) })
        }
        .padding(.vertical, 6)
        Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal)
    }

    @ViewBuilder
    private func projectRow(_ id: UUID, indent: Bool, hottest: TimeInterval) -> some View {
        let color = store.color(id)
        let total = sheet.totals[id] ?? 0
        GridRow {
            HStack(spacing: 8) {
                Dot(color: color)
                Text(store.name(id)).lineLimit(1)
            }
            .padding(.leading, indent ? 16 : 0)
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
            ForEach(sheet.columns) { c in
                let t = c.per[id] ?? 0
                Button { openColumn(c, project: id) } label: {
                    cell(t)
                        .padding(.vertical, 4)
                        .background(alignment: .trailing) {
                            // Busier cells are shaded more deeply in the project's colour.
                            RoundedRectangle(cornerRadius: 5)
                                .fill(color.opacity(t >= 60 ? 0.07 + 0.28 * min(1, t / max(1, hottest)) : 0))
                                .frame(width: width - 8)
                                .padding(.trailing, -4)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t >= 60 ? tooltip(id, c) : "")
            }
            cell(total, bold: !indent).frame(width: totalWidth, alignment: .trailing)
            delta(total, sheet.previous[id] ?? 0)
        }
        .padding(.vertical, 2)
        Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal)
    }

    /// The entries behind a cell, with their times and notes.
    private func tooltip(_ id: UUID, _ c: SheetColumn) -> String {
        let xs = sheet.entries.filter { $0.projectID == id && $0.start < c.interval.end && $0.effectiveEnd() > c.interval.start }
        let head = "\(store.name(id)), " + (sheet.period == .week
            ? Fmt.weekdayDay.string(from: c.interval.start)
            : "week \(c.interval.start.weekNumber)")
        let lines = xs.prefix(12).map { x -> String in
            let range = sheet.period == .week
                ? Fmt.range(x.start, x.effectiveEnd())
                : "\(Fmt.weekday.string(from: x.start)) \(Fmt.range(x.start, x.effectiveEnd()))"
            return "\(range)  \(format.string(x.duration(from: c.interval.start, to: c.interval.end)))" + (x.note.isEmpty ? "" : "  \(x.note)")
        }
        let more = xs.count > 12 ? ["and \(xs.count - 12) more"] : []
        let action = sheet.period == .week ? "Click to open it in the calendar" : "Click to show the week"
        return ([head] + lines + more + ["", action]).joined(separator: "\n")
    }

    private func delta(_ now: TimeInterval, _ before: TimeInterval) -> some View {
        let d = now - before
        let text: String
        if before < 60 && now >= 60 {
            text = "new"
        } else if abs(d) < 60 {
            text = "·"
        } else {
            text = (d > 0 ? "▲ " : "▼ ") + format.string(abs(d))
        }
        return Text(text)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(text == "·" ? Theme.line : Theme.inkSoft)
            .frame(width: totalWidth, alignment: .trailing)
    }

    private func cell(_ t: TimeInterval, bold: Bool = false, soft: Bool = false) -> some View {
        Text(t >= 60 ? format.string(t) : "·")
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(t >= 60 ? (soft ? Theme.inkSoft : Theme.ink) : Theme.line)
            .frame(width: width, alignment: .trailing)
    }
}

// MARK: What you worked on

/// Each project's time broken down by the notes on its entries.
struct WorkDigest: View {
    @Environment(Store.self) private var store
    let sheet: SheetModel
    let format: HourFormat
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let projects = store.tally(sheet.totals).flatMap(\.projects)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("What you worked on").font(.headline)
                Spacer()
                Button("Copy Summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.sheetSummary(sheet, format: format), forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .disabled(projects.isEmpty)
                .help("Copy each project's time and notes as a list, ready for a status update or an invoice")
            }
            if projects.isEmpty {
                Text("Tracked time shows up here, sorted by the notes you give your entries.")
                    .foregroundStyle(Theme.inkSoft)
            }
            ForEach(projects) { p in
                project(p)
            }
            if !projects.isEmpty && sheet.entries.allSatisfy({ $0.note.isEmpty }) {
                Text("Add a note to an entry, such as “design review”, and the time is broken down by it here.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private func project(_ p: ProjectTime) -> some View {
        let notes = store.noteDigest(sheet, project: p.id)
        let open = expanded.contains(p.id)
        let shown = open ? notes : Array(notes.prefix(4))
        let longest = notes.first?.time ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Dot(color: store.color(p.id))
                Text(store.name(p.id)).fontWeight(.semibold).lineLimit(1)
                if let g = store.groupName(of: p.id) {
                    Text(g).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
                Spacer()
                Text(format.string(p.time)).monospacedDigit().fontWeight(.semibold)
            }
            .font(.callout)
            if !(notes.count == 1 && notes[0].text.isEmpty) {
                ForEach(shown, id: \.self) { n in
                    HStack(spacing: 10) {
                        Text(n.text.isEmpty ? "No note" : n.text)
                            .foregroundStyle(n.text.isEmpty ? Theme.inkSoft : Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(days(n.days))
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(1)
                        // A short bar for comparing notes within the project.
                        Capsule().fill(store.color(p.id).opacity(0.55))
                            .frame(width: max(2, 48 * n.time / longest), height: 4)
                            .frame(width: 48, alignment: .leading)
                        Text(format.string(n.time))
                            .monospacedDigit()
                            .foregroundStyle(Theme.inkSoft)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.leading, 16)
                }
                if notes.count > 4 {
                    Button(open ? "Show less" : "Show \(notes.count - 4) more") {
                        if open { expanded.remove(p.id) } else { expanded.insert(p.id) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.leading, 16)
                }
            }
        }
    }

    /// "Mon, Wed" in a week; "4 days" in a month.
    private func days(_ set: Set<Date>) -> String {
        if sheet.period == .month || set.count > 3 {
            return set.count == 1 ? Fmt.dayMonth.string(from: set.first!) : "\(set.count) days"
        }
        return set.sorted().map { Fmt.weekday.string(from: $0) }.joined(separator: ", ")
    }
}

// MARK: Loose ends

/// Things to fix before the period is sent off: forgotten timers, unallocated time, empty days.
struct LooseEnds: View {
    @Environment(Store.self) private var store
    let sheet: SheetModel
    let now: Date
    @State private var showAll = false

    struct Item: Identifiable {
        var id: String
        var icon: String
        var title: String
        var detail: String
        var action: String
        var run: () -> Void
    }

    var body: some View {
        let items = findItems()
        let shown = showAll ? items : Array(items.prefix(6))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Loose ends").font(.headline)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.line.opacity(0.7)))
                }
            }
            if items.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.gran)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing to tidy up")
                        Text("No gaps, empty weekdays or forgotten timers \(sheet.period == .week ? "this week" : "this month").")
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
                .font(.callout)
            }
            ForEach(shown) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.icon)
                        .foregroundStyle(Theme.inkSoft)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.detail).font(.caption).foregroundStyle(Theme.inkSoft)
                    }
                    Spacer(minLength: 8)
                    Button(item.action, action: item.run)
                        .controlSize(.small)
                }
                .font(.callout)
            }
            if items.count > 6 {
                Button(showAll ? "Show less" : "Show \(items.count - 6) more") { showAll.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private func findItems() -> [Item] {
        var out: [(Date, Item)] = []
        let today = now.startOfDay

        // A timer left running overnight.
        if let r = store.running, r.start < today, sheet.interval.contains(now) {
            out.append((r.start, Item(id: "run", icon: "timer", title: "\(store.name(r.projectID)) has run since \(Fmt.weekday.string(from: r.start)) \(Fmt.time(r.start))",
                                      detail: "\(Fmt.hmm(now.timeIntervalSince(r.start))) so far. Was it left on?",
                                      action: "Edit") { store.edit(r.id) }))
        }

        // Entries long enough to be a forgotten timer.
        for x in sheet.entries where !x.isRunning && x.duration() >= 10 * 3600 {
            out.append((x.start, Item(id: x.id.uuidString, icon: "hourglass", title: "\(store.name(x.projectID)) ran for \(Fmt.hmm(x.duration()))",
                                      detail: "\(Fmt.weekdayDay.string(from: x.start)), \(Fmt.range(x.start, x.effectiveEnd()))",
                                      action: "Edit") { store.edit(x.id) }))
        }

        // Unallocated time at work, on days that are over.
        for d in sheet.raw where d.day < today {
            let gaps = store.gaps(d.day, now: now)
            let sum = gaps.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            guard sum >= 15 * 60 else { continue }
            out.append((d.day, Item(id: "gap\(d.day.dayKey)", icon: "rectangle.dashed",
                                    title: "\(Fmt.hmm(sum)) unallocated on \(Fmt.weekday.string(from: d.day))",
                                    detail: "\(Fmt.weekdayDay.string(from: d.day)), \(gaps.count == 1 ? Fmt.range(gaps[0].start, gaps[0].end) : "\(gaps.count) gaps")",
                                    action: "Open") { store.open(d.day) }))
        }

        // Weekdays with nothing at all, merged into runs. Only after tracking began.
        if let first = store.data.entries.map(\.start).min()?.startOfDay {
            var run: [Date] = []
            func flush() {
                guard let a = run.first, let b = run.last else { return }
                let title = run.count == 1 ? "Nothing tracked on \(Fmt.weekday.string(from: a))"
                                           : "Nothing tracked for \(run.count) weekdays"
                let detail = run.count == 1 ? "\(Fmt.weekdayDay.string(from: a)). A day off?"
                                            : "\(Fmt.dayMonth.string(from: a)) – \(Fmt.dayMonth.string(from: b)). Time off?"
                out.append((a, Item(id: "empty\(a.dayKey)", icon: "calendar.badge.exclamationmark", title: title,
                                    detail: detail, action: "Open") { store.open(a) }))
                run = []
            }
            for d in sheet.raw where d.day >= first && d.day < today {
                if cal.isDateInWeekend(d.day) { continue }
                if d.total == 0 && store.recordedDay(d.day)?.start == nil { run.append(d.day) } else { flush() }
            }
            flush()
        }

        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
