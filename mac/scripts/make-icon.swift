// Draws the app icon (same motif as the Android launcher icon) and writes AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let inset = 100 * s
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.31, green: 0.27, blue: 0.90, alpha: 1),
                        NSColor(srgbRed: 0.49, green: 0.23, blue: 0.93, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.58, blue: 0.53, alpha: 1)])!
        .draw(in: shape, angle: -45)
    NSColor.white.setFill()
    let bars: [(CGFloat, CGFloat)] = [(-2, 150), (-1, 270), (0, 380), (1, 230), (2, 130)]
    for (i, h) in bars {
        let w = 64 * s
        let cx = 512 * s + i * 96 * s
        let cy = 540 * s
        NSBezierPath(roundedRect: NSRect(x: cx - w / 2, y: cy - h * s / 2, width: w, height: h * s), xRadius: w / 2, yRadius: w / 2).fill()
    }
    NSColor(white: 1, alpha: 0.8).setFill()
    NSBezierPath(roundedRect: NSRect(x: 448 * s, y: 260 * s, width: 128 * s, height: 60 * s), xRadius: 14 * s, yRadius: 14 * s).fill()
    NSBezierPath(rect: NSRect(x: 474 * s, y: 215 * s, width: 22 * s, height: 45 * s)).fill()
    NSBezierPath(rect: NSRect(x: 528 * s, y: 215 * s, width: 22 * s, height: 45 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "\(outDir)/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try render(1024).write(to: URL(fileURLWithPath: "\(outDir)/AppIcon-1024.png"))
print("wrote \(outDir)/AppIcon.icns")
