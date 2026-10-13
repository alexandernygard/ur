import SwiftUI

/// The calendar: one or more days side by side on a 24-hour axis.
/// - Drag on empty space to log time, or click an unallocated gap to assign it.
/// - Drag a block to move it (sideways to another day), drag its edges to resize.
/// - Drag the amber edge of the work day to change when it started or ended.
/// - Right-click to start or end the day at that time.
/// - Pinch or ⌘+ / ⌘− to zoom.
/// Dragged times snap to other blocks, the day's start and end, and now; hold ⌥ to place freely.
struct CalendarCanvas: View {
    @Environment(Store.self) private var store
    let days: [Date]

    @State private var draft: Draft?
    @State private var adjust: Adjust?
    @State private var bound: Bound?
    @State private var pointer: Pointer?
    /// The time a drag has snapped to, drawn as a guide line.
    @State private var guide: Date?
    @State private var scroller = ScrollerRef()
    /// Hour height when a pinch began, and where in the viewport it is centred.
    @State private var pinch: (height: Double, y: CGFloat)?

    struct Draft { var col: Int; var start: Date; var end: Date }
    struct Adjust { var id: UUID; var start: Date; var end: Date? }
    struct Bound { var day: Date; var isStart: Bool; var time: Date }
    struct Pointer: Equatable { var col: Int; var time: Date }

    /// A piece of an entry inside one day's column. Entries past midnight show in both columns.
    struct Segment: Identifiable {
        var entry: Entry
        var col: Int
        var start: Date
        var end: Date
        var isHead: Bool
        var isTail: Bool
        var id: String { "\(entry.id)-\(col)" }
    }

