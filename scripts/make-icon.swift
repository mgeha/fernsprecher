// Draw the app icon (own artwork, no third-party assets) and build
// Resources/Fernsprecher.icns. Run after changing the design:
//   swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824 pt body, centred, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.3).cgColor)
    cg.addPath(shape)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.36, green: 0.62, blue: 0.96, alpha: 1).cgColor,
        NSColor(red: 0.10, green: 0.33, blue: 0.78, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()

    // Handset: a C-shaped grip with ear and mouth pieces, drawn upright with
    // the grip bulging left, then turned 45° into the classic diagonal.
    cg.saveGState()
    cg.translateBy(x: 492, y: 500)
    cg.rotate(by: .pi / 4)
    // One layer, so the shadow falls from the whole handset, not each part.
    cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor(white: 0, alpha: 0.25).cgColor)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    cg.setFillColor(NSColor.white.cgColor)
    cg.setStrokeColor(NSColor.white.cgColor)

    let handset = CGMutablePath()
    // Grip: thick arc whose centre lies to the right of the handset axis.
    let radius: CGFloat = 250
    let centre = CGPoint(x: 140, y: 0)
    let span: CGFloat = 0.62 * .pi   // total angle of the grip
    handset.addArc(center: centre, radius: radius, startAngle: .pi - span / 2, endAngle: .pi + span / 2,
                   clockwise: false)
    let grip = handset.copy(strokingWithWidth: 96, lineCap: .round, lineJoin: .round, miterLimit: 10)
    cg.addPath(grip)
    cg.fillPath()

    // Ear and mouth pieces at both ends, facing inwards; their outer edge is
    // flush with the outside of the grip.
    for sign in [CGFloat(1), -1] {
        let angle = CGFloat.pi - sign * span / 2
        let end = CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        cg.saveGState()
        cg.translateBy(x: end.x, y: end.y)
        cg.rotate(by: angle)
        let cup = CGRect(x: -104, y: -108, width: 152, height: 216)
        cg.addPath(CGPath(roundedRect: cup, cornerWidth: 58, cornerHeight: 58, transform: nil))
        cg.fillPath()
        cg.restoreGState()
    }
    cg.endTransparencyLayer()
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func scaled(_ rep: NSBitmapImageRep, to pixels: Int) -> Data {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current!.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return out.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("..")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Fernsprecher.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = render()
for points in [16, 32, 128, 256, 512] {
    try scaled(master, to: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try scaled(master, to: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let icns = root.appendingPathComponent("Resources/Fernsprecher.icns").standardizedFileURL
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(icns.path)")
if CommandLine.arguments.count > 1 {   // optional: also save the 1024 px master for review
    try master.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
