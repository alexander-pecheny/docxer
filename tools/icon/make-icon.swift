// Renders App/AppIcon.icns from the Lucide pen-tool glyph (ISC licence).
// Usage: swift tools/icon/make-icon.swift
import AppKit

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let glyph = NSImage(contentsOf: dir.appendingPathComponent("pen-tool.svg"))!

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Apple's icon grid: an 824-point rounded square centred on a 1024 canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.25, green: 0.42, blue: 0.95, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.20, blue: 0.62, alpha: 1))!.draw(in: path, angle: -90)
    glyph.draw(in: tile.insetBy(dx: 170 * s, dy: 170 * s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let out = dir.appendingPathComponent("../../App/AppIcon.icns").standardizedFileURL
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try! render(512).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("docxer-icon-preview.png"))
print(out.path)
