// Renders the layer artwork for images/Burrow.icon.
//
// Usage: swift images/burrow-icon/render.swift <output-directory>
//
// Each layer is a 1024x1024 transparent PNG on Icon Composer's canvas (the
// full canvas is the icon shape). The sky background is a gradient fill
// defined in Burrow.icon/icon.json rather than an image.

import AppKit
import CoreGraphics

let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

/// Draw into a 1024 canvas using top-left coordinates and write a PNG.
func render(_ path: String, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: Shapes

/// The mound the burrow is dug into.
func hillPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: -20, y: 640))
    p.addCurve(to: CGPoint(x: 512, y: 372), control1: CGPoint(x: 120, y: 470), control2: CGPoint(x: 300, y: 372))
    p.addCurve(to: CGPoint(x: 1044, y: 640), control1: CGPoint(x: 724, y: 372), control2: CGPoint(x: 904, y: 470))
    p.addLine(to: CGPoint(x: 1044, y: 1044))
    p.addLine(to: CGPoint(x: -20, y: 1044))
    p.closeSubpath()
    return p
}

/// Just the top edge of the hill, for the rim light.
func hillRimPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: -20, y: 640))
    p.addCurve(to: CGPoint(x: 512, y: 372), control1: CGPoint(x: 120, y: 470), control2: CGPoint(x: 300, y: 372))
    p.addCurve(to: CGPoint(x: 1044, y: 640), control1: CGPoint(x: 724, y: 372), control2: CGPoint(x: 904, y: 470))
    return p
}

/// An arch (semicircle on straight sides) standing on `base`, scaled about the base center.
func archPath(scale: CGFloat = 1, base: CGFloat = 872) -> CGPath {
    let halfWidth = 196 * scale
    let sideHeight = 170 * scale
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512 - halfWidth, y: base))
    p.addLine(to: CGPoint(x: 512 - halfWidth, y: base - sideHeight))
    p.addArc(center: CGPoint(x: 512, y: base - sideHeight), radius: halfWidth,
             startAngle: .pi, endAngle: 0, clockwise: false)
    p.addLine(to: CGPoint(x: 512 + halfWidth, y: base))
    p.closeSubpath()
    return p
}

// MARK: Layers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// Hill: dark soil with a mint rim light along the crest.
render("\(out)/Hill.png") { ctx in
    ctx.saveGState()
    ctx.addPath(hillPath())
    ctx.clip()
    linearGradient(ctx, [color(0x3D2644), color(0x24152B), color(0x170C1C)],
                   from: CGPoint(x: 0, y: 372), to: CGPoint(x: 0, y: 1024))
    ctx.restoreGState()

    // Soft glow under the rim, then the crisp rim line.
    ctx.saveGState()
    ctx.addPath(hillPath())
    ctx.clip()
    ctx.setShadow(offset: .zero, blur: 40, color: color(0x5BD678, 0.55))
    ctx.addPath(hillRimPath())
    ctx.setStrokeColor(color(0x5BD678, 0.9))
    ctx.setLineWidth(12)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

// Burrow: glowing entrance with receding rings for depth.
render("\(out)/Burrow.png") { ctx in
    // Light spilling onto the ground in front of the entrance.
    ctx.saveGState()
    let spill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [color(0xFFB347, 0.45), color(0xFFB347, 0)] as CFArray, locations: [0, 1])!
    ctx.translateBy(x: 512, y: 880)
    ctx.scaleBy(x: 1, y: 0.28)
    ctx.drawRadialGradient(spill, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 330, options: [])
    ctx.restoreGState()

    // Dark lip around the opening.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: color(0x000000, 0.5))
    ctx.addPath(archPath(scale: 1.12, base: 880))
    ctx.setFillColor(color(0x12080F))
    ctx.fillPath()
    ctx.restoreGState()

    // Glowing interior.
    ctx.saveGState()
    ctx.addPath(archPath())
    ctx.clip()
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [color(0xFFF1C4), color(0xFFC25A), color(0xEE6A2C), color(0x7A2418), color(0x2A0C0C)] as CFArray,
        locations: [0, 0.22, 0.52, 0.82, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 770), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 770), endRadius: 330, options: [.drawsAfterEndLocation])

    // Receding rings: the tunnel going deeper.
    for (scale, alpha) in [(0.80, 0.30), (0.60, 0.22), (0.42, 0.14)] {
        ctx.addPath(archPath(scale: scale, base: 872))
        ctx.setStrokeColor(color(0x5A1A10, alpha))
        ctx.setLineWidth(9)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

// Sky: a crescent moon and a few stars above the hill.
render("\(out)/Sky.png") { ctx in
    // Crescent: a disc with an offset disc cut out of it.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36, color: color(0xFFF1C4, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color(0xFFF1D0))
    ctx.fillEllipse(in: CGRect(x: 690, y: 150, width: 150, height: 150))
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: CGRect(x: 735, y: 122, width: 150, height: 150))
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (230, 190, 9, 0.9), (360, 120, 6, 0.7), (150, 330, 6, 0.6),
        (540, 220, 7, 0.75), (900, 360, 6, 0.6), (620, 110, 5, 0.55),
    ]
    for (x, y, r, a) in stars {
        ctx.setShadow(offset: .zero, blur: r * 2, color: color(0xFFFFFF, a * 0.8))
        ctx.setFillColor(color(0xFFFFFF, a))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
}

// Prompt: a `›_` silhouette inside the glow.
render("\(out)/Prompt.png") { ctx in
    ctx.setStrokeColor(color(0x2B1108))
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 436, y: 708))
    ctx.addLine(to: CGPoint(x: 492, y: 752))
    ctx.addLine(to: CGPoint(x: 436, y: 796))
    ctx.strokePath()

    ctx.setFillColor(color(0x2B1108))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 520, y: 781, width: 78, height: 28),
                       cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
}

print("rendered layers to \(out)")
