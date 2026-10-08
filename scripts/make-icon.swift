import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = folder.appendingPathComponent("GlassBridge.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
] {
    let pixels = points * scale
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 25
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    let shape = NSBezierPath(
        roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
    NSGradient(colors: [
        NSColor(red: 0.12, green: 0.31, blue: 0.70, alpha: 1),
        NSColor(red: 0.34, green: 0.70, blue: 0.91, alpha: 1),
    ])!.draw(in: shape, angle: 75)
    NSShadow().set()
    let shine = NSBezierPath(
        roundedRect: NSRect(x: 87, y: 87, width: 850, height: 850), xRadius: 182, yRadius: 182)
    NSColor.white.withAlphaComponent(0.35).setStroke()
    shine.lineWidth = 3
    shine.stroke()
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .light)
    let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.withAlphaComponent(0.94).setFill()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(x: 230, y: 320, width: 564, height: 380))
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    try bitmap.representation(using: .png, properties: [:])!.write(
        to: iconset.appendingPathComponent(name))
}

// PNG-backed ICNS avoids the external image conversion service.
var chunks = Data()
let representations = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png"),
]
func bigEndian(_ number: UInt32) -> Data {
    var value = number.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
for (type, filename) in representations {
    let png = try Data(contentsOf: iconset.appendingPathComponent(filename))
    chunks.append(Data(type.utf8))
    chunks.append(bigEndian(UInt32(png.count + 8)))
    chunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(UInt32(chunks.count + 8)))
icns.append(chunks)
try icns.write(to: folder.appendingPathComponent("GlassBridge.icns"))
try FileManager.default.removeItem(at: iconset)
