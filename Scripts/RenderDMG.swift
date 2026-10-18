import AppKit

// draw the installer artwork at both display scales so finder keeps the typography crisp
@main
enum RenderDMG {
    static func main() throws {
        guard CommandLine.arguments.count == 4,
              ["stable", "beta"].contains(CommandLine.arguments[2]) else {
            throw NSError(domain: "FileelPackaging", code: 64)
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        let beta = CommandLine.arguments[2] == "beta"
        let version = CommandLine.arguments[3]
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let artwork = NSImage(size: NSSize(width: 720, height: 480))
        for scale in [1, 2] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720 * scale, pixelsHigh: 480 * scale,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            draw(beta: beta, version: version)
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = artwork.size
            artwork.addRepresentation(bitmap)
            if scale == 2 {
                try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("preview@2x.png"))
            }
        }
        try artwork.tiffRepresentation!.write(to: destination.appendingPathComponent("background.tiff"))
    }

    static func draw(beta: Bool, version: String) {
        let bounds = NSRect(x: 0, y: 0, width: 720, height: 480)
        let ink = NSColor(srgbRed: 0.18, green: 0.20, blue: 0.22, alpha: 1)
        let muted = NSColor(srgbRed: 0.40, green: 0.42, blue: 0.45, alpha: 1)
        NSGradient(colors: [.white, NSColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1)])!
            .draw(in: bounds, angle: -90)

        // a cropped ribbon quietly connects the installer to the app's own identity
        let mark = FileelIcon.image(size: 420, accent: NSColor(srgbRed: 0.74, green: 0.77, blue: 0.80, alpha: 1), tile: false)
        mark.draw(in: NSRect(x: 470, y: 185, width: 420, height: 420), from: .zero, operation: .sourceOver, fraction: 0.10)

        text("Fileel", at: NSPoint(x: 48, y: 421), font: .systemFont(ofSize: 17, weight: .semibold), color: ink)
        let badge = beta ? "BETA" : "FOR MAC"
        let badgeWidth: CGFloat = beta ? 53 : 76
        let badgeRect = NSRect(x: 720 - 48 - badgeWidth, y: 419, width: badgeWidth, height: 24)
        (beta ? NSColor(srgbRed: 0.98, green: 0.88, blue: 0.66, alpha: 1) : NSColor.black.withAlphaComponent(0.045)).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 12, yRadius: 12).fill()
        centered(badge, in: badgeRect.offsetBy(dx: 0, dy: 5), font: .systemFont(ofSize: 10, weight: .semibold), color: ink)

        let title = NSFont.systemFont(ofSize: 34, weight: .regular)
        let serif = NSFont(descriptor: title.fontDescriptor.withDesign(.serif)!, size: 34)!
        text("Every file, a little easier.", at: NSPoint(x: 48, y: 357), font: serif, color: ink)
        text(beta ? "A first look at what comes next." : "A few great tools. Right where your files are.",
             at: NSPoint(x: 49, y: 331), font: .systemFont(ofSize: 13), color: muted)

        // the actual app and applications icons are supplied by finder over these soft landing pads
        for x: CGFloat in [208, 512] {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.055)
            shadow.shadowBlurRadius = 26
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor.white.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 78, y: 155, width: 156, height: 156), xRadius: 34, yRadius: 34).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 341, y: 233))
        arrow.line(to: NSPoint(x: 379, y: 233))
        arrow.move(to: NSPoint(x: 371, y: 241))
        arrow.line(to: NSPoint(x: 379, y: 233))
        arrow.line(to: NSPoint(x: 371, y: 225))
        arrow.lineWidth = 1.5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        muted.withAlphaComponent(0.6).setStroke()
        arrow.stroke()

        centered("Drag Fileel to Applications to get started.", in: NSRect(x: 0, y: 87, width: 720, height: 20),
                 font: .systemFont(ofSize: 13), color: ink)
        let details = "\(version)\(beta ? " beta" : "")  ·  Apple silicon  ·  macOS 14 or later"
        centered(details, in: NSRect(x: 0, y: 37, width: 720, height: 18), font: .systemFont(ofSize: 10), color: muted)
    }

    static func text(_ value: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (value as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    static func centered(_ value: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (value as NSString).size(withAttributes: attributes).width
        (value as NSString).draw(at: NSPoint(x: rect.midX - width / 2, y: rect.minY), withAttributes: attributes)
    }
}
