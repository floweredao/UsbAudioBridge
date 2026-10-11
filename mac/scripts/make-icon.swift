// Renders Resources/AppIcon.svg (same motif as the Android launcher icon) into AppIcon.icns and AppIcon-1024.png.
// Usage: swift scripts/make-icon.swift <resources-dir> [extra-png-out:size ...]
import AppKit

let resDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let svgURL = URL(fileURLWithPath: "\(resDir)/AppIcon.svg")
guard let svg = NSImage(contentsOf: svgURL) else { fatalError("cannot load \(svgURL.path)") }
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "\(resDir)/AppIcon.icns"]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(1024).write(to: URL(fileURLWithPath: "\(resDir)/AppIcon-1024.png"))
for spec in CommandLine.arguments.dropFirst(2) {
    let parts = spec.split(separator: ":")
    try render(Int(parts[1])!).write(to: URL(fileURLWithPath: String(parts[0])))
}
print("wrote \(resDir)/AppIcon.icns")
