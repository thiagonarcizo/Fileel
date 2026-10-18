import AppKit
import ImageIO
import Vision
import XCTest
@testable import FileelCore

// sample exported pixels to verify that interactive coordinates match the saved image
final class ImageEditingTests: XCTestCase {
    var folder: URL!
    var source: URL!
    var image: CGImage!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-editor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        source = folder.appendingPathComponent("blue.png")
        let ctx = try ImageEngine.context(width: 400, height: 200)
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        image = ctx.makeImage()!
        try ImageEngine.write(image, to: source, options: .init())
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func color(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    func testCanvasAspectFitAndReverseDragCoordinates() {
        let rect = CanvasGeometry.imageRect(size: CGSize(width: 400, height: 200), in: CGRect(x: 0, y: 0, width: 1000, height: 700), inset: 20)
        XCTAssertEqual(rect, CGRect(x: 20, y: 110, width: 960, height: 480))
        XCTAssertEqual(CanvasGeometry.normalized(CGPoint(x: -50, y: -20), imageRect: rect), .zero)
        XCTAssertEqual(CanvasGeometry.normalized(CGPoint(x: 2000, y: 4000), imageRect: rect), CGPoint(x: 1, y: 1))
        let crop = CanvasGeometry.crop(from: CGPoint(x: 0.8, y: 0.9), to: CGPoint(x: 0.2, y: 0.1), imageSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(crop, CGRect(x: 80, y: 20, width: 240, height: 160))
    }

    func testCoverExportsAtTheTopLeftCoordinateSystem() throws {
        let originalBytes = try Data(contentsOf: source)
        var options = OperationOptions()
        options.detectFaces = false
        options.annotations = [.init(kind: .cover, startX: 0.1, startY: 0.1, endX: 0.4, endY: 0.3, hex: "FF0000")]
        let output = try ConversionEngine.perform(.tool(.redactImage), inputs: [source], options: options, runner: ProcessRunner())[0]
        let saved = try ImageEngine.load(output)
        XCTAssertGreaterThan(try color(saved, x: 80, y: 40).redComponent, 0.95)
        XCTAssertLessThan(try color(saved, x: 80, y: 40).blueComponent, 0.05)
        XCTAssertGreaterThan(try color(saved, x: 80, y: 160).blueComponent, 0.8)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    }

    func testEveryAnnotationProducesVisiblePixelsAndPreservesDimensions() throws {
        let baseline = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        for kind in ImageAnnotation.Kind.allCases where kind != .blur && kind != .pixelate {
            let mark = ImageAnnotation(kind: kind, startX: 0.2, startY: 0.2, endX: 0.7, endY: 0.7, text: kind == .number ? "2" : "Fileel", hex: "FF0000")
            let result = try ImageDrawing.annotated(image, marks: [mark])
            XCTAssertEqual(result.width, 400)
            XCTAssertEqual(result.height, 200)
            XCTAssertNotEqual(NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]), baseline, kind.rawValue)
        }
    }

    func testGradientAndRoundedBackgroundAreRenderedInTheExport() throws {
        var options = OperationOptions()
        options.backgroundSpacingPercent = 10
        options.cornerRadius = 60
        options.backgroundStyle = "gradient"
        options.backgroundHex = "FF0000"
        options.backgroundEndHex = "00FF00"
        let output = try ConversionEngine.perform(.tool(.background), inputs: [source], options: options, runner: ProcessRunner())[0]
        let result = try ImageEngine.load(output)
        XCTAssertEqual(result.width, 440)
        XCTAssertEqual(result.height, 240)
        XCTAssertGreaterThan(try color(result, x: 2, y: 2).redComponent, 0.8)
        XCTAssertGreaterThan(try color(result, x: 437, y: 237).greenComponent, 0.8)
        // the rounded corner exposes the backdrop instead of drawing a square source corner
        XCTAssertLessThan(try color(result, x: 21, y: 21).blueComponent, 0.1)
        XCTAssertGreaterThan(try color(result, x: 220, y: 120).blueComponent, 0.8)
    }

