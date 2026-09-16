import AppKit

// Original vector artwork. No SF Symbols or third-party assets.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func drawIcon(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
    let base = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
    NSColor(calibratedWhite: 0.085, alpha: 1).setFill(); base.fill()
    NSColor(calibratedWhite: 0.27, alpha: 1).setStroke(); base.lineWidth = 2; base.stroke()
    let ring = NSBezierPath(); ring.appendArc(withCenter: NSPoint(x: 512, y: 528), radius: 270, startAngle: 218, endAngle: -38, clockwise: true)
    ring.lineWidth = 54; ring.lineCapStyle = .round
    NSColor(calibratedRed: 0.54, green: 0.88, blue: 0.73, alpha: 1).setStroke(); ring.stroke()
    for radius: CGFloat in [158, 103] {
        let arc = NSBezierPath(); arc.appendArc(withCenter: NSPoint(x: 512, y: 426), radius: radius, startAngle: 42, endAngle: 138, clockwise: false)
        arc.lineWidth = 36; arc.lineCapStyle = .round; NSColor.white.setStroke(); arc.stroke()
    }
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 492, y: 416, width: 40, height: 40)).fill()
    for (i, x) in [CGFloat(440), 512, 584].enumerated() {
        NSColor(calibratedWhite: i == 2 ? 0.28 : 0.7, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 18, y: 239, width: 36, height: 36)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try drawIcon(1024).write(to: output.appendingPathComponent("app-icon.png"))
