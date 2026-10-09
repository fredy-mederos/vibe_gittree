// Draws GitTree's app icon at every size macOS needs and writes the asset catalog entry.
// Usage: swift scripts/make-icon.swift GitTree/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws on a 1024-point canvas with y pointing down.
func drawIcon(in context: CGContext) {
    // macOS icon grid: an 824-point rounded square centred on the canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(color(0x101827).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        color(0x26365E).cgColor, color(0x111A30).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Faint row stripes, like the commit list.
    context.setFillColor(NSColor.white.withAlphaComponent(0.035).cgColor)
    var stripe: CGFloat = 100
    while stripe < 924 {
        context.fill(CGRect(x: 100, y: stripe, width: 824, height: 52))
        stripe += 104
    }

    let blue = color(0x3D8BFF), green = color(0x34D17A), pink = color(0xFF4F8B), amber = color(0xFFB340)
    let main: CGFloat = 470, left: CGFloat = 330, right: CGFloat = 640, far: CGFloat = 770
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(40)

    func stroke(_ path: CGMutablePath, _ lane: NSColor) {
        context.addPath(path)
        context.setStrokeColor(lane.cgColor)
        context.strokePath()
    }

    // Main line, top to bottom.
    let trunk = CGMutablePath()
    trunk.move(to: CGPoint(x: main, y: 170))
    trunk.addLine(to: CGPoint(x: main, y: 860))
    stroke(trunk, blue)

    // A feature branch that leaves the main line and merges back.
    let feature = CGMutablePath()
    feature.move(to: CGPoint(x: main, y: 740))
    feature.addCurve(to: CGPoint(x: left, y: 610), control1: CGPoint(x: main, y: 670), control2: CGPoint(x: left, y: 690))
    feature.addLine(to: CGPoint(x: left, y: 420))
    feature.addCurve(to: CGPoint(x: main, y: 290), control1: CGPoint(x: left, y: 340), control2: CGPoint(x: main, y: 360))
    stroke(feature, green)

    // An open branch heading up and to the right.
    let open = CGMutablePath()
    open.move(to: CGPoint(x: main, y: 560))
    open.addCurve(to: CGPoint(x: right, y: 430), control1: CGPoint(x: main, y: 490), control2: CGPoint(x: right, y: 510))
    open.addLine(to: CGPoint(x: right, y: 230))
    stroke(open, pink)

    let release = CGMutablePath()
    release.move(to: CGPoint(x: right, y: 430))
    release.addCurve(to: CGPoint(x: far, y: 320), control1: CGPoint(x: right, y: 370), control2: CGPoint(x: far, y: 390))
    release.addLine(to: CGPoint(x: far, y: 250))
    stroke(release, amber)

    func dot(_ x: CGFloat, _ y: CGFloat, _ lane: NSColor, hollow: Bool = false) {
        let r: CGFloat = 46
        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
        context.setFillColor(lane.cgColor)
        context.fillEllipse(in: rect)
        context.setFillColor(hollow ? color(0x16213B).cgColor : NSColor.white.withAlphaComponent(0.92).cgColor)
        context.fillEllipse(in: rect.insetBy(dx: 18, dy: 18))
    }
    dot(main, 290, blue, hollow: true)
    dot(main, 560, blue)
    dot(main, 740, blue)
    dot(left, 420, green)
    dot(left, 610, green)
    dot(right, 230, pink)
    dot(right, 430, pink)
    dot(far, 250, amber)

    // Top highlight for depth.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])
    context.restoreGState()

    context.addPath(shape)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    context.setLineWidth(3)
    context.strokePath()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let scale = CGFloat(size) / 1024
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)
    drawIcon(in: context)
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(size: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(output.path)")