    private let gutter: CGFloat = 58
    private let pad: CGFloat = 12
    private var hourH: CGFloat { CGFloat(store.prefs.hourHeight) }
    private var multi: Bool { days.count > 1 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            let now = ctx.date
            GeometryReader { geo in
                let colW = max(60, (geo.size.width - gutter - 10) / CGFloat(days.count))
                VStack(spacing: 0) {
                    if multi {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: gutter)
                            ForEach(days, id: \.self) { d in
                                ColumnHeader(day: d, now: now).frame(width: colW)
                            }
                        }
                        .frame(height: 52)
                        Divider()
                    }
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            ZStack(alignment: .topLeading) {
                                hourGrid
                                content(colW: colW, now: now)
                            }
                            .frame(height: hourH * 24)
                            .padding(.vertical, pad)
                            .background(ScrollerFinder(ref: scroller))
                        }
                        .simultaneousGesture(pinchGesture)
                        .onAppear { scroll(proxy) }
                        .onChange(of: days) { scroll(proxy) }
                        .onChange(of: store.prefs.hourHeight) { old, new in
                            keepAnchored(from: old, to: new)
                        }
                    }
                }
            }
        }
        .background(Theme.canvas)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        let starts = days.compactMap { store.dayBounds($0)?.start ?? store.entries(on: $0).first?.start }
        var hour = starts.map { Int($0.hoursIntoDay) }.min() ?? 8
        if days.contains(where: \.isToday) { hour = min(hour, max(0, Int(Date().hoursIntoDay) - 4)) }
        let target = max(0, hour - 1)
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, gutter)
                    if hourH >= 36 {
                        Rectangle().fill(Theme.line.opacity(0.45)).frame(height: 1)
                            .padding(.leading, gutter)
                            .offset(y: hourH / 2)
                    }
                    if hourH >= 150 {
                        ForEach([1, 3], id: \.self) { q in
                            Rectangle().fill(Theme.line.opacity(0.22)).frame(height: 1)
                                .padding(.leading, gutter)
                                .offset(y: hourH * CGFloat(q) / 4)
                        }
                    }
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

    // MARK: Geometry

    private func y(_ d: Date, in day: Date) -> CGFloat {
        CGFloat(d.timeIntervalSince(day.startOfDay) / 3600) * hourH
    }

    private func rawDate(atY y: CGFloat, in day: Date) -> Date {
        day.startOfDay.addingTimeInterval(Double(y / hourH) * 3600)
    }

    private func date(atY y: CGFloat, in day: Date) -> Date {
        clamp(rawDate(atY: y, in: day).snapped(to: store.prefs.snapMinutes), to: day)
    }

    private func clamp(_ t: Date, to day: Date) -> Date {
        let s = day.startOfDay
        return min(max(t, s), s.adding(days: 1))
    }

    private func colX(_ col: Int, _ colW: CGFloat) -> CGFloat { gutter + CGFloat(col) * colW + (multi ? 3 : 6) }
    private func blockW(_ colW: CGFloat) -> CGFloat { max(30, colW - (multi ? 6 : 10)) }

    private func column(atX x: CGFloat, _ colW: CGFloat) -> Int {
        min(max(0, Int(((x - gutter) / colW).rounded(.down))), days.count - 1)
    }

    private func delta(_ dy: CGFloat) -> TimeInterval { Double(dy / hourH) * 3600 }

    // MARK: Layers

    @ViewBuilder
    private func content(colW: CGFloat, now: Date) -> some View {
        let all = store.entries(from: days[0], to: days[days.count - 1].adding(days: 1), now: now)
        let w = blockW(colW)

        ZStack(alignment: .topLeading) {
            // Empty canvas per day: drag to create, click to select the day, right-click for the day menu.
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                background(i, day, colW: colW, now: now)
            }

            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                ForEach(store.gaps(day, now: now), id: \.start) { g in
                    GapBlock(start: g.start, end: g.end, compact: multi)
                        .frame(width: w, height: max(4, y(g.end, in: day) - y(g.start, in: day) - 2))
                        .offset(x: colX(i, colW), y: y(g.start, in: day) + 1)
                        .gesture(createGesture(i, day))
                }
            }

            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                bookends(i, day, colW: colW, now: now)
            }

            ForEach(segments(all, now: now)) { seg in
                let day = days[seg.col]
                EntryBlock(entry: seg.entry, start: seg.start, end: seg.end, now: now,
                           selected: store.selectedEntryID == seg.entry.id, narrow: multi)
                    .frame(width: w, height: max(14, y(seg.end, in: day) - y(seg.start, in: day) - 2))
                    .overlay(alignment: .top) { if seg.isHead { handle(seg.entry, top: true) } }
                    .overlay(alignment: .bottom) { if seg.isTail && !seg.entry.isRunning { handle(seg.entry, top: false) } }
                    .offset(x: colX(seg.col, colW), y: y(seg.start, in: day) + 1)
                    .gesture(moveGesture(seg.entry, colW: colW))
            }

            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                if day.isToday { nowLine(now, col: i, colW: colW) }
                if let g = guide, g >= day.startOfDay, g <= day.startOfDay.adding(days: 1) {
                    Rectangle()
                        .fill(Theme.gran)
                        .frame(width: blockW(colW) + 6, height: 1.5)
                        .offset(x: colX(i, colW) - 3, y: y(g, in: day) + 0.25)
                        .allowsHitTesting(false)
                }
            }

            if let d = draft {
                let day = days[d.col]
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.gran.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.gran, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                    .overlay(alignment: .topLeading) {
                        Text(multi ? Fmt.range(d.start, d.end) : "\(Fmt.range(d.start, d.end))   \(Fmt.dur(d.end.timeIntervalSince(d.start)))")
                            .font(Theme.mono)
                            .foregroundStyle(Theme.gran)
                            .padding(6)
                    }
                    .frame(width: w, height: max(2, y(d.end, in: day) - y(d.start, in: day)))
                    .offset(x: colX(d.col, colW), y: y(d.start, in: day))
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "calendar")
    }

    /// Entries as they should be drawn right now, including one being dragged.
    private func segments(_ all: [Entry], now: Date) -> [Segment] {
        var out: [Segment] = []
        for e in all {
            let a = adjust?.id == e.id ? adjust : nil
            let s = a?.start ?? e.start
            let end = a.map { $0.end ?? now } ?? e.effectiveEnd(now)
            for (i, day) in days.enumerated() {
                let ds = day.startOfDay, de = ds.adding(days: 1)
                guard s < de && end > ds else { continue }
                out.append(Segment(entry: e, col: i, start: max(s, ds), end: min(end, de),
                                   isHead: s >= ds, isTail: end <= de))
            }
        }
        return out
    }

    /// The day's hours as they should be drawn, including a bookend being dragged.
    private func hours(_ day: Date) -> (start: Date?, end: Date?) {
        let w = store.workday(day)
        var s = w?.start, e = w?.end
        if let b = bound, b.day == day.startOfDay {
            if b.isStart { s = b.time } else { e = b.time }
        }
        return (s, e)
    }

    private func background(_ i: Int, _ day: Date, colW: CGFloat, now: Date) -> some View {
        let h = hours(day)
        let inferred = store.dayBounds(day, now: now)?.start
        let selected = multi && store.selectedDay == day.startOfDay
        let x = gutter + CGFloat(i) * colW
        let total = hourH * 24
        let shadeTop = (h.start ?? inferred).map { y($0, in: day) } ?? 0
        let shadeBottom = h.end.map { y($0, in: day) } ?? total

        return ZStack(alignment: .topLeading) {
            Rectangle().fill(selected ? Theme.gran.opacity(0.04) : .clear)
            // Shade the hours outside the work day.
            Rectangle().fill(Theme.line.opacity(0.28)).frame(height: max(0, shadeTop))
            Rectangle().fill(Theme.line.opacity(0.28)).frame(height: max(0, total - shadeBottom))
                .offset(y: shadeBottom)
            if multi && i > 0 {
                Rectangle().fill(Theme.line).frame(width: 1)
            }
        }
        .frame(width: colW, height: total, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(createGesture(i, day))
        .onTapGesture {
            store.selectedEntryID = nil
            store.selectedDay = day.startOfDay
        }
        .onContinuousHover(coordinateSpace: .named("calendar")) { phase in
            if case .active(let p) = phase {
                let next = Pointer(col: i, time: date(atY: p.y, in: day))
                if pointer != next { pointer = next }
            }
        }
        .contextMenu { dayMenu(i, day) }
        .offset(x: x)
    }

    @ViewBuilder
    private func dayMenu(_ i: Int, _ day: Date) -> some View {
        let t = pointer?.col == i ? pointer!.time : day.at(hour: 9, minute: 0)
        let w = store.workday(day)
        let start = w?.start ?? store.dayBounds(day)?.start
        Button("Add Time at \(Fmt.time(t))") {
            store.selectedDay = day.startOfDay
            store.newEntry(start: t, end: min(t.addingTimeInterval(3600), day.startOfDay.adding(days: 1)))
        }
        Divider()
        Button("Start Day at \(Fmt.time(t))") {
            let end = w?.end.flatMap { $0 > t ? $0 : nil }
            store.setDayBounds(day, start: t, end: end)
        }
        if !(day.isToday && t > Date()) {
            Button("End Day at \(Fmt.time(t))") {
                if day.isToday, store.running != nil { store.stop(at: max(t, store.running!.start)) }
                store.setDayBounds(day, start: start.flatMap { $0 < t ? $0 : nil } ?? t, end: t)
            }
        }
        if w?.end != nil && day.isToday {
            Button("Resume Day") { store.setDayBounds(day, start: w?.start, end: nil) }
        }
        if w != nil {
            Button("Clear Start and End") { store.setDayBounds(day, start: nil, end: nil) }
        }
    }

    // MARK: Gestures

    private func createGesture(_ col: Int, _ day: Date) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("calendar"))
            .onChanged { v in
                let targets = snapTargets()
                let a = clamp(snap(rawDate(atY: v.startLocation.y, in: day), targets).time, to: day)
                let pulled = snap(rawDate(atY: v.location.y, in: day), targets)
                let b = clamp(pulled.time, to: day)
                draft = Draft(col: col, start: min(a, b), end: max(a, b))
                guide = pulled.magnet
            }
            .onEnded { _ in
                if let d = draft, d.end.timeIntervalSince(d.start) >= 60 {
                    store.selectedDay = day.startOfDay
                    store.newEntry(start: d.start, end: d.end)
                }
                draft = nil
                guide = nil
            }
    }

    private func moveGesture(_ e: Entry, colW: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("calendar"))
            .onChanged { v in
                store.selectedEntryID = e.id
                let days = multi && !e.isRunning
                    ? column(atX: v.location.x, colW) - column(atX: v.startLocation.x, colW) : 0
                let now = Date()
                let raw = e.start.addingTimeInterval(delta(v.translation.height)).adding(days: days)
                let length = e.effectiveEnd(now).timeIntervalSince(e.start)
                let targets = snapTargets(excluding: e.id)
                // Whichever edge is nearer to something worth lining up with wins.
                let head = magnet(raw, targets)
                let tail = e.isRunning ? nil : magnet(raw.addingTimeInterval(length), targets)
                let s: Date
                if let h = head, tail == nil || abs(h.timeIntervalSince(raw)) <= abs(tail!.timeIntervalSince(raw.addingTimeInterval(length))) {
                    s = h; guide = h
                } else if let t = tail {
                    s = t.addingTimeInterval(-length); guide = t
                } else {
                    s = grid(raw); guide = nil
                }
                if e.isRunning {
                    adjust = Adjust(id: e.id, start: min(s, Date()), end: nil)
                } else {
                    adjust = Adjust(id: e.id, start: s, end: e.end.map { $0.addingTimeInterval(s.timeIntervalSince(e.start)) })
                }
            }
            .onEnded { _ in commit() }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinch == nil { pinch = (store.prefs.hourHeight, v.startLocation.y) }
                store.setHourHeight(pinch!.height * v.magnification)
            }
            .onEnded { _ in pinch = nil }
    }

    private func handle(_ e: Entry, top: Bool) -> some View {
        Color.clear
            .frame(height: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("calendar"))
                    .onChanged { v in
                        store.selectedEntryID = e.id
                        let d = delta(v.translation.height)
                        let minimum = Double(store.prefs.snapMinutes * 60)
                        let targets = snapTargets(excluding: e.id)
                        if top {
                            let limit = e.effectiveEnd().addingTimeInterval(-minimum)
                            let pulled = snap(e.start.addingTimeInterval(d), targets)
                            adjust = Adjust(id: e.id, start: min(pulled.time, limit), end: e.end)
                            guide = pulled.magnet
                        } else if let end = e.end {
                            let limit = e.start.addingTimeInterval(minimum)
                            let pulled = snap(end.addingTimeInterval(d), targets)
                            adjust = Adjust(id: e.id, start: e.start, end: max(pulled.time, limit))
                            guide = pulled.magnet
                        }
                    }
                    .onEnded { _ in commit() }
            )
    }

    private func commit() {
        if let a = adjust {
            store.setTimes(a.id, start: a.start, end: a.end)
            if multi { store.selectedDay = a.start.startOfDay }
        }
        adjust = nil
        guide = nil
    }

    // MARK: Snapping

    /// Times worth lining up with: the edges of other blocks, each day's start and end, and now.
    private func snapTargets(excluding id: UUID? = nil, skipBoundsOf skipDay: Date? = nil) -> [Date] {
        let now = Date()
        var out = [now]
        for x in store.entries(from: days[0].adding(days: -1), to: days[days.count - 1].adding(days: 2), now: now) where x.id != id {
            out.append(x.start)
            out.append(x.effectiveEnd(now))
        }
        for d in days where d.startOfDay != skipDay?.startOfDay {
            if let w = store.workday(d) { out += [w.start, w.end].compactMap { $0 } }
        }
        return out
    }

    /// ⌥ turns snapping off, down to the minute.
    private var freehand: Bool { NSEvent.modifierFlags.contains(.option) }

    /// The nearest target within a few points of `t`, if any.
    private func magnet(_ t: Date, _ targets: [Date]) -> Date? {
        guard !freehand else { return nil }
        let reach = delta(8)
        let best = targets.min { abs($0.timeIntervalSince(t)) < abs($1.timeIntervalSince(t)) }
        return best.flatMap { abs($0.timeIntervalSince(t)) <= reach ? $0 : nil }
    }

    private func grid(_ t: Date) -> Date { t.snapped(to: freehand ? 1 : store.prefs.snapMinutes) }

    /// Pulled to a target when one is close, otherwise to the grid.
    private func snap(_ t: Date, _ targets: [Date]) -> (time: Date, magnet: Date?) {
        if let m = magnet(t, targets) { return (m, m) }
        return (grid(t), nil)
    }

    // MARK: Zoom

    /// Keeps the time under the pinch (or the middle of the view) in place while the hours grow or shrink.
    private func keepAnchored(from old: Double, to new: Double) {
        guard let sv = scroller.view, let doc = sv.documentView, old > 0 else { return }
        let visible = sv.contentView.bounds
        let anchorY = pinch?.y ?? visible.height / 2
        let flipped = doc.isFlipped
        let top = flipped ? visible.minY : doc.bounds.height - visible.maxY
        let hours = (top + anchorY - pad) / old
        DispatchQueue.main.async {
            let docH = doc.bounds.height
            let newTop = min(max(0, hours * new + pad - anchorY), max(0, docH - visible.height))
            let y = flipped ? newTop : docH - newTop - visible.height
            sv.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    // MARK: Start and end of the day

    /// The amber edges of the work day. Each has a grab strip on its outside edge, where entries rarely are,
    /// so it can be dragged without fighting the blocks.
    @ViewBuilder
    private func bookends(_ i: Int, _ day: Date, colW: CGFloat, now: Date) -> some View {
        let h = hours(day)
        if let s = h.start, s.startOfDay == day.startOfDay {
            bookend(s, isStart: true, col: i, day: day, colW: colW)
        }
        if let e = h.end, e.startOfDay == day.startOfDay {
            bookend(e, isStart: false, col: i, day: day, colW: colW)
        }
    }

    private func bookend(_ t: Date, isStart: Bool, col: Int, day: Date, colW: CGFloat) -> some View {
        let strip: CGFloat = 16
        let label = multi ? Fmt.time(t) : "\(isStart ? "Day started" : "Day ended") \(Fmt.time(t))"
        return VStack(spacing: 0) {
            if !isStart { Rectangle().fill(Theme.molte).frame(height: 2) }
            Text(label)
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.molte)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            if isStart { Rectangle().fill(Theme.molte).frame(height: 2) }
        }
        .frame(width: blockW(colW) + 6, height: strip)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(boundGesture(day, isStart: isStart))
        .help(isStart ? "Drag to change when the day started" : "Drag to change when the day ended")
        .offset(x: colX(col, colW) - 3, y: isStart ? y(t, in: day) - strip + 1 : y(t, in: day) - 1)
    }

    private func boundGesture(_ day: Date, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("calendar"))
            .onChanged { v in
                let w = store.workday(day)
                let minimum = Double(store.prefs.snapMinutes * 60)
                let pulled = snap(rawDate(atY: v.location.y, in: day), snapTargets(skipBoundsOf: day))
                var t = clamp(pulled.time, to: day)
                guide = pulled.magnet
                if isStart {
                    let end = w?.end ?? (day.isToday ? Date() : day.startOfDay.adding(days: 1))
                    t = min(t, end.addingTimeInterval(-minimum))
                } else {
                    if let s = w?.start { t = max(t, s.addingTimeInterval(minimum)) }
                    if day.isToday { t = min(t, Date()) }
                }
                bound = Bound(day: day.startOfDay, isStart: isStart, time: t)
            }
            .onEnded { _ in
                if let b = bound {
                    let w = store.workday(day)
                    store.setDayBounds(day, start: b.isStart ? b.time : w?.start, end: b.isStart ? w?.end : b.time)
                }
                bound = nil
                guide = nil
            }
    }

    private func nowLine(_ now: Date, col: Int, colW: CGFloat) -> some View {
        let day = days[col]
        return HStack(spacing: 0) {
            if col == 0 {
                Text(Fmt.time(now))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.gran)
                    .padding(.trailing, 4)
                    .frame(width: gutter + 2, alignment: .trailing)
                    .padding(.vertical, 4)
                    .background(Theme.canvas)
            }
            Circle().fill(Theme.gran).frame(width: 7, height: 7)
            Rectangle().fill(Theme.gran).frame(width: blockW(colW) + 2, height: 1)
        }
        .offset(x: col == 0 ? 0 : colX(col, colW) - 4, y: y(now, in: day) - 10)
        .frame(height: 20)
        .allowsHitTesting(false)
    }
}

