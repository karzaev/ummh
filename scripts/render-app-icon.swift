import AppKit
import Foundation

// Original vector artwork, rendered at every macOS icon size.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
    let context = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor(white: 0.96, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                 xRadius: 190, yRadius: 190).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor(white: 0.075, alpha: 1).setStroke()
    let body = NSBezierPath(roundedRect: NSRect(x: 416, y: 430, width: 192, height: 342),
                            xRadius: 96, yRadius: 96)
    body.lineWidth = 42
    body.stroke()
    let cradle = NSBezierPath()
    cradle.move(to: NSPoint(x: 320, y: 490))
    cradle.curve(to: NSPoint(x: 512, y: 300), controlPoint1: NSPoint(x: 320, y: 378),
                 controlPoint2: NSPoint(x: 398, y: 300))
    cradle.curve(to: NSPoint(x: 704, y: 490), controlPoint1: NSPoint(x: 626, y: 300),
                 controlPoint2: NSPoint(x: 704, y: 378))
    cradle.lineWidth = 42
    cradle.lineCapStyle = .round
    cradle.stroke()
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 512, y: 300))
    stem.line(to: NSPoint(x: 512, y: 230))
    stem.lineWidth = 42
    stem.lineCapStyle = .round
    stem.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let png = render(size * scale)
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        if size * scale == 1024 { try png.write(to: root.appendingPathComponent("resources/AppIcon.png")) }
    }
}
