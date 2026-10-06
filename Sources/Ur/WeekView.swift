import SwiftUI

struct WeekView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let start = store.selectedDay.startOfWeek
        let days = (0..<7).map { start.adding(days: $0) }
        let end = start.adding(days: 7)

        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let stats = store.dayStats(from: start, to: end, now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    WeekColumns(days: days, stats: stats, now: now)
                    Timesheet(days: days, stats: stats)
                }
                .padding(28)
            }
        }
        .navigationTitle("Week \(start.weekNumber)")
        .navigationSubtitle("\(Fmt.dayMonth.string(from: start)) – \(Fmt.dayMonth.string(from: end.adding(days: -1)))")
        .toolbar { DayToolbar() }
    }
}

/// Seven compact day timelines, with each day's start and end drawn in amber.
struct WeekColumns: View {
    @Environment(Store.self) private var store
    let days: [Date]
    let stats: [DayStat]
    let now: Date

    var body: some View {
        // Hour range covering the week's activity, at least 07–17.
        let entries = store.entries(from: days[0], to: days[6].adding(days: 1), now: now)
        let hours = entries.flatMap { [$0.start.hoursIntoDay, $0.effectiveEnd(now).hoursIntoDay] }
            + stats.compactMap { $0.start?.hoursIntoDay } + stats.compactMap { $0.end?.hoursIntoDay }
        let lo = max(0, floor(min(hours.min() ?? 7, 7)))
        let hi = min(24, ceil(max(hours.max() ?? 17, 17)))
        let height: CGFloat = 420
        let scale = height / CGFloat(hi - lo)

        HStack(alignment: .top, spacing: 0) {
            // Hour labels
            VStack(alignment: .trailing, spacing: 0) {
                Color.clear.frame(height: 58)
                ZStack(alignment: .topTrailing) {
                    ForEach(Int(lo)...Int(hi), id: \.self) { h in
                        if (h - Int(lo)) % 2 == 0 {
                            Text(String(format: "%02d", h))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Theme.inkSoft)
                                .offset(y: CGFloat(Double(h) - lo) * scale - 6)
                        }
                    }
                }
                .frame(width: 26, height: height, alignment: .topTrailing)
            }
            .padding(.trailing, 6)

            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                let s = stats[i]
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        store.selectedDay = day
                        store.pane = .today
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(Fmt.weekday.string(from: day))
                                    .font(.callout.weight(day.isToday ? .bold : .medium))
                                Text(Fmt.dayMonth.string(from: day)).font(.caption).foregroundStyle(Theme.inkSoft)
                            }
                            Text(s.total > 0 ? Fmt.dur(s.total) : " ")
                                .font(Theme.clock(22))
                                .foregroundStyle(day.isToday ? Theme.gran : Theme.ink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(height: 50)

                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 6).fill(day.isToday ? Theme.surface : Theme.surface.opacity(0.55))
                        ForEach(Int(lo)...Int(hi), id: \.self) { h in
                            Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1)
                                .offset(y: CGFloat(Double(h) - lo) * scale)
                        }
                        ForEach(store.entries(on: day, now: now)) { e in
                            let a = max(e.start.hoursIntoDay, lo)
                            let b = min(e.effectiveEnd(now).startOfDay > day ? 24 : e.effectiveEnd(now).hoursIntoDay, hi)
                            if b > a {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(store.color(e.projectID).opacity(e.start > now ? 0.35 : 0.85))
                                    .frame(height: max(2, CGFloat(b - a) * scale - 1))
                                    .padding(.horizontal, 5)
                                    .offset(y: CGFloat(a - lo) * scale)
                                    .help("\(store.name(e.projectID))  \(Fmt.range(e.start, e.effectiveEnd(now)))")
                            }
                        }
                        if let st = s.start { amber(st.hoursIntoDay, lo: lo, scale: scale) }
                        if let en = s.end { amber(en.hoursIntoDay, lo: lo, scale: scale) }
                    }
                    .frame(height: height, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text(s.start.map { "\(Fmt.time($0))–\(s.end.map { Fmt.time($0) } ?? "")" } ?? " ")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.molte)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func amber(_ h: Double, lo: Double, scale: CGFloat) -> some View {
        Rectangle().fill(Theme.molte).frame(height: 2)
            .offset(y: CGFloat(h - lo) * scale - 1)
    }
}

/// Hours per project per day, like a classic timesheet.
struct Timesheet: View {
    @Environment(Store.self) private var store
    let days: [Date]
    let stats: [DayStat]

    var body: some View {
        let ids = store.data.projects.map(\.id).filter { id in stats.contains { ($0.perProject[id] ?? 0) > 0 } }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timesheet").font(.headline)
                Spacer()
                Text("Hours as h:mm").font(.caption).foregroundStyle(Theme.inkSoft)
            }
            Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(days, id: \.self) { d in
                        Text(Fmt.weekday.string(from: d)).foregroundStyle(Theme.inkSoft).frame(width: 64, alignment: .trailing)
                    }
                    Text("Total").foregroundStyle(Theme.inkSoft).frame(width: 76, alignment: .trailing)
                }
                .font(.caption.weight(.medium))
                .padding(.vertical, 6)

                Divider().gridCellUnsizedAxes(.horizontal)

                if ids.isEmpty {
                    GridRow {
                        Text("No time tracked this week.").foregroundStyle(Theme.inkSoft).gridCellColumns(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                }

                ForEach(ids, id: \.self) { id in
                    GridRow {
                        HStack(spacing: 8) {
                            Dot(color: store.color(id))
                            Text(store.name(id)).lineLimit(1)
                        }
                        .frame(minWidth: 160, alignment: .leading)
                        ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                            cell(s.perProject[id] ?? 0)
                        }
                        cell(stats.reduce(0) { $0 + ($1.perProject[id] ?? 0) }, bold: true).frame(width: 76, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal)
                }

                GridRow {
                    Text("Tracked").fontWeight(.semibold).gridColumnAlignment(.leading)
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, s in cell(s.total, bold: true) }
                    cell(stats.reduce(0) { $0 + $1.total }, bold: true).frame(width: 76, alignment: .trailing)
                }
                .padding(.vertical, 6)
                GridRow {
                    Text("At work").foregroundStyle(Theme.inkSoft)
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                        cell(s.span ?? 0).foregroundStyle(Theme.molte)
                    }
                    cell(stats.reduce(0) { $0 + ($1.span ?? 0) }).foregroundStyle(Theme.molte).frame(width: 76, alignment: .trailing)
                }
                .padding(.vertical, 6)
            }
            .font(.callout)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        }
    }

    private func cell(_ t: TimeInterval, bold: Bool = false) -> some View {
        Text(t >= 60 ? Fmt.hmm(t) : "·")
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(t >= 60 ? Theme.ink : Theme.line)
            .frame(width: 64, alignment: .trailing)
    }
}