/// Day name, tracked time and the day's start and end, above each column of the multi-day calendar.
struct ColumnHeader: View {
    @Environment(Store.self) private var store
    let day: Date
    let now: Date
    @State private var editing = false

    var body: some View {
        let selected = store.selectedDay == day.startOfDay
        let w = store.workday(day)
        let tracked = store.tracked(on: day, now: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Fmt.weekday.string(from: day))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(day.isToday ? Theme.gran : Theme.ink)
                Text("\(cal.component(.day, from: day))")
                    .font(.callout)
                    .foregroundStyle(day.isToday ? Theme.gran : Theme.inkSoft)
                Spacer(minLength: 2)
                if tracked >= 60 {
                    Text(Fmt.hmm(tracked)).font(Theme.mono).foregroundStyle(Theme.ink)
                }
            }
            HStack(spacing: 6) {
                Button { editing = true } label: {
                    Text(hoursLabel(w))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(w?.start == nil ? Theme.inkSoft : Theme.molte)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $editing, arrowEdge: .bottom) { DayBoundsEditor(day: day) }
                .help("Set when the day started and ended")
                Spacer(minLength: 0)
                if day.isToday {
                    Button(store.dayToggleTitle.replacingOccurrences(of: " Day", with: "")) { store.toggleDay() }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.medium))
                        .help("\(store.dayToggleTitle) (⌘D)")
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? Theme.gran.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) {
            if selected { Rectangle().fill(Theme.gran).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.selectedDay = day.startOfDay; store.span = .day }
        .onTapGesture { store.selectedDay = day.startOfDay }
        .help("Click to select, double-click to open the day")
    }

    private func hoursLabel(_ w: WorkDay?) -> String {
        guard let s = w?.start else { return "Set hours" }
        guard let e = w?.end else { return "\(Fmt.time(s))–" }
        return Fmt.range(s, e)
    }
}

