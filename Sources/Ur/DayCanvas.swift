import SwiftUI

/// The vertical 24-hour timeline. Drag on empty space to log time, drag blocks to move them,
/// drag their edges to resize, click an unallocated gap to assign it.
struct DayCanvas: View {
    @Environment(Store.self) private var store
    let day: Date

    @State private var draft: (start: Date, end: Date)?
    @State private var adjust: Adjust?

    struct Adjust {
        var id: UUID
        var start: Date
        var end: Date?
    }

    private let gutter: CGFloat = 58
    private var hourH: CGFloat { CGFloat(store.prefs.hourHeight) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            let now = ctx.date
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        hourGrid
                        GeometryReader { geo in
                            content(width: geo.size.width, now: now)
                        }
                    }
                    .frame(height: hourH * 24)
                    .padding(.vertical, 12)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: day) { scroll(proxy) }
            }
        }
        .background(Theme.canvas)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        let start = store.dayBounds(day)?.start ?? store.entries(on: day).first?.start
        var hour = start.map { Int($0.hoursIntoDay) } ?? 8
        if day.isToday { hour = min(hour, max(0, Int(Date().hoursIntoDay) - 4)) }
        let target = max(0, hour - 1)
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, gutter)
                    Rectangle().fill(Theme.line.opacity(0.45)).frame(height: 1)
                        .padding(.leading, gutter)
                        .offset(y: hourH / 2)
                    Text(String(format: "%02d:00", h))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkSoft)
                        .frame(width: gutter - 12, alignment: .trailing)
                        .offset(y: -6)
                }
                .frame(height: hourH, alignment: .top)
                .id(h)
            }
        }
    }

    private func y(_ d: Date) -> CGFloat {
        CGFloat(d.timeIntervalSince(day.startOfDay) / 3600) * hourH
    }

    private func date(atY y: CGFloat) -> Date {
        let t = day.startOfDay.addingTimeInterval(Double(y / hourH) * 3600).snapped(to: store.prefs.snapMinutes)
        return min(max(t, day.startOfDay), day.startOfDay.adding(days: 1))
    }

    @ViewBuilder
    private func content(width: CGFloat, now: Date) -> some View {
        let x0 = gutter + 6
        let w = max(40, width - x0 - 14)
        let entries = store.entries(on: day, now: now)
        let bounds = store.dayBounds(day, now: now)
        let workday = store.workday(day)

        ZStack(alignment: .topLeading) {
            // Empty canvas: drag to create, click to deselect.
            Color.clear
                .contentShape(Rectangle())
                .gesture(createGesture)
                .onTapGesture { store.selectedEntryID = nil }

            // Shade outside the work day.
            if let b = bounds {
                Rectangle().fill(Theme.line.opacity(0.2))
                    .frame(width: w + 8, height: max(0, y(b.start)))
                    .offset(x: x0 - 4)
                    .allowsHitTesting(false)
                if workday?.end != nil {
                    Rectangle().fill(Theme.line.opacity(0.2))
                        .frame(width: w + 8, height: max(0, hourH * 24 - y(b.end)))
                        .offset(x: x0 - 4, y: y(b.end))
                        .allowsHitTesting(false)
                }
            }

            ForEach(store.gaps(day, now: now), id: \.start) { g in
                GapBlock(start: g.start, end: g.end)
                    .frame(width: w, height: max(4, y(g.end) - y(g.start) - 2))
                    .offset(x: x0, y: y(g.start) + 1)
                    .gesture(createGesture)
            }

            if let s = workday?.start, s.startOfDay == day.startOfDay {
                bookendLine(s, at: y(s), width: w, x0: x0)
            }
            if let e = workday?.end, e.startOfDay == day.startOfDay {
                bookendLine(e, at: y(e), width: w, x0: x0)
            }

            ForEach(entries) { e in
                let a = adjust?.id == e.id ? adjust : nil
                let s = max(a?.start ?? e.start, day.startOfDay)
                let endDate = a.map { $0.end ?? now } ?? e.effectiveEnd(now)
                let end = min(endDate, day.startOfDay.adding(days: 1))
                EntryBlock(entry: e, start: a?.start ?? e.start, end: endDate, now: now,
                           selected: store.selectedEntryID == e.id)
                    .frame(width: w, height: max(14, y(end) - y(s) - 2))
                    .overlay(alignment: .top) { handle(e, top: true) }
                    .overlay(alignment: .bottom) { if !e.isRunning { handle(e, top: false) } }
                    .offset(x: x0, y: y(s) + 1)
                    .gesture(moveGesture(e))
            }

            if day.isToday {
                nowLine(now, width: w, x0: x0)
            }

            if let d = draft {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.gran.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.gran, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                    .overlay(alignment: .topLeading) {
                        Text("\(Fmt.range(d.start, d.end))   \(Fmt.dur(d.end.timeIntervalSince(d.start)))")
                            .font(Theme.mono)
                            .foregroundStyle(Theme.gran)
                            .padding(6)
                    }
                    .frame(width: w, height: max(2, y(d.end) - y(d.start)))
                    .offset(x: x0, y: y(d.start))
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "canvas")
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("canvas"))
            .onChanged { v in
                let a = date(atY: v.startLocation.y), b = date(atY: v.location.y)
                draft = (min(a, b), max(a, b))
            }
            .onEnded { _ in
                if let d = draft, d.end.timeIntervalSince(d.start) >= 60 {
                    store.newEntry(start: d.start, end: d.end)
                }
                draft = nil
            }
    }

    private func delta(_ dy: CGFloat) -> TimeInterval { Double(dy / hourH) * 3600 }

    private func moveGesture(_ e: Entry) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { v in
                store.selectedEntryID = e.id
                let s = e.start.addingTimeInterval(delta(v.translation.height)).snapped(to: store.prefs.snapMinutes)
                if e.isRunning {
                    adjust = Adjust(id: e.id, start: min(s, Date()), end: nil)
                } else {
                    adjust = Adjust(id: e.id, start: s, end: e.end.map { $0.addingTimeInterval(s.timeIntervalSince(e.start)) })
                }
            }
            .onEnded { _ in commit() }
    }

    private func handle(_ e: Entry, top: Bool) -> some View {
        Color.clear
            .frame(height: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        store.selectedEntryID = e.id
                        let d = delta(v.translation.height)
                        let snap = store.prefs.snapMinutes
                        if top {
                            let limit = e.effectiveEnd().addingTimeInterval(-Double(snap * 60))
                            adjust = Adjust(id: e.id, start: min(e.start.addingTimeInterval(d).snapped(to: snap), limit), end: e.end)
                        } else if let end = e.end {
                            let limit = e.start.addingTimeInterval(Double(snap * 60))
                            adjust = Adjust(id: e.id, start: e.start, end: max(end.addingTimeInterval(d).snapped(to: snap), limit))
                        }
                    }
                    .onEnded { _ in commit() }
            )
    }

    private func commit() {
        if let a = adjust { store.setTimes(a.id, start: a.start, end: a.end) }
        adjust = nil
    }

    /// Amber rule across the timeline, with the time in the gutter so it never collides with blocks.
    private func bookendLine(_ t: Date, at yy: CGFloat, width: CGFloat, x0: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(Fmt.time(t))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.molte)
                .padding(.trailing, 4)
                .frame(width: x0 - 4, alignment: .trailing)
                .padding(.vertical, 4)
                .background(Theme.canvas)
            Rectangle().fill(Theme.molte).frame(width: width + 8, height: 2)
        }
        .offset(y: yy - 10)
        .frame(height: 20)
        .help(t == store.workday(day)?.start ? "Day started" : "Day ended")
    }

    private func nowLine(_ now: Date, width: CGFloat, x0: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(Fmt.time(now))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.gran)
                .padding(.trailing, 4)
                .frame(width: x0 - 4, alignment: .trailing)
                .padding(.vertical, 4)
                .background(Theme.canvas)
            Circle().fill(Theme.gran).frame(width: 7, height: 7)
            Rectangle().fill(Theme.gran).frame(width: width + 2, height: 1)
        }
        .offset(y: y(now) - 10)
        .frame(height: 20)
        .allowsHitTesting(false)
    }
}

