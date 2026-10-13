import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

enum StatsRange: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }
    var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

struct StatsView: View {
    @Environment(Store.self) private var store
    @State private var range: StatsRange = .week
    @State private var anchor = Date()
    @State private var hoverDay: Date?

    private var interval: DateInterval { cal.dateInterval(of: range.component, for: anchor)! }

    private var title: String {
        let i = interval
        switch range {
        case .week: return "Week \(i.start.weekNumber), \(Fmt.dayMonth.string(from: i.start)) – \(Fmt.dayMonth.string(from: i.end.adding(days: -1)))"
        case .month: return Fmt.monthYear.string(from: i.start)
        case .year: return String(cal.component(.year, from: i.start))
        }
    }

    var body: some View {
        let i = interval
        // Redraw every minute so a running timer and today's day keep counting.
        TimelineView(.everyMinute) { ctx in
            content(i, now: ctx.date)
        }
        .navigationTitle("Stats")
        .navigationSubtitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ControlGroup {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Button("Now") { anchor = Date() }
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }
            }
            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $range) {
                    ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Entries as CSV…") { export(store.csvEntries(from: i.start, to: i.end), name: "ur-entries") }
                    Button("Work days as CSV…") { export(store.csvDays(from: i.start, to: i.end), name: "ur-days") }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func content(_ i: DateInterval, now: Date) -> some View {
        let days = store.dayStats(from: i.start, to: min(i.end, now.startOfDay.adding(days: 1)), now: now)
        let projectIDs = orderedProjects(days)
        return ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                Figures(days: days, target: store.prefs.targetHours)
                section("Hours per \(range == .year ? "month" : "day")") {
                    hoursChart(days, projectIDs: projectIDs, now: now)
                }
                section("Start and end of day", note: "Amber bars run from when you started the day to when you ended it.") {
                    spanChart(days, now: now)
                }
                HStack(alignment: .top, spacing: 32) {
                    section("By project") { ProjectTable(days: days) }
                        .frame(maxWidth: .infinity)
                    section("Time of day", note: "When tracked time happens, summed over the period.") {
                        hourOfDayChart(i, now: now)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
    }

    private var header: some View {
        Text(title)
            .font(.system(size: 34, weight: .light).width(.compressed))
            .foregroundStyle(Theme.ink)
    }

    private func shift(_ dir: Int) {
        anchor = cal.date(byAdding: range.component, value: dir, to: anchor) ?? anchor
    }

    private func orderedProjects(_ days: [DayStat]) -> [UUID] {
        var totals: [UUID: TimeInterval] = [:]
        for d in days { for (k, v) in d.perProject { totals[k, default: 0] += v } }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let note { Text(note).font(.caption).foregroundStyle(Theme.inkSoft) }
            }
            content()
        }
    }

    // MARK: Charts

    private struct Bar: Identifiable {
        var bucket: Date
        var project: String
        var hours: Double
        var id: String { "\(bucket.timeIntervalSince1970)-\(project)" }
    }

    private func buckets(_ days: [DayStat]) -> [(Date, [UUID: TimeInterval])] {
        guard range == .year else { return days.map { ($0.day, $0.perProject) } }
        var out: [Date: [UUID: TimeInterval]] = [:]
        for d in days {
            let m = cal.dateInterval(of: .month, for: d.day)!.start
            for (k, v) in d.perProject { out[m, default: [:]][k, default: 0] += v }
        }
        return out.sorted { $0.key < $1.key }
    }

    @ViewBuilder
    private func hoursChart(_ days: [DayStat], projectIDs: [UUID], now: Date) -> some View {
        let names = projectIDs.map { store.name($0) }
        let colors = projectIDs.map { store.color($0) }
        let bars = buckets(days).flatMap { b, per in
            projectIDs.compactMap { id in per[id].map { Bar(bucket: b, project: store.name(id), hours: $0 / 3600) } }
        }
        let unit: Calendar.Component = range == .year ? .month : .day
        let fullRange = interval

        if bars.isEmpty {
            empty("Nothing tracked in this period.")
        } else {
            Chart {
                ForEach(bars) { b in
                    BarMark(x: .value("Day", b.bucket, unit: unit), y: .value("Hours", b.hours))
                        .foregroundStyle(by: .value("Project", b.project))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                if range != .year {
                    RuleMark(y: .value("Target", store.prefs.targetHours))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.inkSoft)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Target \(Fmt.hours(store.prefs.targetHours * 3600))h")
                                .font(.caption2).foregroundStyle(Theme.inkSoft)
                        }
                }
                if let h = hoverDay {
                    RuleMark(x: .value("Day", h, unit: unit))
                        .foregroundStyle(Theme.ink.opacity(0.06))
                }
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartXScale(domain: fullRange.start...fullRange.end)
            .chartXAxis {
                AxisMarks(values: .stride(by: unit == .month ? .month : (range == .month ? .weekOfYear : .day))) { v in
                    axisDateLabel(v, month: unit == .month)
                }
            }
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h") } }
                }
            }
            // Only the hovered day or month is kept, so moving within a bar doesn't redraw the chart.
            .chartXSelection(value: Binding(
                get: { hoverDay },
                set: { new in
                    let b = new.flatMap { cal.dateInterval(of: unit, for: $0)?.start }
                    if b != hoverDay { hoverDay = b }
                }))
            // The tooltip floats above the chart rather than being part of it, so showing it
            // never changes the chart's layout (which made it jitter under the pointer).
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let h = hoverDay,
                       let day = days.first(where: { cal.isDate($0.day, equalTo: h, toGranularity: unit) }),
                       let plot = proxy.plotFrame,
                       let x0 = proxy.position(forX: h),
                       let x1 = proxy.position(forX: cal.dateInterval(of: unit, for: h)!.end) {
                        let frame = geo[plot]
                        let mid = frame.minX + (x0 + x1) / 2
                        let w: CGFloat = 200
                        tooltip(day, unit: unit, days: days, now: now)
                            .frame(width: w)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(x: min(max(mid - w / 2, frame.minX), frame.maxX - w), y: frame.minY + 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 260)
        }
    }

    @ViewBuilder
    private func tooltip(_ day: DayStat, unit: Calendar.Component, days: [DayStat], now: Date) -> some View {
        let per: [UUID: TimeInterval] = unit == .month
            ? days.filter { cal.isDate($0.day, equalTo: day.day, toGranularity: .month) }
                .reduce(into: [:]) { acc, d in for (k, v) in d.perProject { acc[k, default: 0] += v } }
            : day.perProject
        VStack(alignment: .leading, spacing: 4) {
            Text(unit == .month ? Fmt.monthYear.string(from: day.day) : Fmt.dayTitle.string(from: day.day))
                .font(.caption.weight(.semibold))
            ForEach(per.sorted { $0.value > $1.value }, id: \.key) { k, v in
                HStack(spacing: 6) {
                    Dot(color: store.color(k), size: 6)
                    Text(store.name(k))
                    Spacer(minLength: 12)
                    Text(Fmt.dur(v)).monospacedDigit()
                }
                .font(.caption)
            }
            let total = per.values.reduce(0, +)
            // The timer is still adding to this day (or month).
            let bucket = cal.dateInterval(of: unit, for: day.day)!
            let live = store.running.map { $0.start < bucket.end && now > bucket.start && now < bucket.end } ?? false
            if per.count > 1 || live {
                Divider()
                HStack(spacing: 6) {
                    Text(live ? "Total so far" : "Total")
                    Spacer(minLength: 12)
                    Text(Fmt.dur(total)).monospacedDigit()
                }
                .font(.caption.weight(.semibold))
            }
            if unit == .day, let s = day.start {
                Text("Day \(Fmt.time(s))–\(day.end.map { Fmt.time($0) } ?? (day.day.isToday ? "now" : "–"))")
                    .font(.caption).foregroundStyle(Theme.molte)
            }
        }
        .padding(8)
        .frame(minWidth: 160)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
    }

    private struct Span: Identifiable {
        var day: Date
        var start: Double
        var end: Double
        var id: Date { day }
    }

    @ViewBuilder
    private func spanChart(_ days: [DayStat], now: Date) -> some View {
        let spans = days.compactMap { d -> Span? in
            guard let s = d.start else { return nil }
            let e = d.end ?? (d.day.isToday ? now : nil)
            guard let e, e > s else { return nil }
            return Span(day: d.day, start: s.hoursIntoDay, end: min(24, e.timeIntervalSince(d.day) / 3600))
        }
        if spans.isEmpty {
            empty("No work days recorded. Press ⌘D to start your day.")
        } else {
            let starts = days.compactMap { $0.start?.hoursIntoDay }
            let ends = days.compactMap { $0.end?.hoursIntoDay }
            let avgStart = starts.reduce(0, +) / Double(max(1, starts.count))
            let avgEnd: Double? = ends.isEmpty ? nil : ends.reduce(0, +) / Double(ends.count)
            // The averages can include days without a bar (started but never ended), so keep them in range too.
            let lo = max(0, floor(min(spans.map(\.start).min()!, avgStart, avgEnd ?? 24) - 1))
            let hi = min(24, ceil(max(spans.map(\.end).max()!, avgStart, avgEnd ?? 0) + 1))
            let unit: Calendar.Component = .day
            let fullRange = interval
            Chart {
                ForEach(spans) { s in
                    BarMark(x: .value("Day", s.day, unit: unit),
                            yStart: .value("Start", -s.start),
                            yEnd: .value("End", -s.end),
                            width: .ratio(range == .year ? 1 : 0.55))
                        .foregroundStyle(Theme.molte.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: range == .year ? 0 : 3))
                }
                RuleMark(y: .value("Average start", -avgStart))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.inkSoft)
                    .annotation(position: .top, alignment: .leading) {
                        Text("Avg start \(Fmt.clockHour(avgStart))").font(.caption2).foregroundStyle(Theme.inkSoft)
                    }
                if let avgEnd {
                RuleMark(y: .value("Average end", -avgEnd))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.inkSoft)
                    .annotation(position: .bottom, alignment: .leading) {
                        Text("Avg end \(Fmt.clockHour(avgEnd))").font(.caption2).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
            // Negated so the morning sits at the top, like a timetable.
            .chartYScale(domain: -hi ... -lo)
            .chartXScale(domain: fullRange.start...fullRange.end)
            .chartPlotStyle { $0.clipped() }
            .chartYAxis {
                AxisMarks(values: .stride(by: 2)) { v in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel { if let h = v.as(Double.self) { Text(Fmt.clockHour(-h)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: range == .year ? .month : (range == .month ? .weekOfYear : .day))) { v in
                    axisDateLabel(v, month: range == .year)
                }
            }
            .frame(height: 220)
        }
    }

    private struct HourBin: Identifiable {
        var hour: Int
        var hours: Double
        var id: Int { hour }
    }

    @ViewBuilder
    private func hourOfDayChart(_ i: DateInterval, now: Date) -> some View {
        var bins = Array(repeating: 0.0, count: 24)
        let _ = {
            for e in store.entries(from: i.start, to: i.end, now: now) {
                var t = max(e.start, i.start)
                let end = min(e.effectiveEnd(now), i.end, now)
                while t < end {
                    let h = cal.component(.hour, from: t)
                    let next = min(cal.date(bySetting: .minute, value: 0, of: t.addingTimeInterval(3600)) ?? end, end)
                    let step = max(next.timeIntervalSince(t), 1)
                    bins[h] += step / 3600
                    t = t.addingTimeInterval(step)
                }
            }
        }()
        let data = bins.enumerated().map { HourBin(hour: $0.offset, hours: $0.element) }
        if bins.allSatisfy({ $0 == 0 }) {
            empty("No tracked time yet.")
        } else {
            let active = data.filter { $0.hours > 0 }
            let lo = max(0, (active.first?.hour ?? 6) - 1), hi = min(23, (active.last?.hour ?? 18) + 1)
            Chart(data.filter { $0.hour >= lo && $0.hour <= hi }) { b in
                BarMark(x: .value("Hour", String(format: "%02d", b.hour)), y: .value("Hours", b.hours))
                    .foregroundStyle(Theme.gran)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Fmt.hours(h * 3600))h") } }
                }
            }
            .frame(height: 220)
        }
    }

    private func axisDateLabel(_ v: AxisValue, month: Bool) -> some AxisMark {
        AxisValueLabel(centered: !month) {
            if let d = v.as(Date.self) {
                Text(month ? Fmt.month.string(from: d) : "\(Fmt.weekday.string(from: d)) \(cal.component(.day, from: d))")
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Theme.inkSoft)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private func export(_ csv: String, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(name)-\(interval.start.dayKey).csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// The plain row of headline figures above the charts.
struct Figures: View {
    let days: [DayStat]
    let target: Double

    var body: some View {
        let worked = days.filter { $0.total > 0 || $0.start != nil }
        let total = days.reduce(0) { $0 + $1.total }
        let spans = days.compactMap(\.span)
        let starts = days.compactMap { $0.start?.hoursIntoDay }
        let ends = days.compactMap { $0.end?.hoursIntoDay }
        let spanTotal = spans.reduce(0, +)
        let trackedInSpanDays = days.filter { $0.span != nil }.reduce(0) { $0 + $1.total }

        HStack(alignment: .top, spacing: 0) {
            figure(Fmt.hmm(total), "tracked", detail: worked.isEmpty ? nil : "\(Fmt.dur(total / Double(worked.count))) per work day")
            divider
            figure("\(worked.count)", worked.count == 1 ? "day worked" : "days worked",
                   detail: "target \(Fmt.dur(target * 3600 * Double(worked.count)))")
            divider
            figure(spans.isEmpty ? "–" : Fmt.hmm(spanTotal / Double(spans.count)), "average day at work")
            divider
            figure(starts.isEmpty ? "–" : Fmt.clockHour(starts.reduce(0, +) / Double(starts.count)), "average start", amber: true)
            divider
            figure(ends.isEmpty ? "–" : Fmt.clockHour(ends.reduce(0, +) / Double(ends.count)), "average end", amber: true)
            divider
            figure(spanTotal > 0 ? "\(Int((min(1, trackedInSpanDays / spanTotal) * 100).rounded()))%" : "–", "of the work day allocated")
        }
        .padding(.vertical, 4)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 52).padding(.horizontal, 20)
    }

    private func figure(_ value: String, _ label: String, detail: String? = nil, amber: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .light).width(.condensed).monospacedDigit())
                .foregroundStyle(amber ? Theme.molte : Theme.ink)
            Text(label).font(.callout).foregroundStyle(Theme.inkSoft)
            if let detail { Text(detail).font(.caption).foregroundStyle(Theme.inkSoft) }
        }
        .fixedSize()
    }
}

struct ProjectTable: View {
    @Environment(Store.self) private var store
    let days: [DayStat]

    var body: some View {
        let per = days.reduce(into: [UUID: TimeInterval]()) { acc, d in
            for (k, v) in d.perProject { acc[k, default: 0] += v }
        }
        if per.isEmpty {
            Text("No projects tracked in this period.").foregroundStyle(Theme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Breakdown(tallies: store.tally(per), showShare: true)
        }
    }
}
