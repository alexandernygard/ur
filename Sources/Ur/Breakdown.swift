import SwiftUI

/// Time per project, with grouped projects listed under their group's combined time.
/// Click a group to fold its projects away.
struct Breakdown: View {
    @Environment(Store.self) private var store
    let tallies: [Tally]
    /// Show each line's share of the whole as a percentage.
    var showShare = false
    var barHeight: CGFloat = 4
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        let sum = max(1, tallies.reduce(0) { $0 + $1.total })
        VStack(alignment: .leading, spacing: 12) {
            ForEach(tallies) { t in
                if let g = t.group {
                    group(g, t, sum: sum)
                } else if let p = t.projects.first {
                    line(p, sum: sum)
                }
            }
        }
    }

    private func group(_ g: ProjectGroup, _ t: Tally, sum: TimeInterval) -> some View {
        let open = !collapsed.contains(g.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { collapsed.insert(g.id) } else { collapsed.remove(g.id) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.inkSoft)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 10)
                        Text(g.name).fontWeight(.semibold).lineLimit(1)
                        if !open {
                            Text("\(t.projects.count) \(t.projects.count == 1 ? "project" : "projects")")
                                .foregroundStyle(Theme.inkSoft)
                        }
                        Spacer()
                        figures(t.total, sum: sum, bold: true)
                    }
                    .font(.callout)
                    // The group's bar is made of its projects' colours.
                    GeometryReader { geo in
                        let width = max(3, geo.size.width * t.total / sum)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line.opacity(0.6))
                            HStack(spacing: 0) {
                                ForEach(t.projects) { p in
                                    Rectangle().fill(store.color(p.id))
                                        .frame(width: width * p.time / max(1, t.total))
                                }
                            }
                            .frame(width: width, alignment: .leading)
                            .clipShape(Capsule())
                        }
                    }
                    .frame(height: barHeight)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the projects in \(g.name)" : "Show the projects in \(g.name)")

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(t.projects) { p in line(p, sum: sum, thin: true) }
                }
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 4)
                }
            }
        }
    }

    private func line(_ p: ProjectTime, sum: TimeInterval, thin: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Dot(color: store.color(p.id))
                Text(store.name(p.id)).lineLimit(1)
                Spacer()
                figures(p.time, sum: sum, bold: false)
            }
            .font(.callout)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line.opacity(0.6))
                    Capsule().fill(store.color(p.id)).frame(width: max(3, g.size.width * p.time / sum))
                }
            }
            .frame(height: thin ? max(2, barHeight - 1) : barHeight)
        }
    }

    @ViewBuilder
    private func figures(_ t: TimeInterval, sum: TimeInterval, bold: Bool) -> some View {
        Text(showShare ? Fmt.hmm(t) : Fmt.dur(t))
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(showShare || bold ? Theme.ink : Theme.inkSoft)
        if showShare {
            Text("\(Int((t / sum * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