struct EntryBlock: View {
    @Environment(Store.self) private var store
    let entry: Entry
    let start: Date
    let end: Date
    let now: Date
    let selected: Bool

    var body: some View {
        let color = store.color(entry.projectID)
        let planned = start > now
        let duration = end.timeIntervalSince(start)
        let compact = duration < 40 * 60

        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.name(entry.projectID))
                        .font(.system(size: 12, weight: .semibold))
                    if compact {
                        Text(entry.note).font(.system(size: 11)).foregroundStyle(Theme.inkSoft)
                    }
                    Spacer(minLength: 4)
                    Text(timeLabel(planned: planned, duration: duration))
                        .font(Theme.mono)
                        .foregroundStyle(entry.isRunning ? Theme.gran : Theme.inkSoft)
                }
                if !compact && !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(3)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 1 : 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .leading : .topLeading)
        }
        .foregroundStyle(Theme.ink)
        .background(color.opacity(planned ? 0.07 : 0.17))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            if planned {
                RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 5).strokeBorder(color, lineWidth: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.edit(entry.id) }
        .onTapGesture { store.selectedEntryID = entry.id }
        .contextMenu { EntryMenu(entry: entry) }
        .help(entry.note.isEmpty ? store.name(entry.projectID) : "\(store.name(entry.projectID)): \(entry.note)")
    }

    private func timeLabel(planned: Bool, duration: TimeInterval) -> String {
        let span = entry.isRunning ? "\(Fmt.time(start))–now" : Fmt.range(start, end)
        return "\(span)   \(Fmt.dur(duration))\(planned ? "  planned" : "")"
    }
}

struct EntryMenu: View {
    @Environment(Store.self) private var store
    let entry: Entry

    var body: some View {
        Button("Edit…") { store.edit(entry.id) }
        Menu("Change project") {
            ForEach(store.activeProjects) { p in
                Button(p.name) { store.setProject(entry.id, p.id) }
            }
        }
        if !entry.isRunning {
            Button("Continue now") { store.start(entry.projectID, note: entry.note) }
        } else {
            Button("Stop") { store.stop() }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(entry.id) }
    }
}

struct GapBlock: View {
    @Environment(Store.self) private var store
    let start: Date
    let end: Date
    @State private var hover = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Theme.inkSoft.opacity(hover ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.raised.opacity(0.7) : .clear))
            .overlay(alignment: .leading) {
                if end.timeIntervalSince(start) >= 15 * 60 {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("\(Fmt.dur(end.timeIntervalSince(start))) unallocated")
                        if hover { Text("Click to assign").foregroundStyle(Theme.inkSoft.opacity(0.8)) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.horizontal, 10)
                }
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { store.newEntry(start: start, end: end) }
    }
}
