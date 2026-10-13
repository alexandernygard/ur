import SwiftUI

/// Which projects the Stats page counts.
enum StatsScope: Hashable {
    case all
    case group(UUID)
    case ungrouped
    case project(UUID)
}

/// A year of activity, like GitHub's contribution graph: one cell per day, darker for more
/// hours. Below it, one strip per project with a cell per week, in the project's colour, so
/// you can see when each project was busy and when it went quiet.
struct ActivityView: View {
    @Environment(Store.self) private var store
    /// The last day shown; the graph covers the 53 weeks up to it.
    let through: Date
    let now: Date
    let includes: (UUID) -> Bool
    /// The colour of the day grid: the project's own when only one is shown.
    let tint: Color

    @State private var width: CGFloat = 900
    @State private var hover: Hover?

    private enum Hover: Equatable {
        case day(Date)
        case week(UUID, Date)
    }

    // Layout
    private let weeks = 53
    private let gap: CGFloat = 3
    private let labelW: CGFloat = 132
    private let totalW: CGFloat = 64
    private let monthH: CGFloat = 18
    private let stripGap: CGFloat = 22
    private let stripH: CGFloat = 14

    private var cell: CGFloat {
        let fit = (width - labelW - totalW) / CGFloat(weeks) - gap
        return min(16, max(7, fit.rounded(.down)))
    }
    private var pitch: CGFloat { cell + gap }