struct EntryBlock: View {
    @Environment(Store.self) private var store
    let entry: Entry
    let start: Date
    let end: Date
    let now: Date
    let selected: Bool
    /// Several days side by side: put the time under the name.
    var narrow = false
    @State private var hover = false

    var body: some View {
        let color = store.color(entry.projectID)
        let planned = start > now
        let duration = end.timeIntervalSince(start)
        let compact = duration < 40 * 60

        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 4)
            if narrow {
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.name(entry.projectID))
                        .font(.system(size: 11, weight: .semibold))
                    if duration >= 30 * 60 {
                        Text(entry.isRunning ? "\(Fmt.time(start))–now" : Fmt.range(start, end))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(entry.isRunning ? Theme.gran : Theme.inkSoft)
                    }
                    if duration >= 60 * 60 && !entry.note.isEmpty {
                        Text(entry.note).font(.system(size: 10)).foregroundStyle(Theme.inkSoft)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, duration < 30 * 60 ? 0 : 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: duration < 30 * 60 ? .leading : .topLeading)
            } else {
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
        .overlay(alignment: duration < 40 * 60 ? .trailing : .topTrailing) {
            if hover && !entry.isRunning && !planned && end.timeIntervalSince(start) >= 10 * 60 {
                Button { store.resume(entry.id) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(color))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Resume \(store.name(entry.projectID)) now")
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
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
        if entry.isRunning {
            Button("Stop") { store.stop() }
        } else {
            Button("Resume") { store.resume(entry.id) }
            if store.canContinue(entry.id), let end = entry.end {
                Button("Resume from \(Fmt.time(end)), Counting the Break") { store.continueEntry(entry.id) }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(entry.id) }
    }
}

struct GapBlock: View {
    @Environment(Store.self) private var store
    let start: Date
    let end: Date
    var compact = false
    @State private var hover = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Theme.inkSoft.opacity(hover ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.raised.opacity(0.7) : .clear))
            .overlay(alignment: .leading) {
                if end.timeIntervalSince(start) >= 15 * 60 {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text(compact ? Fmt.dur(end.timeIntervalSince(start)) : "\(Fmt.dur(end.timeIntervalSince(start))) unallocated")
                        if hover && !compact { Text("Click to assign").foregroundStyle(Theme.inkSoft.opacity(0.8)) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.horizontal, compact ? 6 : 10)
                    .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { store.newEntry(start: start, end: end) }
    }
}

/// The AppKit scroll view behind a SwiftUI `ScrollView`, so zooming can keep its place precisely.
final class ScrollerRef {
    weak var view: NSScrollView?
}

struct ScrollerFinder: NSViewRepresentable {
    let ref: ScrollerRef

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { ref.view = v.enclosingScrollView }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        if ref.view == nil { DispatchQueue.main.async { ref.view = v.enclosingScrollView } }
    }
}
