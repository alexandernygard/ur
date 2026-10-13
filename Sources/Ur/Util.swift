import Foundation

/// Weeks start on Monday, ISO week numbers.
let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.locale = Locale(identifier: "en_GB")
    c.timeZone = .current
    c.firstWeekday = 2
    c.minimumDaysInFirstWeek = 4
    return c
}()

extension Date {
    var startOfDay: Date { cal.startOfDay(for: self) }
    func adding(days: Int) -> Date { cal.date(byAdding: .day, value: days, to: self)! }
    func adding(months: Int) -> Date { cal.date(byAdding: .month, value: months, to: self)! }
    var startOfMonth: Date { cal.dateInterval(of: .month, for: self)!.start }
    var startOfWeek: Date { cal.dateInterval(of: .weekOfYear, for: self)!.start }
    var weekNumber: Int { cal.component(.weekOfYear, from: self) }
    var dayKey: String { Fmt.key.string(from: self) }
    var isToday: Bool { cal.isDateInToday(self) }
    var hoursIntoDay: Double { timeIntervalSince(startOfDay) / 3600 }

    func at(hour: Int, minute: Int) -> Date {
        cal.date(bySettingHour: min(hour, 23), minute: minute, second: 0, of: self)!
            .addingTimeInterval(hour >= 24 ? 3600 : 0)
    }

    func floored(to minutes: Int) -> Date {
        let s = Double(max(1, minutes) * 60)
        let local = timeIntervalSince(startOfDay)
        return startOfDay.addingTimeInterval((local / s).rounded(.down) * s)
    }

    func snapped(to minutes: Int) -> Date {
        let s = Double(max(1, minutes) * 60)
        let local = timeIntervalSince(startOfDay)
        return startOfDay.addingTimeInterval((local / s).rounded() * s)
    }
}

enum Fmt {
    private static func make(_ format: String? = nil, template: String? = nil) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = .current
        if let format { f.dateFormat = format }
        if let template { f.setLocalizedDateFormatFromTemplate(template) }
        return f
    }

    static let key: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let hm = make("HH:mm")
    static let dayTitle = make("EEEE d MMMM")
    static let weekday = make("EEE")
    static let dayMonth = make("d MMM")
    static let monthYear = make("MMMM yyyy")
    static let month = make("MMM")

    static func time(_ d: Date?) -> String { d.map { hm.string(from: $0) } ?? "–" }

    /// "2h 14m", "45m", "0m"
    static func dur(_ t: TimeInterval) -> String {
        let m = Int((max(0, t) / 60).rounded())
        if m < 60 { return "\(m)m" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    /// "2:14:07"
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "2:14"
    static func hmm(_ t: TimeInterval) -> String {
        let m = Int((max(0, t) / 60).rounded())
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func hours(_ t: TimeInterval) -> String {
        let h = t / 3600
        return h == h.rounded() ? String(format: "%.0f", h) : String(format: "%.1f", h)
    }

    /// Hour-of-day as a clock string, e.g. 8.25 -> "08:15".
    static func clockHour(_ h: Double) -> String {
        let m = Int((h * 60).rounded())
        return String(format: "%02d:%02d", (m / 60) % 24, m % 60)
    }

    static func range(_ a: Date, _ b: Date) -> String { "\(time(a))–\(time(b))" }
}

/// Parses times typed in natural shorthand: "9", "930", "9:30", "09.30", ranges like "9-11:30", durations like "1h30" or "45m".
enum TimeParse {
    struct Range { var span: Swift.Range<String.Index>; var start: (Int, Int); var end: (Int, Int) }
    struct Duration { var span: Swift.Range<String.Index>; var seconds: TimeInterval }

    private static let rangeRx = try! NSRegularExpression(
        pattern: #"(?<![\w:.])(\d{1,2})(?:[:.]?(\d{2}))?\s*[-–]\s*(\d{1,2})(?:[:.]?(\d{2}))?(?![:\d]|\.\d)"#)
    private static let durRx = try! NSRegularExpression(
        pattern: #"(?<![\w:.])(?:(\d+(?:[.,]\d+)?)\s*h(?:\s*(\d{1,2})\s*m?)?|(\d+)\s*m(?:in)?)(?![\w])"#,
        options: [.caseInsensitive])

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        guard let r = Swift.Range(m.range(at: i), in: s) else { return nil }
        return String(s[r])
    }

    private static func valid(_ h: Int, _ m: Int) -> Bool { (0...24).contains(h) && (0..<60).contains(m) && !(h == 24 && m > 0) }

    static func range(in s: String) -> Range? {
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = rangeRx.firstMatch(in: s, range: ns), let span = Swift.Range(m.range, in: s) else { return nil }
        var h1 = Int(group(m, 1, in: s)!)!, m1 = Int(group(m, 2, in: s) ?? "0")!
        var h2 = Int(group(m, 3, in: s)!)!, m2 = Int(group(m, 4, in: s) ?? "0")!
        guard valid(h1, m1), valid(h2, m2) else { return nil }
        // Nobody logs work at 2–4 in the night: a start of 1–6 means the afternoon,
        // unless written as 24-hour time with a leading zero ("01:00").
        let padded = group(m, 1, in: s)!.hasPrefix("0") || group(m, 3, in: s)!.hasPrefix("0")
        if !padded {
            if (1...6).contains(h1) {
                h1 += 12
                if h2 < 12 && h2 + 12 > h1 { h2 += 12 }
            } else if (7...12).contains(h1) && (1...6).contains(h2) {
                h2 += 12
            }
        }
        return Range(span: span, start: (h1, m1), end: (h2, m2))
    }

    static func duration(in s: String) -> Duration? {
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = durRx.firstMatch(in: s, range: ns), let span = Swift.Range(m.range, in: s) else { return nil }
        if let h = group(m, 1, in: s) {
            let hours = Double(h.replacingOccurrences(of: ",", with: ".")) ?? 0
            let mins = Double(group(m, 2, in: s) ?? "0") ?? 0
            let total = hours * 3600 + mins * 60
            return total > 0 ? Duration(span: span, seconds: total) : nil
        }
        if let mm = group(m, 3, in: s), let mins = Double(mm), mins > 0 {
            return Duration(span: span, seconds: mins * 60)
        }
        return nil
    }
}

/// Simple fuzzy ranking for project names.
enum Fuzzy {
    static func score(_ name: String, _ query: String) -> Int {
        let n = name.lowercased(), q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return 1 }
        if n == q { return 100 }
        if n.hasPrefix(q) { return 80 }
        if n.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 60 }
        if n.contains(q) { return 40 }
        var it = n.makeIterator()
        for ch in q where ch != " " {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return 0 }
        }
        return 20
    }
}
