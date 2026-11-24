import AppKit

/// ClipCopy's mascot: a paperclip with a face. The same drawing makes the menu bar icon and the app icon.
enum Paperclip {
    /// The wire's centre line in a 100 × 100 box, y up. Four straight runs joined by three bends:
    /// an inner loop, a bottom bend and an outer loop.
    static func wire() -> CGPath {
        let outerLeft: CGFloat = 14, innerLeft: CGFloat = 32, innerRight: CGFloat = 68, outerRight: CGFloat = 86
        let path = CGMutablePath()
        path.move(to: CGPoint(x: innerLeft, y: 36))
        path.addLine(to: CGPoint(x: innerLeft, y: 62))
        path.addArc(center: CGPoint(x: (innerLeft + innerRight) / 2, y: 62), radius: (innerRight - innerLeft) / 2,
                    startAngle: .pi, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: innerRight, y: 28))
        path.addArc(center: CGPoint(x: (outerLeft + innerRight) / 2, y: 28), radius: (innerRight - outerLeft) / 2,
                    startAngle: 0, endAngle: -.pi, clockwise: true)
        path.addLine(to: CGPoint(x: outerLeft, y: 64))
        path.addArc(center: CGPoint(x: (outerLeft + outerRight) / 2, y: 64), radius: (outerRight - outerLeft) / 2,
                    startAngle: .pi, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: outerRight, y: 20))
        return path
    }

    static let leftEye = CGPoint(x: 43, y: 58)
    static let rightEye = CGPoint(x: 57, y: 58)

    /// A small smile under the eyes, inside the inner loop.
    static func smile() -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: 50, y: 50), radius: 7, startAngle: .pi * 1.18, endAngle: .pi * 1.82,
                    clockwise: false)
        return path
    }

    /// The menu bar icon: one colour, so macOS can tint it for light and dark menu bars.
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 15, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.height / 104
            context.translateBy(x: (rect.width - 100 * scale) / 2, y: 2 * scale)
            context.scaleBy(x: scale, y: scale)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            context.setLineWidth(8.5)
            context.addPath(wire())
            context.strokePath()

            for eye in [leftEye, rightEye] {
                context.fillEllipse(in: CGRect(x: eye.x - 4.2, y: eye.y - 4.2, width: 8.4, height: 8.4))
            }
            context.setLineWidth(5)
            context.addPath(smile())
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ClipCopy"
        return image
    }

    /// The full-colour app icon at `pixels` × `pixels`, as PNG.
    static func appIconPNG(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawAppIcon(in: context)
        return rep.representation(using: .png, properties: [:])
    }

    /// Draws the app icon on a 1024 × 1024 canvas.
    private static func drawAppIcon(in context: CGContext) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: srgb, components: [r, g, b, a])!
        }

        // The standard macOS icon tile: 824 on a 1024 canvas, with a soft shadow.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tileShape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.3))
        context.addPath(tileShape)
        context.setFillColor(color(0, 0, 0))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(tileShape)
        context.clip()
        let background = CGGradient(colorsSpace: srgb, colors: [
            color(0.36, 0.78, 0.96), color(0.40, 0.36, 0.92)
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        context.restoreGState()

        // The paperclip, tilted a little, filling most of the tile.
        context.saveGState()
        context.translateBy(x: 512, y: 500)
        context.rotate(by: -0.26)
        context.scaleBy(x: 7.2, y: 7.2)
        context.translateBy(x: -50, y: -52)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let wirePath = wire()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1.2), blur: 3, color: color(0.05, 0.05, 0.25, 0.35))
        context.setStrokeColor(color(0.55, 0.58, 0.66))
        context.setLineWidth(8)
        context.addPath(wirePath)
        context.strokePath()
        context.restoreGState()
        context.setStrokeColor(color(0.93, 0.95, 0.98))
        context.setLineWidth(5.6)
        context.addPath(wirePath)
        context.strokePath()
        context.setStrokeColor(color(1, 1, 1, 0.9))
        context.setLineWidth(1.6)
        context.saveGState()
        context.translateBy(x: -0.9, y: 0.9)
        context.addPath(wirePath)
        context.strokePath()
        context.restoreGState()

        // Face: dark eyes with a glint, rosy cheeks and a smile.
        context.setFillColor(color(1.0, 0.55, 0.62, 0.55))
        context.fillEllipse(in: CGRect(x: leftEye.x - 8.5, y: leftEye.y - 10.5, width: 7, height: 5))
        context.fillEllipse(in: CGRect(x: rightEye.x + 1.5, y: rightEye.y - 10.5, width: 7, height: 5))
        context.setFillColor(color(0.11, 0.12, 0.2))
        for eye in [leftEye, rightEye] {
            context.fillEllipse(in: CGRect(x: eye.x - 3.2, y: eye.y - 4, width: 6.4, height: 8))
        }
        context.setFillColor(color(1, 1, 1))
        for eye in [leftEye, rightEye] {
            context.fillEllipse(in: CGRect(x: eye.x - 0.4, y: eye.y + 0.8, width: 2.2, height: 2.2))
        }
        context.setStrokeColor(color(0.11, 0.12, 0.2))
        context.setLineWidth(2.2)
        context.addPath(smile())
        context.strokePath()
        context.restoreGState()
    }

    /// Writes an .iconset folder for `iconutil`.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try appIconPNG(pixels: points * scale)?.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
