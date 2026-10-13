import Foundation

/// A named group of projects, such as a client. Its time is the sum of its projects.
struct ProjectGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

struct Project: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    /// `nil` when the project stands on its own.
    var groupID: UUID?
    var archived = false
    /// The free-text client from before groups existed. Turned into a group on load.
    var legacyClient: String?
}

extension Project: Codable {
    enum CodingKeys: String, CodingKey { case id, name, colorIndex, groupID, archived, client }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        legacyClient = try c.decodeIfPresent(String.self, forKey: .client)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colorIndex, forKey: .colorIndex)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encode(archived, forKey: .archived)
    }
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

struct AppData: Codable, Equatable {
    var groups: [ProjectGroup] = []
    var projects: [Project] = []
    var entries: [Entry] = []
    var days: [String: WorkDay] = [:]
    var preferences = Preferences()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([ProjectGroup].self, forKey: .groups) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        days = try c.decodeIfPresent([String: WorkDay].self, forKey: .days) ?? [:]
        preferences = try c.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
        migrateClients()
    }

    /// Projects that had a client get a group of that name.
    private mutating func migrateClients() {
        for i in projects.indices {
            defer { projects[i].legacyClient = nil }
            guard projects[i].groupID == nil,
                  let client = projects[i].legacyClient?.trimmingCharacters(in: .whitespaces), !client.isEmpty
            else { continue }
            if let g = groups.first(where: { $0.name.lowercased() == client.lowercased() }) {
                projects[i].groupID = g.id
            } else {
                let g = ProjectGroup(name: client)
                groups.append(g)
                projects[i].groupID = g.id
            }
        }
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

/// Development builds (`scripts/dev.sh`, or `swift run`) keep their own data and shortcut,
/// so they can run next to the installed app without touching its data.
enum Build {
    static let isDev = Bundle.main.bundleIdentifier != "no.nygard.ur"
    static let name = isDev ? "Ur Dev" : "Ur"
}

enum Persistence {
    static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["UR_DATA_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Build.name, isDirectory: true)
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
