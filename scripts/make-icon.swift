// Renders assets/AppIcon.icns: the app's mark, white on a black squircle.
//   swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: the shape sits inside a 824/1024 square.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.13, alpha: 1), NSColor(white: 0.0, alpha: 1)])!.draw(in: squircle, angle: -90)
    NSColor(white: 1, alpha: 0.12).setStroke()
    squircle.lineWidth = s / 512
    squircle.stroke()

    // The mark: a filled window behind an outlined one (see Mark in Theme.swift; y is flipped here).
    let m = body.width * 0.5
    let origin = NSPoint(x: body.midX - m / 2, y: body.midY - m / 2)
    let w = m * 0.72, h = m * 0.56, r = m * 0.14
    let back = NSRect(x: origin.x + m * 0.28, y: origin.y + m - m * 0.06 - h, width: w, height: h)
    let front = NSRect(x: origin.x, y: origin.y + m - m * 0.38 - h, width: w, height: h)
    NSColor(white: 0.93, alpha: 1).setFill()
    NSBezierPath(roundedRect: back, xRadius: r, yRadius: r).fill()
    NSColor(white: 0.04, alpha: 1).setFill()
    NSBezierPath(roundedRect: front, xRadius: r, yRadius: r).fill()
    let lw = m * 0.08
    let outline = NSBezierPath(roundedRect: front.insetBy(dx: lw / 2, dy: lw / 2), xRadius: r - lw / 2, yRadius: r - lw / 2)
    outline.lineWidth = lw
    NSColor(white: 0.93, alpha: 1).setStroke()
    outline.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("assets/AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try render(1024).write(to: root.appendingPathComponent("assets/AppIcon.png"))
print("wrote assets/AppIcon.icns")
