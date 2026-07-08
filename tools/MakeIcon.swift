import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// Renders a 1024×1024 Cthugha app icon: a dark body with a fiery swirl and an
// oscilloscope wave — evoking the feedback-flame visualizer.

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("context")
}

func fire(_ u: Double) -> (CGFloat, CGFloat, CGFloat) {
    let stops: [(Double, Double, Double, Double)] = [
        (0.0, 0.05, 0.0, 0.02), (0.25, 0.6, 0.05, 0.0), (0.55, 1.0, 0.35, 0.0),
        (0.8, 1.0, 0.85, 0.2), (1.0, 1.0, 1.0, 0.92)
    ]
    let t = min(max(u, 0), 1)
    var a = stops[0], b = stops[stops.count - 1]
    for i in 0..<(stops.count - 1) where t >= stops[i].0 && t <= stops[i + 1].0 {
        a = stops[i]; b = stops[i + 1]; break
    }
    let k = (t - a.0) / max(b.0 - a.0, 1e-6)
    return (CGFloat(a.1 + (b.1 - a.1) * k),
            CGFloat(a.2 + (b.2 - a.2) * k),
            CGFloat(a.3 + (b.3 - a.3) * k))
}

let full = CGFloat(size)
let inset: CGFloat = 96
let body = CGRect(x: inset, y: inset, width: full - 2 * inset, height: full - 2 * inset)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 200, cornerHeight: 200, transform: nil)

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()

// Deep background gradient.
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.04, green: 0.02, blue: 0.10, alpha: 1),
    CGColor(red: 0.01, green: 0.00, blue: 0.02, alpha: 1)] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 620, options: [])

// Central fire glow.
let core = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1, green: 0.95, blue: 0.7, alpha: 0.95),
    CGColor(red: 1, green: 0.5, blue: 0.05, alpha: 0.55),
    CGColor(red: 0.6, green: 0.1, blue: 0.0, alpha: 0.0)] as CFArray,
    locations: [0, 0.4, 1])!
ctx.setBlendMode(.plusLighter)
ctx.drawRadialGradient(core, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 430, options: [])

// Fiery logarithmic spiral of glowing dots.
let turns = 5.0
let count = 1500
for i in 0..<count {
    let t = Double(i) / Double(count)
    let angle = t * .pi * 2 * turns
    let radius = 30.0 + t * 400.0
    let x = 512.0 + cos(angle) * radius
    let y = 512.0 + sin(angle) * radius
    let c = fire(1.0 - t)
    let dot = 3.0 + (1.0 - t) * 7.0
    ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.55))
    ctx.fillEllipse(in: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
}

// Oscilloscope wave across the middle.
ctx.setLineWidth(10)
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(red: 0.2, green: 1.0, blue: 0.9, alpha: 0.9))
ctx.setShadow(offset: .zero, blur: 22,
              color: CGColor(red: 0.2, green: 1.0, blue: 0.9, alpha: 0.9))
let wave = CGMutablePath()
for px in stride(from: 140, through: 884, by: 2) {
    let fx = Double(px)
    let env = sin((fx - 140) / 744.0 * .pi)
    let y = 512.0 + (sin(fx * 0.028) * 0.7 + sin(fx * 0.061 + 1.0) * 0.3) * 150.0 * env
    if px == 140 { wave.move(to: CGPoint(x: fx, y: y)) }
    else { wave.addLine(to: CGPoint(x: fx, y: y)) }
}
ctx.addPath(wave)
ctx.strokePath()
ctx.restoreGState()

// Subtle rim highlight.
ctx.setBlendMode(.normal)
ctx.addPath(bodyPath)
ctx.setLineWidth(4)
ctx.setStrokeColor(CGColor(red: 1, green: 0.6, blue: 0.2, alpha: 0.25))
ctx.strokePath()

guard let image = ctx.makeImage() else { fatalError("image") }
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("dest")
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
