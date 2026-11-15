import CoreGraphics
import CoreImage
import Foundation
import UniformTypeIdentifiers

// Headless-safe icon generator. Draws a white microphone on a blue gradient
// rounded square using a CoreGraphics bitmap context, then exports PNG via
// CGImageDestination. Needs no window server, so it works from a plain CLI.

func makeIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    // Background gradient.
    let colors = [
        CGColor(colorSpace: cs, components: [0.31, 0.56, 0.96, 1.0])!,
        CGColor(colorSpace: cs, components: [0.14, 0.34, 0.78, 1.0])!,
    ] as CFArray
    let locations: [CGFloat] = [0.0, 1.0]
    if let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: locations) {
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.14, 0.34, 0.78, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.saveGState()
        // Rounded clip so the gradient stays inside the squircle.
        let inset = s * 0.055
        let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let radius = rect.width * 0.2237
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
        ctx.restoreGState()
    }

    // Microphone, white.
    ctx.setFillColor(CGColor.white)
    ctx.setStrokeColor(CGColor.white)
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.022)

    let cx = s / 2
    // Mic head: vertical rounded rectangle (capsule).
    let headW = s * 0.26
    let headH = s * 0.40
    let headX = cx - headW / 2
    let headY = s * 0.40
    let head = CGPath(roundedRect: CGRect(x: headX, y: headY, width: headW, height: headH),
                      cornerWidth: headW / 2, cornerHeight: headW / 2, transform: nil)
    ctx.addPath(head)
    ctx.fillPath()

    // Cradle: a "U" hugging the lower part of the head.
    ctx.beginPath()
    let cradleR = s * 0.17
    let cradleCenter = CGPoint(x: cx, y: s * 0.44)
    let startAngle = CGFloat(-(100.0 * .pi / 180.0))
    let endAngle = CGFloat(100.0 * .pi / 180.0)
    ctx.addArc(center: cradleCenter, radius: cradleR, startAngle: startAngle, endAngle: endAngle, clockwise: false)
    ctx.strokePath()

    // Stem from cradle down to the base.
    ctx.beginPath()
    ctx.move(to: CGPoint(x: cx, y: s * 0.27))
    ctx.addLine(to: CGPoint(x: cx, y: s * 0.20))
    ctx.strokePath()

    // Base: short horizontal bar.
    let baseW = s * 0.16
    let base = CGPath(roundedRect: CGRect(x: cx - baseW / 2, y: s * 0.175, width: baseW, height: s * 0.022),
                      cornerWidth: s * 0.011, cornerHeight: s * 0.011, transform: nil)
    ctx.addPath(base)
    ctx.fillPath()

    guard let cgImage = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
if let data = makeIcon(size: 1024) {
    do {
        try data.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath) (\(data.count) bytes)")
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        exit(1)
    }
} else {
    FileHandle.standardError.write(Data("icon generation failed\n".utf8))
    exit(1)
}