    var body: some View {
        let model = Model(store: store, through: through, now: now, weeks: weeks, includes: includes)
        let height = gridBottom + (model.projects.isEmpty ? 0 : stripGap + CGFloat(model.projects.count) * (stripH + 6))

        VStack(alignment: .leading, spacing: 10) {
            Canvas { ctx, _ in draw(model, in: &ctx) }
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { width = g.size.width }
                        .onChange(of: g.size.width) { width = g.size.width }
                })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let h = hit(p, model)
                        if h != hover { hover = h }
                    case .ended:
                        hover = nil
                    }
                }
                .onTapGesture { p in
                    guard case .day(let d) = hit(p, model) else { return }
                    store.selectedDay = d
                    store.pane = .today
                }
                .overlay(alignment: .topLeading) {
                    if let hover, let at = anchor(hover, model) {
                        tooltip(hover, model)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                // Keep it inside the view, centred over the cell where there's room.
                                let x = min(max(at.x - d.width / 2, 0), width - d.width)
                                return -x
                            }
                            .alignmentGuide(.top) { d in -(at.y - d.height - 6) }
                            .allowsHitTesting(false)
                    }
                }
            legend(model)
        }
    }

    // MARK: Data

    struct Model {
        var weekStarts: [Date] = []
        var perDay: [Date: [UUID: TimeInterval]] = [:]
        var perWeek: [UUID: [Date: TimeInterval]] = [:]
        var projects: [(id: UUID, total: TimeInterval)] = []
        var maxDay: TimeInterval = 0
        var maxWeek: TimeInterval = 0
        var total: TimeInterval = 0
        var daysWithTime = 0
        var last: Date

        init(store: Store, through: Date, now: Date, weeks: Int, includes: (UUID) -> Bool) {
            last = through.startOfDay
            let lastWeek = cal.dateInterval(of: .weekOfYear, for: last)!.start
            let first = lastWeek.adding(days: -7 * (weeks - 1))
            weekStarts = (0..<weeks).map { first.adding(days: 7 * $0) }
            let end = min(last.adding(days: 1), now.startOfDay.adding(days: 1))
            guard first < end else { return }
            var totals: [UUID: TimeInterval] = [:]
            for d in store.dayStats(from: first, to: end, now: now) {
                let per = d.perProject.filter { includes($0.key) }
                guard !per.isEmpty else { continue }
                perDay[d.day] = per
                let sum = per.values.reduce(0, +)
                maxDay = max(maxDay, sum)
                total += sum
                daysWithTime += 1
                let w = cal.dateInterval(of: .weekOfYear, for: d.day)!.start
                for (k, v) in per {
                    perWeek[k, default: [:]][w, default: 0] += v
                    totals[k, default: 0] += v
                }
            }
            maxWeek = perWeek.values.flatMap(\.values).max() ?? 0
            projects = totals.filter { $0.value >= 60 }
                .sorted { $0.value > $1.value }
                .map { (id: $0.key, total: $0.value) }
        }

        func day(_ week: Int, _ row: Int) -> Date? {
            guard weekStarts.indices.contains(week), (0..<7).contains(row) else { return nil }
            return weekStarts[week].adding(days: row)
        }
    }

    /// Four steps, like GitHub, measured against the busiest cell so the scale fits the data.
    private func level(_ value: TimeInterval, max: TimeInterval) -> Int {
        guard value >= 60, max > 0 else { return 0 }
        return Swift.min(4, Swift.max(1, Int((value / max * 4).rounded(.up))))
    }

    private static let opacities: [Double] = [0, 0.25, 0.45, 0.7, 1]

    private func fill(_ level: Int, _ color: Color) -> Color {
        level == 0 ? Theme.line.opacity(0.6) : color.opacity(Self.opacities[level])
    }

    // MARK: Geometry

    private var gridTop: CGFloat { monthH }
    private var gridBottom: CGFloat { gridTop + 7 * pitch - gap }
    private func stripY(_ i: Int) -> CGFloat { gridBottom + stripGap + CGFloat(i) * (stripH + 6) }
    private func colX(_ w: Int) -> CGFloat { labelW + CGFloat(w) * pitch }

    private func hit(_ p: CGPoint, _ m: Model) -> Hover? {
        let w = Int(floor((p.x - labelW) / pitch))
        guard m.weekStarts.indices.contains(w), p.x - colX(w) <= cell else { return nil }
        if p.y >= gridTop && p.y < gridBottom {
            let r = Int(floor((p.y - gridTop) / pitch))
            guard p.y - gridTop - CGFloat(r) * pitch <= cell, let d = m.day(w, r), d <= m.last, d <= now else { return nil }
            return .day(d)
        }
        for (i, proj) in m.projects.enumerated() where p.y >= stripY(i) && p.y < stripY(i) + stripH {
            guard m.weekStarts[w] <= now else { return nil }
            return .week(proj.id, m.weekStarts[w])
        }
        return nil
    }

    /// The top centre of the hovered cell, where the tooltip points.
    private func anchor(_ h: Hover, _ m: Model) -> CGPoint? {
        switch h {
        case .day(let d):
            guard let w = m.weekStarts.lastIndex(where: { $0 <= d }) else { return nil }
            let r = cal.dateComponents([.day], from: m.weekStarts[w], to: d).day ?? 0
            return CGPoint(x: colX(w) + cell / 2, y: gridTop + CGFloat(r) * pitch)
        case .week(let id, let ws):
            guard let w = m.weekStarts.firstIndex(of: ws), let i = m.projects.firstIndex(where: { $0.id == id }) else { return nil }
            return CGPoint(x: colX(w) + cell / 2, y: stripY(i))
        }
    }

    // MARK: Drawing

    private func draw(_ m: Model, in ctx: inout GraphicsContext) {
        let soft = Theme.inkSoft
        let label = Font.system(size: 10)

        // Month names above the first week that starts in each month.
        var lastMonth = -1
        var lastLabelX: CGFloat = -100
        for (w, ws) in m.weekStarts.enumerated() {
            let month = cal.component(.month, from: ws.adding(days: 6))
            if month != lastMonth {
                lastMonth = month
                let x = colX(w)
                if x - lastLabelX > 28 {
                    ctx.draw(Text(Fmt.month.string(from: ws.adding(days: 6))).font(label).foregroundStyle(soft),
                             at: CGPoint(x: x, y: 0), anchor: .topLeading)
                    lastLabelX = x
                }
            }
        }

        // Weekday names on alternate rows, like GitHub.
        for r in [0, 2, 4] {
            guard let d = m.day(0, r) else { continue }
            ctx.draw(Text(Fmt.weekday.string(from: d)).font(label).foregroundStyle(soft),
                     at: CGPoint(x: labelW - 8, y: gridTop + CGFloat(r) * pitch + cell / 2), anchor: .trailing)
        }

        let radius = Swift.max(2, cell / 5)
        for w in m.weekStarts.indices {
            for r in 0..<7 {
                guard let d = m.day(w, r), d <= m.last, d <= now else { continue }
                let v = m.perDay[d]?.values.reduce(0, +) ?? 0
                let rect = CGRect(x: colX(w), y: gridTop + CGFloat(r) * pitch, width: cell, height: cell)
                ctx.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(fill(level(v, max: m.maxDay), tint)))
                if hover == .day(d) {
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: radius + 1), with: .color(Theme.ink), lineWidth: 1.5)
                }
            }
        }
        ctx.draw(Text(Fmt.dur(m.total)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink),
                 at: CGPoint(x: width, y: gridTop), anchor: .topTrailing)
        ctx.draw(Text("\(m.daysWithTime) days").font(label).foregroundStyle(soft),
                 at: CGPoint(x: width, y: gridTop + 16), anchor: .topTrailing)

        // One strip per project, a cell per week.
        for (i, p) in m.projects.enumerated() {
            let y = stripY(i)
            let color = store.color(p.id)
            ctx.fill(Path(ellipseIn: CGRect(x: 0, y: y + stripH / 2 - 3.5, width: 7, height: 7)), with: .color(color))
            ctx.draw(Text(store.name(p.id)).font(.system(size: 11)).foregroundStyle(Theme.ink),
                     in: CGRect(x: 13, y: y - 1, width: labelW - 22, height: stripH + 2))
            let weeks = m.perWeek[p.id] ?? [:]
            for (w, ws) in m.weekStarts.enumerated() where ws <= now && ws <= m.last {
                let rect = CGRect(x: colX(w), y: y, width: cell, height: stripH)
                ctx.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(fill(level(weeks[ws] ?? 0, max: m.maxWeek), color)))
                if hover == .week(p.id, ws) {
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: radius + 1), with: .color(Theme.ink), lineWidth: 1.5)
                }
            }
            ctx.draw(Text(Fmt.dur(p.total)).font(.system(size: 11).monospacedDigit()).foregroundStyle(soft),
                     at: CGPoint(x: width, y: y + stripH / 2), anchor: .trailing)
        }
    }

    private func legend(_ m: Model) -> some View {
        HStack(spacing: 4) {
            Text("Less")
            ForEach(0..<5, id: \.self) { l in
                RoundedRectangle(cornerRadius: 2).fill(fill(l, tint)).frame(width: 10, height: 10)
            }
            Text("More")
            if m.maxDay > 0 {
                Text("Darkest day \(Fmt.dur(m.maxDay))\(m.maxWeek > 0 && !m.projects.isEmpty ? ", darkest week \(Fmt.dur(m.maxWeek))" : ""). Click a day to open it.")
                    .padding(.leading, 10)
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.inkSoft)
        .padding(.leading, labelW)
    }

    // MARK: Tooltip

    @ViewBuilder
    private func tooltip(_ h: Hover, _ m: Model) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch h {
            case .day(let d):
                let per = m.perDay[d] ?? [:]
                Text(Fmt.dayTitle.string(from: d)).font(.caption.weight(.semibold))
                if per.isEmpty {
                    Text("Nothing tracked").font(.caption).foregroundStyle(Theme.inkSoft)
                }
                ForEach(per.sorted { $0.value > $1.value }, id: \.key) { k, v in
                    row(store.color(k), store.name(k), v)
                }
                if per.count > 1 {
                    Divider()
                    row(nil, d.isToday && store.running != nil ? "Total so far" : "Total", per.values.reduce(0, +)).fontWeight(.semibold)
                }
            case .week(let id, let ws):
                Text("Week \(ws.weekNumber), \(Fmt.dayMonth.string(from: ws)) – \(Fmt.dayMonth.string(from: ws.adding(days: 6)))")
                    .font(.caption.weight(.semibold))
                row(store.color(id), store.name(id), m.perWeek[id]?[ws] ?? 0)
            }
        }
        .padding(8)
        .frame(minWidth: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
    }

    private func row(_ color: Color?, _ name: String, _ v: TimeInterval) -> some View {
        HStack(spacing: 6) {
            if let color { Dot(color: color, size: 6) }
            Text(name)
            Spacer(minLength: 12)
            Text(Fmt.dur(v)).monospacedDigit()
        }
        .font(.caption)
    }
}
