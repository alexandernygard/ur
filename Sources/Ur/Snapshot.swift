import SwiftUI
import AppKit

/// Development aid: `UR_SNAPSHOT=/some/dir` renders each pane of the main window to PNG and quits.
enum Snapshot {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["UR_SNAPSHOT"] else { return }
        let store = Store.shared
        let dark = ProcessInfo.processInfo.environment["UR_SNAPSHOT_DARK"] != nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        let host = NSHostingView(rootView: ContentView().environment(store))
        window.contentView = host
        window.orderFront(nil)

        var steps: [(String, () -> Void)] = Pane.allCases.map { pane in (pane.rawValue, { store.pane = pane }) }
        steps.insert(("today-past", { store.pane = .today; store.selectedDay = Date().startOfDay.adding(days: -1) }), at: 1)
        steps.append(("palette", { store.pane = .today; store.goToday(); store.showPalette = true }))
        steps.append(("editor", { store.showPalette = false; store.newEntry() }))

        func next(_ i: Int) {
            guard i < steps.count else { store.saveNow(); exit(0) }
            steps[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let view: NSView = (i == steps.count - 1 ? NSApp.windows.last(where: { $0.isVisible && $0 != window && $0.className.contains("Sheet") })?.contentView : nil) ?? host
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let suffix = dark ? "-dark" : ""
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(steps[i].0)\(suffix).png"))
                }
                next(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next(0) }
    }
}
