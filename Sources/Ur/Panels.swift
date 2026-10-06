import SwiftUI
import AppKit
import ServiceManagement

// MARK: Menu bar

struct MenuBarLabel: View {
    let store: Store

    var body: some View {
        let _ = store.tick
        if let r = store.running {
            Image(systemName: "record.circle")
            Text(Fmt.hmm(Date().timeIntervalSince(r.start)))
        } else {
            Image(systemName: "clock")
        }
    }
}

struct MenuBarPanel: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 12) {
                if let r = store.running {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.clock(ctx.date.timeIntervalSince(r.start)))
                            .font(Theme.clock(40))
                        HStack(spacing: 6) {
                            Dot(color: store.color(r.projectID))
                            Text(store.name(r.projectID)).fontWeight(.medium)
                            Spacer()
                            Button("Stop") { store.stop() }
                        }
                    }
                } else {
                    Text("Not tracking").foregroundStyle(Theme.inkSoft)
                }

                HStack {
                    Rectangle().fill(Theme.molte).frame(width: 2, height: 14)
                    switch store.dayState(.now) {
                    case .notStarted: Text("Day not started")
                    case .active(let s): Text("Started \(Fmt.time(s)), \(Fmt.dur(ctx.date.timeIntervalSince(s))) ago")
                    case .ended(let s, let e): Text("Worked \(Fmt.time(s))–\(Fmt.time(e))")
                    }
                    Spacer()
                    Button(store.dayToggleTitle) { store.toggleDay() }
                }
                .font(.callout)

                Divider()

                VStack(spacing: 2) {
                    ForEach(store.activeProjects) { p in
                        let isRunning = store.running?.projectID == p.id
                        Button { store.toggle(p.id) } label: {
                            HStack {
                                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.project(p.colorIndex))
                                    .frame(width: 14)
                                Text(p.name)
                                Spacer()
                                let t = store.tracked(on: ctx.date, project: p.id, now: ctx.date)
                                if t >= 60 { Text(Fmt.hmm(t)).monospacedDigit().foregroundStyle(Theme.inkSoft) }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(isRunning ? Theme.project(p.colorIndex).opacity(0.15) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                HStack {
                    Button("Open Ur") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "main")
                    }
                    Spacer()
                    Text("⌃⌥Space").font(.caption).foregroundStyle(Theme.inkSoft)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .font(.callout)
            }
            .padding(14)
            .frame(width: 300)
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Work day") {
                Stepper(value: $store.data.preferences.targetHours, in: 1...14, step: 0.5) {
                    Text("Daily target: \(Fmt.dur(store.prefs.targetHours * 3600))")
                }
                Toggle("Start the day automatically when a timer starts", isOn: $store.data.preferences.autoStartDay)
            }
            Section("Timeline") {
                Picker("Snap to", selection: $store.data.preferences.snapMinutes) {
                    ForEach([1, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
                }
                Slider(value: $store.data.preferences.hourHeight, in: 40...140) {
                    Text("Hour height")
                }
            }
            Section("System") {
                Toggle("Open Ur at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Global shortcut", value: "⌃⌥Space opens the command bar")
                LabeledContent("Data") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Persistence.file]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}

// MARK: Shortcuts

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Tracking", [
            ("⌘1 – ⌘9", "Start or stop project 1–9"),
            ("⌘K", "Command bar: start, switch, or log time"),
            ("⌃⌥Space", "Command bar from any app"),
            ("⌘.", "Stop the timer"),
            ("⌘R", "Resume the last project"),
            ("⌘D", "Start, end, or resume the work day"),
        ]),
        ("Entries", [
            ("⌘N", "Add time"),
            ("⌘E", "Edit the selected or running entry"),
            ("⌘⌫", "Delete the selected entry"),
            ("Drag", "On the timeline: log a new block"),
            ("Drag a block", "Move it; drag its edges to resize"),
        ]),
        ("Moving around", [
            ("⌘T", "Go to today"),
            ("⌘[  ⌘]", "Previous and next day or week"),
            ("⌥⌘1 – ⌥⌘4", "Day, Week, Stats, Projects"),
            ("⌘/", "This list"),
        ]),
        ("Command bar examples", [
            ("design", "Start Design now"),
            ("design 9-11:30", "Log 09:00–11:30 to Design"),
            ("design 1h30 review", "Log the last 1h 30m with a note"),
            ("new thing", "Create a project and start it"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard shortcuts").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 20) { group(groups[0]); group(groups[1]) }
                VStack(alignment: .leading, spacing: 20) { group(groups[2]); group(groups[3]) }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
    }

    private func group(_ g: (String, [(String, String)])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(g.0).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(g.1, id: \.0) { k, v in
                    GridRow {
                        Text(k).font(.system(.callout, design: .rounded).weight(.medium)).foregroundStyle(Theme.ink)
                        Text(v).font(.callout).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
    }
}
