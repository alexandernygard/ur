import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var client: String = ""
    var archived = false
}

struct Entry: Identifiable, Codable, Hashable {
    var id = UUID()
    var projectID: UUID
    var start: Date
    /// `nil` while the timer is running.
    var end: Date?
    var note: String = ""

    var isRunning: Bool { end == nil }

    func effectiveEnd(_ now: Date = .now) -> Date { end ?? max(now, start) }

    /// Duration inside `[from, to)`, never counting time after `now`.
    func duration(from: Date = .distantPast, to: Date = .distantFuture, now: Date = .now) -> TimeInterval {
        let s = max(start, from)
        let e = min(effectiveEnd(now), to, now)
        return max(0, e.timeIntervalSince(s))
    }
}

/// When the work day started and ended. Keyed by `yyyy-MM-dd`.
struct WorkDay: Codable, Hashable {
    var key: String
    var start: Date?
    var end: Date?
}

struct Preferences: Codable, Hashable {
    var targetHours: Double = 7.5
    var autoStartDay = true
    var snapMinutes = 5
    var hourHeight: Double = 64

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        targetHours = try c.decodeIfPresent(Double.self, forKey: .targetHours) ?? d.targetHours
        autoStartDay = try c.decodeIfPresent(Bool.self, forKey: .autoStartDay) ?? d.autoStartDay
        snapMinutes = try c.decodeIfPresent(Int.self, forKey: .snapMinutes) ?? d.snapMinutes
        hourHeight = try c.decodeIfPresent(Double.self, forKey: .hourHeight) ?? d.hourHeight
    }
}

struct AppData: Codable {
    var projects: [Project] = []
    var entries: [Entry] = []
    var days: [String: WorkDay] = [:]
    var preferences = Preferences()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        days = try c.decodeIfPresent([String: WorkDay].self, forKey: .days) ?? [:]
        preferences = try c.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
    }

    static var starter: AppData {
        var d = AppData()
        d.projects = [
            Project(name: "Admin", colorIndex: 9),
            Project(name: "Meetings", colorIndex: 2),
        ]
        return d
    }
}

enum Persistence {
    static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["UR_DATA_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ur", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("ur.json") }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func load() -> AppData? {
        guard let raw = try? Data(contentsOf: file) else { return nil }
        do { return try decoder.decode(AppData.self, from: raw) } catch {
            // Keep the unreadable file aside rather than overwriting it.
            let aside = directory.appendingPathComponent("ur-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: file, to: aside)
            NSLog("Ur: could not read data file: \(error)")
            return nil
        }
    }

    static func save(_ data: AppData) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(data).write(to: file, options: .atomic)
        } catch {
            NSLog("Ur: save failed: \(error)")
        }
    }

    /// One backup per day, the last 14 kept.
    static func backup() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let backups = directory.appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let target = backups.appendingPathComponent("ur-\(Date().dayKey).json")
        if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: file, to: target) }
        let all = (try? fm.contentsOfDirectory(atPath: backups.path))?.filter { $0.hasSuffix(".json") }.sorted() ?? []
        for name in all.dropLast(14) { try? fm.removeItem(at: backups.appendingPathComponent(name)) }
    }
}
