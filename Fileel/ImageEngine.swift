import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

// use imageio for native formats and normalize orientation before editing pixels
enum ImageEngine {
    // CIContext is thread-safe and expensive to create, so previews and exports share one GPU context
    static let renderContext = CIContext(options: [.cacheIntermediates: false])
    static func load(_ url: URL, maximumPixelSize: Int? = nil) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let originalSize = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 16384,
                                   properties?[kCGImagePropertyPixelHeight] as? Int ?? 16384)
            // full exports keep their original dimensions while thumbnail callers choose an explicit limit
            let limit = maximumPixelSize.map { max(1, $0) } ?? originalSize
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit
            ] as CFDictionary) { return image }
        }
        // give vector inputs an explicit pixel canvas so a Retina display cannot double export dimensions
        guard let image = NSImage(contentsOf: url), image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else {
            throw FileelError.message("Cannot read \(url.lastPathComponent) as an image.")
        }
        let longestSide = max(image.size.width, image.size.height)
        let scale = maximumPixelSize.map { min(1, CGFloat(max(1, $0)) / longestSide) } ?? 1
        let width = (image.size.width * scale).rounded()
        let height = (image.size.height * scale).rounded()
        guard width <= 16384, height <= 16384 else {
            throw FileelError.message("Vector images can be rasterized up to 16384 pixels per side.")
        }
        let canvas = try context(width: max(1, Int(width)), height: max(1, Int(height)))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height),
                   from: .zero, operation: .copy, fraction: 1)
        guard let raster = canvas.makeImage() else { throw FileelError.message("Cannot rasterize \(url.lastPathComponent).") }
        return raster
    }

    static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FileelError.message("Choose dimensions between 1 and 16384 pixels.")
        }
        context.interpolationQuality = .high
        return context
    }

    static func write(_ image: CGImage, to url: URL, options: OperationOptions, source: URL? = nil) throws {
        if url.pathExtension == "pdf" {
            let pdf = PDFDocument()
            if let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) { pdf.insert(page, at: 0) }
            guard pdf.write(to: url) else { throw FileelError.message("Cannot write the PDF.") }
            return
        }
        guard let type = UTType(filenameExtension: url.pathExtension),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw FileelError.message("The native image encoder cannot write \(url.pathExtension.uppercased()).")
        }
        // the native AVIF writer rejects 1 as an unsupported lossless mode, so use its highest working quality
        let quality = url.pathExtension.lowercased() == "avif" && options.quality >= 1 ? 0.999 : options.quality
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if options.preserveMetadata, !options.stripMetadata, let source,
           let input = CGImageSourceCreateWithURL(source as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] {
            properties.merge(original) { current, _ in current }
        }
        // the pixel data is already oriented, so stale orientation tags must not rotate it again
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if !options.author.isEmpty { tiff[kCGImagePropertyTIFFArtist] = options.author }
        if !options.cameraMake.isEmpty { tiff[kCGImagePropertyTIFFMake] = options.cameraMake }
        if !options.cameraModel.isEmpty { tiff[kCGImagePropertyTIFFModel] = options.cameraModel }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = image.width
        exif[kCGImagePropertyExifPixelYDimension] = image.height
        if !options.lensModel.isEmpty { exif[kCGImagePropertyExifLensModel] = options.lensModel }
        properties[kCGImagePropertyExifDictionary] = exif
        if !options.title.isEmpty {
            var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            iptc[kCGImagePropertyIPTCObjectName] = options.title
            properties[kCGImagePropertyIPTCDictionary] = iptc
        }
        if options.removeLocation { properties.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        if !options.latitude.isEmpty || !options.longitude.isEmpty {
            guard let latitude = Double(options.latitude), let longitude = Double(options.longitude),
                  latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw FileelError.message("Enter latitude from −90 to 90 and longitude from −180 to 180.")
            }
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(latitude), kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(longitude), kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E"
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileelError.message("The \(url.pathExtension.uppercased()) encoder could not finish the file.") }
    }

    // replace descriptive metadata without recompressing supported single-frame images
    static func copyWithoutMetadata(_ input: URL, to output: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { return false }
        let metadata = CGImageMetadataCreateMutable()
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = properties[kCGImagePropertyOrientation] as? NSNumber {
            // orientation describes the encoded pixels and must survive removal of camera and location tags
            guard CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                kCGImagePropertyTIFFOrientation, orientation) else { return false }
        }
        let settings: [CFString: Any] = [kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false, kCGImageMetadataShouldExcludeGPS: true]
        let copied = CGImageDestinationCopyImageSource(destination, source, settings as CFDictionary, nil)
        if !copied { try? FileManager.default.removeItem(at: output) }
        return copied
    }

    static func supports(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else { return false }
        return (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type.identifier)
    }

    // clipboard images contain only flattened pixels, never the source file's metadata or hidden layers
    static func clipboardPNG(_ inputs: [URL], tool: FileTool, options: OperationOptions) throws -> Data {
        try Task.checkCancellation()
        guard let first = inputs.first else { throw FileelError.message("Choose an image first.") }
        let image = try tool == .collage ? collage(inputs, options: options) : edit(first, tool: tool, options: options)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FileelError.message("The image could not be prepared for copying.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileelError.message("The image could not be copied.") }
        try Task.checkCancellation()
        return data as Data
    }

    static func resized(_ image: CGImage, options: OperationOptions) throws -> CGImage {
        guard options.width > 0 || options.height > 0 else { return image }
        let width = options.width > 0 ? options.width : Int(Double(image.width) * Double(options.height) / Double(image.height))
        let height = options.height > 0 ? options.height : Int(Double(image.height) * Double(width) / Double(image.width))
        let ctx = try context(width: width, height: height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func edit(_ url: URL, tool: FileTool, options: OperationOptions) throws -> CGImage {
        try edit(load(url), tool: tool, options: options)
    }

    static func edit(_ original: CGImage, tool: FileTool, options: OperationOptions) throws -> CGImage {
        var image = original
        if tool == .rotate {
            let swapped = options.rotation == 90 || options.rotation == 270
            let ctx = try context(width: swapped ? original.height : original.width, height: swapped ? original.width : original.height)
            ctx.translateBy(x: CGFloat(ctx.width) / 2, y: CGFloat(ctx.height) / 2)
            ctx.rotate(by: -CGFloat(options.rotation) * .pi / 180)
            if options.flipHorizontal { ctx.scaleBy(x: -1, y: 1) }
            ctx.draw(original, in: CGRect(x: -CGFloat(original.width) / 2, y: -CGFloat(original.height) / 2,
                                         width: CGFloat(original.width), height: CGFloat(original.height)))
            return ctx.makeImage()!
        }
        if tool == .cropImage {
            let rect = try pixelRect(image, options: options)
            guard let cropped = image.cropping(to: rect) else { throw FileelError.message("The crop is outside the image.") }
            return cropped
        }
        if tool == .editImage {
            if options.autoAdjust { image = try autoAdjusted(image) }
            var ci = CIImage(cgImage: image).applyingFilter("CIExposureAdjust", parameters: ["inputEV": options.exposure])
            ci = ci.applyingFilter("CIColorControls", parameters: ["inputSaturation": options.saturation, "inputContrast": options.contrast, "inputBrightness": options.brightness])
            if options.vibrance != 0 { ci = ci.applyingFilter("CIVibrance", parameters: ["inputAmount": options.vibrance]) }
            if options.temperature != 6500 || options.tint != 0 {
                ci = ci.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: options.temperature, y: options.tint)])
            }
            if options.highlights != 1 || options.shadows != 0 {
                ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": options.highlights, "inputShadowAmount": options.shadows])
            }
            if options.sharpness != 0 { ci = ci.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": options.sharpness]) }
            guard let result = renderContext.createCGImage(ci, from: ci.extent) else { throw FileelError.message("Cannot render the adjustments.") }
            image = result
        }
        if tool == .redactImage {
            let ctx = try context(width: image.width, height: image.height)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            func cover(_ rect: CGRect) throws {
                let mark = ImageAnnotation(kind: options.redactionKind, startX: rect.minX / CGFloat(image.width), startY: rect.minY / CGFloat(image.height),
                                           endX: rect.maxX / CGFloat(image.width), endY: rect.maxY / CGFloat(image.height), hex: options.redactionHex, seed: 921)
                try ImageDrawing.draw(mark, in: ctx, source: image)
            }
            if options.width > 0 && options.height > 0 { try cover(pixelRect(image, options: options)) }
            // face and text detection run entirely on the mac
            var requests: [VNRequest] = []
            let faces = VNDetectFaceRectanglesRequest()
            let text = VNRecognizeTextRequest()
            if options.detectFaces { requests.append(faces) }
            if options.detectText { requests.append(text) }
            if !requests.isEmpty { try VisionExecution.perform(requests, handler: VNImageRequestHandler(cgImage: image)) }
            let boxes = (faces.results ?? []).map(\.boundingBox) + (text.results ?? []).map(\.boundingBox)
            for box in boxes {
                let rect = CGRect(x: box.minX * CGFloat(image.width), y: box.minY * CGFloat(image.height),
                                  width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
                let expanded = rect.insetBy(dx: -4, dy: -4)
                try cover(CGRect(x: expanded.minX, y: CGFloat(image.height) - expanded.maxY, width: expanded.width, height: expanded.height))
            }
            return try ImageDrawing.annotated(ctx.makeImage()!, marks: options.annotations)
        }
        if tool == .background {
            return try ImageDrawing.background(image, options: options)
        }
        if tool == .annotateImage {
            guard !options.annotations.isEmpty else { throw FileelError.message("Add a mark on the preview before saving.") }
            return try ImageDrawing.annotated(image, marks: options.annotations)
        }
        return try resized(image, options: options)
    }

    // native automatic enhancement estimates tone and color from the image content
    static func autoAdjusted(_ image: CGImage) throws -> CGImage {
        var ci = CIImage(cgImage: image)
        let extent = ci.extent
        for filter in ci.autoAdjustmentFilters(options: [.enhance: true, .redEye: false]) {
            filter.setValue(ci, forKey: kCIInputImageKey)
            if let output = filter.outputImage { ci = output }
        }
        guard let result = renderContext.createCGImage(ci, from: extent) else { throw FileelError.message("Automatic adjustment could not finish.") }
        return result
    }

    static func pixelRect(_ image: CGImage, options: OperationOptions) throws -> CGRect {
        let rect = CGRect(x: options.x, y: options.y, width: options.width, height: options.height)
        guard rect.width > 0, rect.height > 0,
              CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(rect) else {
            throw FileelError.message("Choose a crop or redaction rectangle within the image, using pixel coordinates from its top-left corner.")
        }
        return rect
    }

    static func collage(_ urls: [URL], options: OperationOptions) throws -> CGImage {
        let limit = max(options.width > 0 ? options.width : 800, options.height > 0 ? options.height : 800)
        guard limit <= 16384 else { throw FileelError.message("Choose collage cells up to 16384 pixels.") }
        // a cell never needs a full camera-sized decode when its output is only a thumbnail
        return try collage(urls.map { try load($0, maximumPixelSize: limit) }, options: options)
    }

    static func collage(_ images: [CGImage], options: OperationOptions) throws -> CGImage {
        guard !images.isEmpty else { throw FileelError.message("Choose images for the collage.") }
        let columns = min(max(1, options.columns), images.count)
        let rows = (images.count + columns - 1) / columns
        let cellWidth = options.width > 0 ? options.width : 800
        let cellHeight = options.height > 0 ? options.height : 800
        let gap = max(0, options.padding)
        let ctx = try context(width: columns * cellWidth + (columns + 1) * gap, height: rows * cellHeight + (rows + 1) * gap)
        try ImageDrawing.paintBackground(in: ctx, bounds: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height), options: options)
        for (index, image) in images.enumerated() {
            let scale = min(Double(cellWidth) / Double(image.width), Double(cellHeight) / Double(image.height))
            let w = Double(image.width) * scale, h = Double(image.height) * scale
            let x = Double(gap + (index % columns) * (cellWidth + gap)) + (Double(cellWidth) - w) / 2
            let y = Double(ctx.height - gap - (index / columns + 1) * cellHeight - (index / columns) * gap) + (Double(cellHeight) - h) / 2
            let bounds = CGRect(x: x, y: y, width: w, height: h)
            let radius = min(max(0, options.cornerRadius), min(w, h) / 2)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            ctx.draw(image, in: bounds)
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    static func color(_ hex: String) -> CGColor {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0xFFFFFF
        return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
