// Draws the app icon: flat amber ledge with a page resting on it, on a dark square.
// swift scripts/make-icon.swift Ledge/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func png(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c: NSColor) {
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: h * s), xRadius: r * s, yRadius: r * s).fill()
    }
    box(94, 94, 836, 836, 184, NSColor(white: 0.31, alpha: 1))
    box(102, 102, 820, 820, 176, NSColor(srgbRed: 0.10, green: 0.105, blue: 0.12, alpha: 1))
    for (index, angle) in [-13.0, -4.0, 6.0].enumerated() {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by: (448 + CGFloat(index * 44)) * s, yBy: (545 + CGFloat(index * 4)) * s); transform.rotate(byDegrees: angle); transform.concat()
        box(-154, -158, 308, 316, 27, NSColor(white: [0.43, 0.63, 0.92][index], alpha: 1))
        if index == 2 { box(-118, -114, 104, 23, 8, NSColor(white: 0.32, alpha: 1)) }
        NSGraphicsContext.restoreGraphicsState()
    }
    box(215, 258, 594, 91, 31, NSColor(white: 0.23, alpha: 1))
    box(215, 322, 594, 27, 12, NSColor(srgbRed: 224/255, green: 160/255, blue: 48/255, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! png(pt * scale).write(to: out.appendingPathComponent(name))
    images.append("{ \"filename\": \"\(name)\", \"idiom\": \"mac\", \"scale\": \"\(scale)x\", \"size\": \"\(pt)x\(pt)\" }")
}
try! "{ \"images\": [\(images.joined(separator: ",\n"))], \"info\": { \"author\": \"xcode\", \"version\": 1 } }".write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
