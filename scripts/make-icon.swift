// Genera AppIcon.icns: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit
let out = CommandLine.arguments[1]
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(px), inset = s * 0.1
        let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        NSGradient(starting: NSColor(red: 0.86, green: 0.2, blue: 0.16, alpha: 1), ending: NSColor(red: 0.6, green: 0.08, blue: 0.08, alpha: 1))!
            .draw(in: NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22), angle: -90)
        let font = NSFont.systemFont(ofSize: s * 0.34, weight: .heavy)
        let str = NSAttributedString(string: "MD", attributes: [.font: font, .foregroundColor: NSColor.white])
        let sz = str.size()
        str.draw(at: NSPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run(); p.waitUntilExit()
