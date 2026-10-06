import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

/// Nordic work-day palette. Molte (cloudberry amber) is reserved for the start and end of the day;
/// Gran (spruce) for what is live right now.
enum Theme {
    static let canvas = Color.adaptive(0xEEF1F2, 0x13191E)
    static let surface = Color.adaptive(0xF8F9F9, 0x1A2228)
    static let raised = Color.adaptive(0xFFFFFF, 0x212A31)
    static let ink = Color.adaptive(0x16212A, 0xE3E8EB)
    static let inkSoft = Color.adaptive(0x67757F, 0x8B98A2)
    static let line = Color.adaptive(0xD6DCE0, 0x2A343B)
    static let molte = Color.adaptive(0xC27A10, 0xF0A93B)
    static let gran = Color.adaptive(0x2D6A5C, 0x5DB39E)

    /// Ordered so neighbouring slots stay distinct for colour-blind readers (validated with ΔE checks).
    static let projectPalette: [(name: String, light: UInt32, dark: UInt32)] = [
        ("Fjord", 0x2F6CB5, 0x4A86CF),
        ("Cloudberry", 0xC9841C, 0xC98420),
        ("Heather", 0x8E52A8, 0x8E4DAD),
        ("Glacier", 0x1E9BB8, 0x2BA2BE),
        ("Lingonberry", 0xB53048, 0xCF4A62),
        ("Lichen", 0x7A9620, 0x7E9A28),
        ("Aurora", 0x5B5FD0, 0x7477E0),
        ("Rowan", 0xB5562A, 0xC9663A),
        ("Spruce", 0x1F7A60, 0x47A688),
        ("Slate", 0x5A6874, 0x93A1AD),
        ("Rosehip", 0xC0508A, 0xDB78AA),
        ("Bark", 0x86705A, 0xB49C84),
    ]

    static func project(_ index: Int) -> Color {
        let p = projectPalette[((index % projectPalette.count) + projectPalette.count) % projectPalette.count]
        return .adaptive(p.light, p.dark)
    }

    /// The one loud typographic element: the running clock.
    static func clock(_ size: CGFloat) -> Font {
        .system(size: size, weight: .thin).width(.compressed).monospacedDigit()
    }

    static let mono = Font.system(size: 11, weight: .medium).monospacedDigit()
}

/// A small keycap hint such as "⌘1".
struct KeyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.inkSoft)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
    }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// Wrapping row layout for project chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
