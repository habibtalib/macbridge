// Draws MacBridge's app icon and writes the icon set.
//   swift scripts/make-icon.swift            (run from the repo root)
// Two screens, the front one with a pointer: one Mac's screen on another, and in control of it.
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let u = size / 1024 // the design is drawn on a 1024 grid

    // macOS icon shape: 824 square, centred, with a soft shadow below.
    let plate = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(platePath)
    ctx.setFillColor(NSColor(srgbRed: 0.16, green: 0.25, blue: 0.80, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.36, green: 0.62, blue: 1.00, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.20, green: 0.30, blue: 0.86, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.24, green: 0.16, blue: 0.62, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    // A soft light from the top left.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330 * u, y: 800 * u), startRadius: 0,
                           endCenter: CGPoint(x: 330 * u, y: 800 * u), endRadius: 560 * u, options: [])
    ctx.restoreGState()

    func screen(_ rect: CGRect, radius: CGFloat, fill: NSColor, shadow: Bool) {
        ctx.saveGState()
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 30 * u, color: NSColor.black.withAlphaComponent(0.35).cgColor) }
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // The other Mac's screen, behind.
    screen(CGRect(x: 232 * u, y: 484 * u, width: 400 * u, height: 268 * u), radius: 40 * u,
           fill: NSColor.white.withAlphaComponent(0.38), shadow: false)
    // This Mac's view of it, in front.
    let front = CGRect(x: 360 * u, y: 286 * u, width: 440 * u, height: 296 * u)
    screen(front, radius: 44 * u, fill: .white, shadow: true)

    // The pointer on the front screen.
    let tip = CGPoint(x: front.minX + 150 * u, y: front.maxY - 62 * u)
    let pointer = CGMutablePath()
    let points: [(CGFloat, CGFloat)] = [(0, 0), (0, -176), (44, -134), (76, -206), (110, -190), (78, -120), (136, -120)]
    for (i, p) in points.enumerated() {
        let point = CGPoint(x: tip.x + p.0 * u, y: tip.y + p.1 * u)
        if i == 0 { pointer.move(to: point) } else { pointer.addLine(to: point) }
    }
    pointer.closeSubpath()
    ctx.saveGState()
    ctx.setLineJoin(.round)
    ctx.addPath(pointer)
    ctx.setFillColor(NSColor(srgbRed: 0.20, green: 0.30, blue: 0.86, alpha: 1).cgColor)
    ctx.setStrokeColor(NSColor(srgbRed: 0.20, green: 0.30, blue: 0.86, alpha: 1).cgColor)
    ctx.setLineWidth(14 * u)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let folder = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(to: folder.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) sizes to \(folder.path)")
