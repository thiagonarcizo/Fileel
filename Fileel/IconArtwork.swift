import AppKit

// keep the folded ribbon geometry shared by the dock asset and the in-app mark
// coordinates use a 1024 pt canvas with the origin at the bottom left
nonisolated enum FileelIcon {
    static var silhouette: NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 324, y: 274))
        p.curve(to: NSPoint(x: 346, y: 252), controlPoint1: NSPoint(x: 324, y: 262), controlPoint2: NSPoint(x: 334, y: 252))
        p.line(to: NSPoint(x: 444, y: 252))
        p.curve(to: NSPoint(x: 466, y: 274), controlPoint1: NSPoint(x: 456, y: 252), controlPoint2: NSPoint(x: 466, y: 262))
        p.line(to: NSPoint(x: 466, y: 452))
        p.line(to: NSPoint(x: 637, y: 452))
        p.line(to: NSPoint(x: 708, y: 570))
        p.line(to: NSPoint(x: 466, y: 570))
        p.line(to: NSPoint(x: 466, y: 652))
        p.line(to: NSPoint(x: 709, y: 652))
        p.line(to: NSPoint(x: 780, y: 770))
        p.line(to: NSPoint(x: 352, y: 770))
        p.curve(to: NSPoint(x: 324, y: 742), controlPoint1: NSPoint(x: 337, y: 770), controlPoint2: NSPoint(x: 324, y: 757))
        p.close()
        return p
    }

    static var returns: NSBezierPath {
        let path = polygon([(709, 652), (780, 770), (780, 673), (752, 632)])
        path.append(polygon([(637, 452), (708, 570), (708, 474), (680, 432)]))
        return path
    }

    // a template image lets the menu bar choose its own contrast and appearance
    static var menuBarImage: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let scale = AffineTransform(scaleByX: 14 / 456, byY: 16 / 518)
            let path = silhouette
            path.transform(using: scale)
            let offset = AffineTransform(translationByX: 2 - 324 * 14 / 456, byY: 1 - 252 * 16 / 518)
            path.transform(using: offset)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // render legacy assets while the layered icon follows the system appearance
    static func image(size: Int, accent: NSColor? = nil, tile: Bool = true) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        context.setShouldAntialias(true)
        let ink = accent?.usingColorSpace(.sRGB) ?? color(0.31, 0.35, 0.39)
        if tile { drawTile() }
        drawRibbon(ink: ink, shadow: tile)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(bitmap)
        return image
    }

    // a quiet porcelain surface gives the folded color room to breathe
    private static func drawTile() {
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 198, yRadius: 198)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -9)
        shadow.set()
        color(0.94, 0.945, 0.95).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        gradient([color(0.90, 0.915, 0.93), color(0.975, 0.98, 0.985), color(0.995, 0.995, 0.995)])
            .draw(in: tile, angle: 90)
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        let rim = NSBezierPath(roundedRect: NSRect(x: 67, y: 67, width: 890, height: 890), xRadius: 195, yRadius: 195)
        rim.lineWidth = 3
        NSColor.white.withAlphaComponent(0.8).setStroke()
        rim.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawRibbon(ink: NSColor, shadow: Bool) {
        let shape = silhouette
        if shadow {
            NSGraphicsContext.saveGraphicsState()
            let cast = NSShadow()
            cast.shadowColor = NSColor.black.withAlphaComponent(0.21)
            cast.shadowOffset = NSSize(width: 0, height: -17)
            cast.shadowBlurRadius = 22
            cast.set()
            ink.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        gradient([ink.blended(withFraction: 0.24, of: .black)!, ink, ink.blended(withFraction: 0.18, of: .white)!])
            .draw(in: shape, angle: 90)

        // broad faces carry the light while the narrow returns describe the fold
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        gradient([ink, ink.blended(withFraction: 0.32, of: .white)!])
            .draw(in: NSRect(x: 300, y: 652, width: 500, height: 118), angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        let middle = polygon([(466, 452), (637, 452), (708, 570), (466, 570)])
        gradient([ink.blended(withFraction: 0.08, of: .black)!, ink.blended(withFraction: 0.22, of: .white)!])
            .draw(in: middle, angle: 90)
        let topReturn = polygon([(709, 652), (780, 770), (780, 673), (752, 632)])
        let midReturn = polygon([(637, 452), (708, 570), (708, 474), (680, 432)])
        for face in [topReturn, midReturn] {
            gradient([ink.blended(withFraction: 0.46, of: .black)!, ink.blended(withFraction: 0.08, of: .white)!])
                .draw(in: face, angle: 20)
        }
        let crease = NSBezierPath()
        crease.move(to: NSPoint(x: 709, y: 652))
        crease.line(to: NSPoint(x: 780, y: 770))
        crease.move(to: NSPoint(x: 637, y: 452))
        crease.line(to: NSPoint(x: 708, y: 570))
        crease.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.40).setStroke()
        crease.stroke()
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            if index == 0 { path.move(to: NSPoint(x: point.0, y: point.1)) }
            else { path.line(to: NSPoint(x: point.0, y: point.1)) }
        }
        path.close()
        return path
    }

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func gradient(_ colors: [NSColor]) -> NSGradient {
        NSGradient(colors: colors)!
    }
}
