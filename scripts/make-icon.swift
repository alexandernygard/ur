// Renders the app icon: a fjord-dark face with the work day drawn as an amber arc from 08 to 16.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with ~185 radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(color(0x16212A).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(0x22323E).cgColor, color(0x121A21).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    ctx.restoreGState()

    let c = CGPoint(x: body.midX, y: body.midY)
    let r = body.width * 0.33

    // Hour ticks on a 24-hour dial (00 at top).
    for h in 0..<24 {
        let a = CGFloat.pi / 2 - CGFloat(h) / 24 * 2 * .pi
        let major = h % 6 == 0
        let r1 = r * (major ? 1.10 : 1.14), r2 = r * 1.22
        ctx.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
        ctx.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
        ctx.setStrokeColor(color(0xE3E8EB, major ? 0.75 : 0.28).cgColor)
        ctx.setLineWidth(s * (major ? 0.014 : 0.008))
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    // The work day, 08–16, in molte amber.
    func angle(_ h: CGFloat) -> CGFloat { .pi / 2 - h / 24 * 2 * .pi }
    ctx.addArc(center: c, radius: r * 0.86, startAngle: angle(8), endAngle: angle(16), clockwise: true)
    ctx.setStrokeColor(color(0xF0A93B).cgColor)
    ctx.setLineWidth(s * 0.075)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // A single spruce hand at "now", inside the day.
    let now = angle(13.2)
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + cos(now) * r * 0.74, y: c.y + sin(now) * r * 0.74))
    ctx.setStrokeColor(color(0x5DB39E).cgColor)
    ctx.setLineWidth(s * 0.03)
    ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: c.x - s * 0.03, y: c.y - s * 0.03, width: s * 0.06, height: s * 0.06))
    ctx.setFillColor(color(0xE3E8EB).cgColor)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Ur.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
try! render(512).write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
print("Wrote \(out)")