    func testImageBackgroundUsesAspectFill() throws {
        let ctx = try ImageEngine.context(width: 20, height: 20)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let backdrop = folder.appendingPathComponent("background.png")
        try ImageEngine.write(ctx.makeImage()!, to: backdrop, options: .init())
        var options = OperationOptions()
        options.backgroundStyle = "image"; options.backgroundImage = backdrop; options.backgroundSpacingPercent = 10
        let result = try ImageDrawing.background(image, options: options)
        XCTAssertGreaterThan(try color(result, x: 2, y: 2).redComponent, 0.95)
        XCTAssertGreaterThan(try color(result, x: 220, y: 120).blueComponent, 0.8)
    }

    // proportional frames keep all source pixels and use one equal margin on every side
    func testBackgroundSpacingUsesSixPercentOfTheShorterSideByDefault() throws {
        let options = OperationOptions()
        XCTAssertEqual(options.backgroundSpacingPercent, 6)
        for (width, height) in [(400, 200), (200, 400), (200, 200)] {
            let ctx = try ImageEngine.context(width: width, height: height)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let result = try ImageDrawing.background(XCTUnwrap(ctx.makeImage()), options: options)
            XCTAssertEqual(result.width, width + 24)
            XCTAssertEqual(result.height, height + 24)
            for (x, y) in [(11, height / 2 + 12), (width + 12, height / 2 + 12), (width / 2 + 12, 11), (width / 2 + 12, height + 12)] {
                XCTAssertGreaterThan(try color(result, x: x, y: y).redComponent, 0.95)
            }
            XCTAssertLessThan(try color(result, x: 12, y: 12).redComponent, 0.05)
            XCTAssertLessThan(try color(result, x: width + 11, y: height + 11).redComponent, 0.05)
        }
        var edge = options
        edge.backgroundSpacingPercent = 0
        XCTAssertEqual(try ImageDrawing.background(image, options: edge).width, 400)
        edge.backgroundSpacingPercent = 30
        XCTAssertEqual(try ImageDrawing.background(image, options: edge).width, 520)
        edge.backgroundSpacingPercent = .nan
        XCTAssertThrowsError(try ImageDrawing.background(image, options: edge))
    }

    // thumbnail rendering must keep the percentage rather than scaling it as a pixel count
    func testBackgroundPreviewAndExportHaveTheSameRelativeSpacing() async throws {
        let ctx = try ImageEngine.context(width: 4000, height: 3000)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let large = folder.appendingPathComponent("framed.png")
        try ImageEngine.write(XCTUnwrap(ctx.makeImage()), to: large, options: .init())
        let options = OperationOptions()
        let preview = try await ImagePreviewRenderer().render(url: large, operation: .tool(.background), options: options)
        let output = try ConversionEngine.perform(.tool(.background), inputs: [large], options: options, runner: ProcessRunner())[0]
        let saved = try ImageEngine.load(output)
        XCTAssertEqual(preview.rendered.width, 1744)
        XCTAssertEqual(preview.rendered.height, 1344)
        XCTAssertEqual(saved.width, 4360)
        XCTAssertEqual(saved.height, 3360)
        XCTAssertEqual(Double(preview.rendered.width) / Double(saved.width), 0.4, accuracy: 0.0001)
        XCTAssertGreaterThan(try color(preview.rendered, x: 71, y: 200).redComponent, 0.95)
        XCTAssertLessThan(try color(preview.rendered, x: 72, y: 200).redComponent, 0.05)
        XCTAssertGreaterThan(try color(saved, x: 179, y: 500).redComponent, 0.95)
        XCTAssertLessThan(try color(saved, x: 180, y: 500).redComponent, 0.05)
    }

