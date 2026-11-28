// Makes PapersIcon.icns: Nebula's icon with a book badge in the same ink.
// Run from apple/Launcher:  swift make-icon.swift  (needs iconutil)
import AppKit

let ink = NSColor(srgbRed: 0.23, green: 0.18, blue: 0.13, alpha: 1)
let paper = NSColor(srgbRed: 0.93, green: 0.89, blue: 0.81, alpha: 1)
guard let base = NSImage(contentsOfFile: "../Notepro/AppIcon.icns") else { fatalError("AppIcon.icns not found") }

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    base.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    // Badge: a paper disc with a double ink ring, bottom right.
    let d = s * 0.42, o = s * 0.035
    let disc = NSRect(x: s - d - o, y: o, width: d, height: d)
    paper.setFill(); NSBezierPath(ovalIn: disc).fill()
    ink.setStroke()
    let outer = NSBezierPath(ovalIn: disc.insetBy(dx: s * 0.006, dy: s * 0.006)); outer.lineWidth = s * 0.008; outer.stroke()
    let inner = NSBezierPath(ovalIn: disc.insetBy(dx: s * 0.022, dy: s * 0.022)); inner.lineWidth = s * 0.003; inner.stroke()
    let cfg = NSImage.SymbolConfiguration(pointSize: d * 0.42, weight: .light)
        .applying(.init(paletteColors: [ink]))
    if let book = NSImage(systemSymbolName: "book", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let b = book.size
        book.draw(in: NSRect(x: disc.midX - b.width / 2, y: disc.midY - b.height / 2, width: b.width, height: b.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PapersIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! render(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! render(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "PapersIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote PapersIcon.icns" : "iconutil failed")
