// Development app icon, rendered from Apple's vector CPU symbol.
import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = destination.deletingLastPathComponent().appendingPathComponent("Kapitsa.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in 1...2 {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let ratio = CGFloat(pixels) / 1024
        let bounds = NSRect(x: 100 * ratio, y: 100 * ratio, width: 824 * ratio, height: 824 * ratio)
        let rounded = NSBezierPath(roundedRect: bounds, xRadius: 185 * ratio, yRadius: 185 * ratio)
        NSGradient(starting: NSColor(red: 0.18, green: 0.65, blue: 0.80, alpha: 1),
                   ending: NSColor(red: 0.15, green: 0.32, blue: 0.72, alpha: 1))!.draw(in: rounded, angle: -75)
        let symbol = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))
        symbol?.draw(in: NSRect(x: 280 * ratio, y: 280 * ratio, width: 464 * ratio, height: 464 * ratio))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconset)
