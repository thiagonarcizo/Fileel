import AppKit
import CoreImage

// normalized coordinates keep marks in the same place at preview and export resolutions
struct ImageAnnotation: Identifiable, Sendable, Equatable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case arrow, rectangle, ellipse, text, number, cover, pixelate, randomPixels, blur
        var id: Self { self }
        var title: String {
            switch self {
            case .arrow: return "Arrow"
            case .rectangle: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .text: return "Text"
            case .number: return "Number"
            case .cover: return "Solid Cover"
            case .pixelate: return "Pixelate"
            case .randomPixels: return "Random Mosaic"
            case .blur: return "Blur"
            }
        }
        var symbol: String {
            switch self {
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .text: return "textformat"
            case .number: return "1.circle"
            case .cover: return "rectangle.fill"
            case .pixelate: return "square.grid.3x3.fill"
            case .randomPixels: return "dice.fill"
            case .blur: return "drop.halffull"
            }
        }
    }
    var id = UUID()
    var kind: Kind
    var startX: Double
    var startY: Double
    var endX: Double
    var endY: Double
    var text = ""
    var hex = "EF4444"
    var thickness = 0.006
    var fontScale = 0.05
    var seed = UInt64.random(in: 1...UInt64.max)
    var rect: CGRect {
        CGRect(x: min(startX, endX), y: min(startY, endY), width: abs(endX - startX), height: abs(endY - startY))
    }
}

// the same renderer is used for exported files and the live editing preview
enum ImageDrawing {
    static func annotated(_ image: CGImage, marks: [ImageAnnotation]) throws -> CGImage {
        let ctx = try ImageEngine.context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for mark in marks { try draw(mark, in: ctx, source: image) }
        return ctx.makeImage()!
    }

    static func draw(_ mark: ImageAnnotation, in ctx: CGContext, source: CGImage) throws {
        let width = CGFloat(ctx.width), height = CGFloat(ctx.height)
        let start = CGPoint(x: mark.startX * width, y: (1 - mark.startY) * height)
        let end = CGPoint(x: mark.endX * width, y: (1 - mark.endY) * height)
        let rect = CGRect(x: mark.rect.minX * width, y: (1 - mark.rect.maxY) * height, width: mark.rect.width * width, height: mark.rect.height * height)
        let lineWidth = max(1, mark.thickness * max(width, height))
        let color = ImageEngine.color(mark.hex)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch mark.kind {
        case .arrow:
            ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(lineWidth * 4, min(hypot(end.x - start.x, end.y - start.y) * 0.3, width * 0.045))
            ctx.move(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
            ctx.addLine(to: end)
            ctx.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
            ctx.strokePath()
        case .rectangle: ctx.stroke(rect)
        case .ellipse: ctx.strokeEllipse(in: rect)
        case .cover: ctx.fill(rect)
        case .pixelate:
            let ci = CIImage(cgImage: ctx.makeImage() ?? source)
            let pixels = ci.applyingFilter("CIPixellate", parameters: ["inputScale": max(10, width * 0.025)])
            if let result = ImageEngine.renderContext.createCGImage(pixels, from: ci.extent) {
                ctx.clip(to: rect)
                ctx.draw(result, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        case .randomPixels:
            // generate new opaque blocks without sampling any of the covered source pixels
            var random = MosaicRandom(state: mark.seed)
            let base = NSColor(cgColor: color)?.usingColorSpace(.sRGB) ?? .black
            let block = max(6, max(width, height) * 0.025)
            ctx.clip(to: rect)
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX
                while x < rect.maxX {
                    let brightness = 0.25 + random.next() * 0.65
                    let noise = random.next() * 0.18
                    ctx.setFillColor(CGColor(srgbRed: min(1, base.redComponent * brightness + noise),
                                            green: min(1, base.greenComponent * brightness + noise),
                                            blue: min(1, base.blueComponent * brightness + noise), alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: block, height: block))
                    x += block
                }
                y += block
            }
        case .blur:
            guard rect.width > 0, rect.height > 0 else { return }
            // clamp the blur input to avoid transparent edges in the covered region
            let ci = CIImage(cgImage: ctx.makeImage() ?? source)
            let blurred = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(12, width * 0.02)]).cropped(to: ci.extent)
            if let result = ImageEngine.renderContext.createCGImage(blurred, from: blurred.extent) {
                ctx.clip(to: rect)
                ctx.draw(result, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        case .text, .number:
            let size = max(12, mark.fontScale * max(width, height))
            var text = mark.text
            if mark.kind == .number {
                let radius = size * 0.68
                ctx.fillEllipse(in: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2))
                if text.isEmpty { text = "1" }
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: mark.kind == .number ? NSColor.white : NSColor(cgColor: color) ?? .labelColor
            ])
            let textSize = attributed.size()
            let origin = mark.kind == .number ? CGPoint(x: start.x - textSize.width / 2, y: start.y - textSize.height / 2) : CGPoint(x: start.x, y: start.y - textSize.height)
            attributed.draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func background(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        let padding = max(0, options.padding)
        let width = image.width + padding * 2, height = image.height + padding * 2
        let ctx = try ImageEngine.context(width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if options.backgroundStyle == "image", let url = options.backgroundImage {
            let backdrop = try ImageEngine.load(url)
            let scale = max(CGFloat(width) / CGFloat(backdrop.width), CGFloat(height) / CGFloat(backdrop.height))
            let w = CGFloat(backdrop.width) * scale, h = CGFloat(backdrop.height) * scale
            ctx.draw(backdrop, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        } else if options.backgroundStyle == "gradient" {
            let colors = [ImageEngine.color(options.backgroundHex), ImageEngine.color(options.backgroundEndHex)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        } else {
            ctx.setFillColor(ImageEngine.color(options.backgroundHex)); ctx.fill(bounds)
        }
        let imageRect = CGRect(x: padding, y: padding, width: image.width, height: image.height)
        let radius = min(options.cornerRadius, Double(min(image.width, image.height)) / 2)
        ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: max(0, radius), cornerHeight: max(0, radius), transform: nil))
        ctx.clip()
        ctx.draw(image, in: imageRect)
        return ctx.makeImage()!
    }
}

// a stable seed makes the random mosaic agree between preview and full-resolution export
private struct MosaicRandom {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Double(value ^ (value >> 31)) / Double(UInt64.max)
    }
}
