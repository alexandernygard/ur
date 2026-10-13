import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch store.pane {
                case .today: DayView()
                case .week: WeekView()
                case .stats: StatsView()
                case .projects: ProjectsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .sheet(item: $store.editing) { draft in
            EntryEditor(draft: draft)
        }
        .sheet(isPresented: $store.showShortcuts) {
            ShortcutsSheet()
        }
        .overlay {
            if store.showPalette {
                CommandPalette()
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.showPalette)
        .onAppear {
            store.openMainWindow = { openWindow(id: "main") }
            store.undoManager = undoManager
        }
        .onChange(of: undoManager) { store.undoManager = undoManager }
    }
}

struct Sidebar: View {
    @Environment(Store.self) private var store

    var body: some View {
        let selection = Binding<Pane?>(get: { store.pane }, set: { if let p = $0 { store.pane = p } })
        List(selection: selection) {
            ForEach(Array(Pane.allCases.enumerated()), id: \.element) { i, pane in
                Label(pane.title, systemImage: pane.icon)
                    .tag(pane)
                    .badge(Text("⌥⌘\(i + 1)").font(.system(size: 10)).foregroundStyle(Theme.inkSoft))
            }
        }
        .safeAreaInset(edge: .bottom) { SidebarStatus() }
    }
}

/// Always-visible state of the day and the timer at the bottom of the sidebar.
struct SidebarStatus: View {
    @Environment(Store.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 10) {
                if let r = store.running {
                    HStack(spacing: 8) {
                        Dot(color: store.color(r.projectID))
                        Text(store.name(r.projectID)).lineLimit(1)
                        Spacer()
                        Text(Fmt.clock(ctx.date.timeIntervalSince(r.start)))
                            .font(Theme.mono)
                            .foregroundStyle(Theme.gran)
                    }
                    .font(.callout.weight(.medium))
                } else {
                    Text("Not tracking")
                        .font(.callout)
                        .foregroundStyle(Theme.inkSoft)
                }

                HStack(spacing: 6) {
                    Rectangle().fill(Theme.molte).frame(width: 2, height: 12)
                    switch store.dayState(.now) {
                    case .notStarted: Text("Day not started")
                    case .active(let s): Text("Started \(Fmt.time(s))")
                    case .ended(let s, let e): Text("\(Fmt.time(s))–\(Fmt.time(e))")
                    }
                    Spacer()
                    Button(store.dayToggleTitle) { store.toggleDay() }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.medium))
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            }
            .padding(14)
            .background(alignment: .top) { Divider() }
        }
    }
}