    // asymmetric quadrants expose an unchanged preview or a mismatched flip direction
    func testRotationPreviewClipboardAndSavedPhotoAgreeForEveryAngleAndFlip() async throws {
        let ctx = try ImageEngine.context(width: 400, height: 200)
        for (rect, fill) in [
            (CGRect(x: 0, y: 0, width: 200, height: 100), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: 200, y: 0, width: 200, height: 100), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 100, width: 200, height: 100), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: 200, y: 100, width: 200, height: 100), CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        ] {
            ctx.setFillColor(fill); ctx.fill(rect)
        }
        let original = try XCTUnwrap(ctx.makeImage())
        let input = folder.appendingPathComponent("quadrants.png")
        try ImageEngine.write(original, to: input, options: .init())
        let renderer = ImagePreviewRenderer()
        for rotation in [0, 90, 180, 270] {
            for flip in [false, true] {
                var options = OperationOptions()
                options.rotation = rotation; options.flipHorizontal = flip
                let frame = try await renderer.render(url: input, operation: .tool(.rotate), options: options)
                let saved = try ImageEngine.load(ConversionEngine.perform(.tool(.rotate), inputs: [input], options: options, runner: ProcessRunner())[0])
                let copied = try ImageEngine.clipboardPNG([input], tool: .rotate, options: options)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(copied as CFData, nil))
                let clipboard = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let quarterTurn = rotation == 90 || rotation == 270
                XCTAssertEqual(frame.rendered.width, quarterTurn ? 200 : 400)
                XCTAssertEqual(frame.rendered.height, quarterTurn ? 400 : 200)
                for result in [frame.rendered, saved, clipboard] {
                    for x in [result.width / 4, result.width * 3 / 4] {
                        for y in [result.height / 4, result.height * 3 / 4] {
                            var point: (Int, Int)
                            switch rotation {
                            case 90: point = (y, 199 - x)
                            case 180: point = (399 - x, 199 - y)
                            case 270: point = (399 - y, x)
                            default: point = (x, y)
                            }
                            if flip { point.0 = 399 - point.0 }
                            let expected = try color(original, x: point.0, y: point.1)
                            let actual = try color(result, x: x, y: y)
                            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01, "\(rotation)°, flip \(flip)")
                            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01)
                            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.01)
                        }
                    }
                }
            }
        }
    }

    func testCollageUsesEveryImageAndRespectsGradientAndCornerRadius() throws {
        var options = OperationOptions()
        options.width = 100; options.height = 100; options.padding = 10; options.columns = 2
        options.backgroundStyle = "gradient"; options.backgroundHex = "FF0000"; options.backgroundEndHex = "00FF00"
        options.cornerRadius = 20
        let red = try ImageEngine.context(width: 100, height: 100)
        red.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        red.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let square = try ImageEngine.context(width: 100, height: 100)
        square.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        square.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let collage = try ImageEngine.collage([red.makeImage()!, square.makeImage()!], options: options)
        XCTAssertEqual(collage.width, 230); XCTAssertEqual(collage.height, 120)
        XCTAssertGreaterThan(try color(collage, x: 60, y: 60).redComponent, 0.95)
        XCTAssertGreaterThan(try color(collage, x: 170, y: 60).blueComponent, 0.95)
        XCTAssertLessThan(try color(collage, x: 121, y: 11).blueComponent, 0.05)
        XCTAssertGreaterThan(try color(collage, x: 228, y: 118).greenComponent, 0.8)
        XCTAssertThrowsError(try ImageEngine.collage([CGImage](), options: options))
    }

    func testFullImageDecodeDoesNotSilentlyShrinkWideOriginals() throws {
        let width = 17000
        let pixels = Data(repeating: 180, count: width * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let wide = try XCTUnwrap(CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = folder.appendingPathComponent("wide.png")
        try ImageEngine.write(wide, to: input, options: .init())
        XCTAssertEqual(try ImageEngine.load(input).width, width)
        XCTAssertEqual(try ImageEngine.load(input, maximumPixelSize: 200).width, 200)
    }

    func testOperationGroupMatchesTheGlobalMenuSelection() {
        XCTAssertEqual(FileOperation.convert("png").mode, .convert)
        XCTAssertEqual(FileOperation.tool(.cropImage).mode, .tools)
        XCTAssertEqual(FileOperation.action(.rename).mode, .actions)
    }

    func testIncompleteImageOperationLeavesNoOutput() throws {
        var options = OperationOptions()
        options.backgroundStyle = "image"
        XCTAssertThrowsError(try ConversionEngine.perform(.tool(.background), inputs: [source], options: options, runner: ProcessRunner()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["blue.png"])
        XCTAssertNotNil(OperationRequirements.issue(for: .tool(.cropImage), inputs: [source], options: .init()))
        XCTAssertNil(OperationRequirements.issue(for: .convert("jpg"), inputs: [source], options: .init()))
    }

    func testMetadataEditsPreserveCameraTagsAndCanRemoveLocation() throws {
        let original = folder.appendingPathComponent("camera.jpg")
        var tagged = OperationOptions()
        tagged.cameraMake = "Fixture Camera"
        tagged.cameraModel = "Test Model"
        tagged.lensModel = "Test Lens"
        tagged.title = "Original Title"
        tagged.latitude = "-22.5"
        tagged.longitude = "-47.1"
        try ImageEngine.write(image, to: original, options: tagged)
        var edit = OperationOptions(); edit.author = "New Author"
        let output = try ConversionEngine.perform(.tool(.metadata), inputs: [original], options: edit, runner: ProcessRunner())[0]
        func properties(_ url: URL) throws -> [CFString: Any] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        }
        let tags = try properties(output)
        let camera = try XCTUnwrap(tags[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(camera[kCGImagePropertyTIFFMake] as? String, "Fixture Camera")
        XCTAssertEqual(camera[kCGImagePropertyTIFFModel] as? String, "Test Model")
        XCTAssertEqual(camera[kCGImagePropertyTIFFArtist] as? String, "New Author")
        let gps = try XCTUnwrap(tags[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "S")
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitude] as? Double, 22.5)
        edit.removeLocation = true
        let stripped = try ConversionEngine.perform(.tool(.metadata), inputs: [output], options: edit, runner: ProcessRunner())[0]
        XCTAssertNil(try properties(stripped)[kCGImagePropertyGPSDictionary])
    }

    func testBlurDoesNotRestorePixelsUnderAnEarlierSolidCover() throws {
        let marks: [ImageAnnotation] = [
            .init(kind: .cover, startX: 0.1, startY: 0.1, endX: 0.9, endY: 0.9, hex: "000000"),
            .init(kind: .blur, startX: 0.3, startY: 0.3, endX: 0.7, endY: 0.7)
        ]
        let result = try ImageDrawing.annotated(image, marks: marks)
        XCTAssertLessThan(try color(result, x: 200, y: 100).blueComponent, 0.01)
        XCTAssertLessThan(try color(result, x: 200, y: 100).redComponent, 0.01)
    }
    func testRandomMosaicDoesNotDependOnCoveredSourcePixels() throws {
        let other = try ImageEngine.context(width: 400, height: 200)
        other.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        other.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let mark = ImageAnnotation(kind: .randomPixels, startX: 0.1, startY: 0.1, endX: 0.9, endY: 0.9, hex: "808080", seed: 42)
        let first = try ImageDrawing.annotated(image, marks: [mark])
        let second = try ImageDrawing.annotated(other.makeImage()!, marks: [mark])
        for y in stride(from: 25, to: 175, by: 11) {
            for x in stride(from: 45, to: 355, by: 11) {
                XCTAssertEqual(try color(first, x: x, y: y), try color(second, x: x, y: y))
                XCTAssertEqual(try color(first, x: x, y: y).alphaComponent, 1)
            }
        }
        XCTAssertNotEqual(try color(first, x: 5, y: 5), try color(second, x: 5, y: 5))
    }

    func testRedactionExportRemovesSourceLocationMetadata() throws {
        var tagged = OperationOptions(); tagged.latitude = "-22"; tagged.longitude = "-47"; tagged.author = "Original Author"
        let original = folder.appendingPathComponent("private.jpg")
        try ImageEngine.write(image, to: original, options: tagged)
        var edit = OperationOptions(); edit.detectFaces = false
        edit.annotations = [.init(kind: .randomPixels, startX: 0.1, startY: 0.1, endX: 0.9, endY: 0.9, seed: 42)]
        let result = try ConversionEngine.perform(.tool(.redactImage), inputs: [original], options: edit, runner: ProcessRunner())[0]
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(CGImageSourceGetCount(encoded), 1)
    }

    func testPreviewReusesTheDecodedSourceAcrossAdjustmentChanges() async throws {
        let renderer = ImagePreviewRenderer()
        let clock = ContinuousClock()
        var options = OperationOptions()
        _ = try await renderer.render(url: source, operation: .tool(.editImage), options: options)
        let start = clock.now
        for index in 0..<30 {
            options.exposure = Double(index) / 30
            let frame = try await renderer.render(url: source, operation: .tool(.editImage), options: options)
            XCTAssertEqual(frame.dimensions, CGSize(width: 400, height: 200))
            XCTAssertEqual(frame.rendered.width, 400)
        }
        let loads = await renderer.sourceLoads
        XCTAssertEqual(loads, 1)
        print("30 cached image adjustments: \(start.duration(to: clock.now))")
    }

    func testOCRReturnsClipboardTextWithoutCreatingAFile() throws {
        let ctx = try ImageEngine.context(width: 1200, height: 260)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 260))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "FILEEL OCR TEST", attributes: [.font: NSFont.systemFont(ofSize: 100), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 70, y: 75))
        NSGraphicsContext.restoreGraphicsState()
        let textImage = folder.appendingPathComponent("ocr.png")
        try ImageEngine.write(ctx.makeImage()!, to: textImage, options: .init())
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let result = try ConversionEngine.execute(.tool(.ocrImage), inputs: [textImage], options: .init(), runner: ProcessRunner())
        guard case .clipboard(let text) = result else { return XCTFail("OCR must return clipboard text") }
        XCTAssertTrue(text.contains("FILEEL OCR TEST"), text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before)
        let cpu = VNRecognizeTextRequest()
        cpu.recognitionLevel = .accurate
        cpu.automaticallyDetectsLanguage = true
        try VisionExecution.perform([cpu], handler: VNImageRequestHandler(cgImage: ImageEngine.load(textImage)), preferCPU: true)
        XCTAssertTrue((cpu.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").contains("FILEEL OCR TEST"))
    }

    func testLargeImagePreviewKeepsOriginalDimensionsAndDecodesOnlyOnce() async throws {
        let ctx = try ImageEngine.context(width: 4000, height: 3000)
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.24, blue: 0.38, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let large = folder.appendingPathComponent("large.jpg")
        try ImageEngine.write(ctx.makeImage()!, to: large, options: .init())
        let renderer = ImagePreviewRenderer()
        var options = OperationOptions()
        let initial = try await renderer.render(url: large, operation: .tool(.editImage), options: options)
        XCTAssertEqual(initial.dimensions, CGSize(width: 4000, height: 3000))
        XCTAssertEqual(initial.original.width, 1600)
        let clock = ContinuousClock(); let start = clock.now
        for step in 0..<20 {
            options.exposure = Double(step) / 20
            _ = try await renderer.render(url: large, operation: .tool(.editImage), options: options)
        }
        let loads = await renderer.sourceLoads
        XCTAssertEqual(loads, 1)
        print("20 cached 1600 px adjustments from a 12 MP source: \(start.duration(to: clock.now))")
    }

    func testClipboardImageContainsEditedPixelsWithoutAFileOrLocationMetadata() throws {
        var tagged = OperationOptions(); tagged.latitude = "-22"; tagged.longitude = "-47"
        let original = folder.appendingPathComponent("tagged.jpg")
        try ImageEngine.write(image, to: original, options: tagged)
        var options = OperationOptions()
        options.annotations = [.init(kind: .cover, startX: 0.1, startY: 0.1, endX: 0.5, endY: 0.5, hex: "FF0000")]
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let data = try ImageEngine.clipboardPNG([original], tool: .annotateImage, options: options)
        let encoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        XCTAssertEqual(result.width, 400)
        XCTAssertEqual(result.height, 200)
        XCTAssertGreaterThan(try color(result, x: 100, y: 40).redComponent, 0.95)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before)
    }

}
