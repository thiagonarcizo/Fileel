import AppKit
import ImageIO

// immutable previews can safely cross the rendering actor boundary
struct ImagePreviewFrame: @unchecked Sendable {
    let original: CGImage
    let rendered: CGImage
    let dimensions: CGSize
}

// serialize preview work and reuse the decoded thumbnail instead of launching parallel GPU renders
actor ImagePreviewRenderer {
    private var loadedURL: URL?
    private var original: CGImage?
    private var automatic: CGImage?
    private var dimensions = CGSize.zero
    private(set) var sourceLoads = 0

    func render(url: URL, operation: FileOperation?, options: OperationOptions) throws -> ImagePreviewFrame {
        try Task.checkCancellation()
        if loadedURL != url || original == nil {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int,
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
               ] as CFDictionary) {
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                dimensions = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
                original = thumbnail
            } else {
                let image = try ImageEngine.load(url)
                dimensions = CGSize(width: image.width, height: image.height)
                var size = OperationOptions()
                if max(image.width, image.height) > 1600 {
                    if image.width >= image.height { size.width = 1600 } else { size.height = 1600 }
                }
                original = try ImageEngine.resized(image, options: size)
            }
            automatic = nil
            loadedURL = url
            sourceLoads += 1
        }
        try Task.checkCancellation()
        guard let original else { throw FileelError.message("The preview could not be loaded.") }
        let ratio = Double(original.width) / dimensions.width
        var scaled = options
        scaled.padding = Int(Double(options.padding) * ratio)
        scaled.cornerRadius = options.cornerRadius * ratio
        scaled.x = Int(Double(options.x) * ratio)
        scaled.y = Int(Double(options.y) * ratio)
        scaled.width = Int(Double(options.width) * ratio)
        scaled.height = Int(Double(options.height) * ratio)
        let rendered: CGImage
        switch operation {
        case .tool(.editImage):
            if options.autoAdjust, automatic == nil { automatic = try ImageEngine.autoAdjusted(original) }
            scaled.autoAdjust = false
            rendered = try ImageEngine.edit(options.autoAdjust ? automatic ?? original : original, tool: .editImage, options: scaled)
        case .tool(.background): rendered = try ImageEngine.edit(original, tool: .background, options: scaled)
        case .tool(.rotate): rendered = try ImageEngine.edit(original, tool: .rotate, options: scaled)
        case .tool(.annotateImage): rendered = try ImageDrawing.annotated(original, marks: options.annotations)
        case .tool(.redactImage): rendered = try ImageEngine.edit(original, tool: .redactImage, options: scaled)
        default: rendered = original
        }
        try Task.checkCancellation()
        return ImagePreviewFrame(original: original, rendered: rendered, dimensions: dimensions)
    }
}
