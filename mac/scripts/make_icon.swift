// アプリアイコン (AppIcon.icns) を生成する:  swift scripts/make_icon.swift Resources
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size: CGFloat = 1024

func render() -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(red: 0.04, green: 0.08, blue: 0.20, alpha: 1),
                        NSColor(red: 0.05, green: 0.28, blue: 0.45, alpha: 1)])!.draw(in: bg, angle: -60)
    let c = NSPoint(x: size / 2, y: size / 2)
    // HUD 風の同心リング
    for (r, w, a) in [(300.0, 10.0, 0.9), (250.0, 4.0, 0.5), (340.0, 3.0, 0.35)] {
        let ring = NSBezierPath()
        ring.appendArc(withCenter: c, radius: r, startAngle: 20, endAngle: 340)
        ring.lineWidth = w
        NSColor(red: 0.35, green: 0.85, blue: 1, alpha: a).setStroke()
        ring.stroke()
    }
    // 中央の波形
    let bars: [CGFloat] = [0.35, 0.6, 1.0, 0.75, 0.45, 0.8, 0.5]
    let barW: CGFloat = 34, gap: CGFloat = 22
    let total = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
    for (i, h) in bars.enumerated() {
        let height = 300 * h
        let x = c.x - total / 2 + CGFloat(i) * (barW + gap)
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: c.y - height / 2, width: barW, height: height), xRadius: 17, yRadius: 17)
        NSColor(red: 0.55, green: 0.93, blue: 1, alpha: 1).setFill()
        bar.fill()
    }
    img.unlockFocus()
    return img
}

let base = render()
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = s * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        base.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(s)x\(s).png" : "icon_\(s)x\(s)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "\(outDir)/AppIcon.icns"]
try p.run()
p.waitUntilExit()
print("wrote \(outDir)/AppIcon.icns")
