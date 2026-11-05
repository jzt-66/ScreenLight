import AppKit

let root = CommandLine.arguments[1]
let manager = FileManager.default
try manager.createDirectory(atPath: root, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: Double(size) / 1024, y: Double(size) / 1024)
    let shape = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840), xRadius: 190, yRadius: 190)
    NSGradient(starting: NSColor(red: 1, green: 0.76, blue: 0.34, alpha: 1),
               ending: NSColor(red: 0.96, green: 0.48, blue: 0.13, alpha: 1))!.draw(in: shape, angle: -70)
    NSColor.white.setStroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 404, y: 404, width: 216, height: 216)).fill()
    for ray in 0..<12 {
        let angle = Double(ray) * Double.pi / 6
        let line = NSBezierPath()
        line.lineWidth = 29
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: 512 + cos(angle) * 173, y: 512 + sin(angle) * 173))
        line.line(to: NSPoint(x: 512 + cos(angle) * 235, y: 512 + sin(angle) * 235))
        line.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: root).appendingPathComponent(name))
}
