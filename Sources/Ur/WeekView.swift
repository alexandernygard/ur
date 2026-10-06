import SwiftUI

/// The week as a timesheet: hours per project per day. Editing happens in the calendar.
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
                Timesheet(days: days, stats: stats)
                .padding(28)
            }
        }
        .navigationTitle("Week \(start.weekNumber)")
        .navigationSubtitle("\(Fmt.dayMonth.string(from: start)) – \(Fmt.dayMonth.string(from: end.adding(days: -1)))")
        .toolbar { DayToolbar() }
    }
}

/// Hours per project per day, like a classic timesheet.
struct Timesheet: View {
    @Environment(Store.self) private var store
    let days: [Date]
    let stats: [DayStat]
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        let week = stats.reduce(into: [UUID: TimeInterval]()) { acc, d in
            for (k, v) in d.perProject { acc[k, default: 0] += v }
        }
        let tallies = store.tally(week, byTotal: false)
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
                        Button {
                            store.selectedDay = d
                            store.pane = .today
                        } label: {
                            Text(Fmt.weekday.string(from: d))
                                .foregroundStyle(d.isToday ? Theme.gran : Theme.inkSoft)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(Fmt.dayTitle.string(from: d)) in the calendar")
                    }
                    Text("Total").foregroundStyle(Theme.inkSoft).frame(width: 76, alignment: .trailing)
                }
                .font(.caption.weight(.medium))
                .padding(.vertical, 6)

                Divider().gridCellUnsizedAxes(.horizontal)

                if tallies.isEmpty {
                    GridRow {
                        Text("No time tracked this week.").foregroundStyle(Theme.inkSoft).gridCellColumns(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                }

                ForEach(tallies) { t in
                    if let g = t.group {
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
                                .frame(minWidth: 160, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(open ? "Hide the projects in \(g.name)" : "Show the projects in \(g.name)")
                            ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                                cell(ids.reduce(0) { $0 + (s.perProject[$1] ?? 0) }, bold: true)
                            }
                            cell(t.total, bold: true).frame(width: 76, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                        Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal)
                        if open {
                            ForEach(t.projects) { p in projectRow(p.id, indent: true) }
                        }
                    } else {
                        projectRow(t.id, indent: false)
                    }
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

    @ViewBuilder
    private func projectRow(_ id: UUID, indent: Bool) -> some View {
        GridRow {
            HStack(spacing: 8) {
                Dot(color: store.color(id))
                Text(store.name(id)).lineLimit(1)
            }
            .padding(.leading, indent ? 16 : 0)
            .frame(minWidth: 160, alignment: .leading)
            ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                cell(s.perProject[id] ?? 0)
            }
            cell(stats.reduce(0) { $0 + ($1.perProject[id] ?? 0) }, bold: !indent).frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 6)
        Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal)
    }

    private func cell(_ t: TimeInterval, bold: Bool = false) -> some View {
        Text(t >= 60 ? Fmt.hmm(t) : "·")
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(t >= 60 ? Theme.ink : Theme.line)
            .frame(width: 64, alignment: .trailing)
    }
}
