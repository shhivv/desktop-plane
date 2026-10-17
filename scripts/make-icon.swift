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
    func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    // Warm black, lit from a bulb above (see Theme.swift).
    c(0x0F0D0B).setFill()
    squircle.fill()
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [c(0xF2C27B, 0.32), c(0xF2C27B, 0.08), c(0xF2C27B, 0)])!
        .draw(fromCenter: NSPoint(x: body.midX, y: body.maxY), radius: 0,
              toCenter: NSPoint(x: body.midX, y: body.maxY), radius: body.width * 0.95, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()
    c(0xF2EBE1, 0.1).setStroke()
    squircle.lineWidth = s / 512
    squircle.stroke()

    // The Mac mini from the app (MacMini in Theme.swift): top face in lamplight, front edge in
    // shadow, power light on. y runs up here.
    let w = body.width * 0.62, top = w * 0.2, front = w * 0.1
    let x0 = body.midX - w / 2, yFront = body.midY - (top + front) / 2 - body.height * 0.03
    let taper = w * 0.07
    let face = NSBezierPath()
    face.move(to: NSPoint(x: x0, y: yFront + front))
    face.line(to: NSPoint(x: x0 + w, y: yFront + front))
    face.line(to: NSPoint(x: x0 + w - taper, y: yFront + front + top - top * 0.25))
    face.curve(to: NSPoint(x: x0 + w - taper - top * 0.4, y: yFront + front + top),
               controlPoint1: NSPoint(x: x0 + w - taper - top * 0.05, y: yFront + front + top), controlPoint2: NSPoint(x: x0 + w - taper - top * 0.2, y: yFront + front + top))
    face.line(to: NSPoint(x: x0 + taper + top * 0.4, y: yFront + front + top))
    face.curve(to: NSPoint(x: x0 + taper, y: yFront + front + top - top * 0.25),
               controlPoint1: NSPoint(x: x0 + taper + top * 0.2, y: yFront + front + top), controlPoint2: NSPoint(x: x0 + taper + top * 0.05, y: yFront + front + top))
    face.close()
    NSGradient(colors: [c(0x8A8075), c(0x4E473F)])!.draw(in: face, angle: 90)
    let edge = NSBezierPath(roundedRect: NSRect(x: x0, y: yFront, width: w, height: front + 1), xRadius: front * 0.45, yRadius: front * 0.45)
    NSGradient(colors: [c(0x14110E), c(0x2E2924)])!.draw(in: edge, angle: 90)
    let d = front * 0.32
    let center = NSPoint(x: x0 + w - w * 0.08, y: yFront + front / 2)
    NSGradient(colors: [c(0xF2C27B, 0.75), c(0xF2C27B, 0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: d * 3.2, options: [])
    c(0xFFF4E0).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)).fill()
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
