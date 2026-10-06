import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct UrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store.shared

    var body: some Scene {
        Window("Ur", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 800)
        .commands { UrCommands(store: store) }

        MenuBarExtra {
            MenuBarPanel().environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshot.runIfRequested()
        GlobalHotKey.register {
            let store = Store.shared
            NSApp.activate(ignoringOtherApps: true)
            store.openMainWindow?()
            store.showPalette = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Store.shared.openMainWindow?() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.saveNow()
    }
}

/// ⌃⌥Space from anywhere opens Ur with the command bar ready.
enum GlobalHotKey {
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ handler: @escaping () -> Void) {
        action = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5552_4B59), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

struct UrCommands: Commands {
    let store: Store

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Time…") { store.newEntry() }
                .keyboardShortcut("n")
                .disabled(store.isModal)
            Button("New Project") { store.pane = .projects; NotificationCenter.default.post(name: .focusNewProject, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Track") {
            Button("Command Bar…") { store.showPalette.toggle() }
                .keyboardShortcut("k")
            Divider()
            Button(store.dayToggleTitle) { store.toggleDay() }
                .keyboardShortcut("d")
                .disabled(store.isModal)
            Button("Stop Timer") { store.stop() }
                .keyboardShortcut(".")
                .disabled(store.running == nil)
            Button("Resume Last") { store.resumeLast() }
                .keyboardShortcut("r")
                .disabled(store.isModal)
            Divider()
            ForEach(Array(store.activeProjects.prefix(9).enumerated()), id: \.element.id) { i, p in
                Button((store.running?.projectID == p.id ? "Stop " : "Start ") + p.name) { store.startProject(at: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .disabled(store.isModal)
            }
            Divider()
            Button("Edit Entry…") { store.editSelectedOrRunning() }
                .keyboardShortcut("e")
                .disabled(store.isModal || (store.selectedEntryID == nil && store.running == nil))
            Button("Delete Entry") { store.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.isModal || store.selectedEntryID == nil || store.pane == .projects)
        }

        CommandMenu("Go") {
            ForEach(Array(Pane.allCases.enumerated()), id: \.element) { i, pane in
                Button(pane.title) { store.pane = pane }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
            Divider()
            Button("Today") { store.goToday(); if store.pane != .week { store.pane = .today } }
                .keyboardShortcut("t")
            Button("Previous") { store.step(-1) }
                .keyboardShortcut("[")
            Button("Next") { store.step(1) }
                .keyboardShortcut("]")
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { store.showShortcuts = true }
                .keyboardShortcut("/")
        }
    }
}

extension Notification.Name {
    static let focusNewProject = Notification.Name("ur.focusNewProject")
}
