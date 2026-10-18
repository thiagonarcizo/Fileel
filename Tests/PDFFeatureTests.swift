import AppKit
import CoreText
import CryptoKit
import PDFKit
import XCTest
@testable import FileelCore

// check saved page content and geometry rather than just trusting thumbnail state
final class PDFFeatureTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-pdf-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func fixture(photograph: Bool = false) throws -> URL {
        let input = folder.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 240, height: 320)
        let context = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &box, nil))
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            if photograph {
                var random: UInt32 = 8317
                var pixels = [UInt8](repeating: 255, count: 900 * 1200 * 4)
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    for channel in 0..<3 {
                        random = random &* 1664525 &+ 1013904223
                        pixels[offset + channel] = UInt8(truncatingIfNeeded: random >> 24)
                    }
                }
                let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
                let image = try XCTUnwrap(CGImage(width: 900, height: 1200, bitsPerComponent: 8, bitsPerPixel: 32,
                                                bytesPerRow: 3600, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
                context.draw(image, in: box)
            }
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 15, y: 265, width: 35, height: 35))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 175, y: 20, width: 45, height: 25))
            let text = NSAttributedString(string: "fileel page \(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 20, y: 180)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        return input
    }

    func digest(_ url: URL) throws -> SHA256.Digest { SHA256.hash(data: try Data(contentsOf: url)) }

    func testOrganizerSavesOrderDuplicatesAndIndependentRotations() throws {
        let source = try fixture()
        let original = try digest(source)
        var options = OperationOptions()
        options.pdfPages = [PDFPageEdit(sourceIndex: 2, rotation: 90), PDFPageEdit(sourceIndex: 0),
                            PDFPageEdit(sourceIndex: 2, rotation: 270)]
        let output = folder.appendingPathComponent("organized.pdf")
        try PDFEngine.process(source, tool: .organizePDF, output: output, options: options, runner: ProcessRunner())
        let document = try PDFEngine.load(output)
        XCTAssertEqual(document.pageCount, 3)
        for (index, sourceNumber) in [3, 1, 3].enumerated() {
            XCTAssertTrue(document.page(at: index)?.string?.contains("fileel page \(sourceNumber)") == true)
        }
        XCTAssertEqual(document.page(at: 0)?.rotation, 90)
        XCTAssertEqual(document.page(at: 1)?.rotation, 0)
        XCTAssertEqual(document.page(at: 2)?.rotation, 270)
        XCTAssertEqual(try digest(source), original)
    }

    func testOrganizerMovesSelectionsAsAStableBlock() {
        let pages = (0..<5).map { PDFPageEdit(sourceIndex: $0) }
        let moved = PDFPageLayout.moving(pages, ids: [pages[0].id, pages[2].id], over: pages[4].id)
        XCTAssertEqual(moved.map(\.sourceIndex), [1, 3, 4, 0, 2])
        XCTAssertEqual(Set(moved.map(\.id)), Set(pages.map(\.id)))
        XCTAssertEqual(PDFPageLayout.moving(pages, ids: [pages[0].id], over: pages[0].id), pages)
        let duplicate = PDFPageEdit(sourceIndex: 0)
        XCTAssertNotEqual(duplicate.id, pages[0].id)
    }

    func testWatermarkPreservesTextAndDisplayedPageSizeForEveryRotation() throws {
        let input = try fixture()
        let document = try PDFEngine.load(input)
        for rotation in [0, 90, 180, 270] {
            document.page(at: 0)?.rotation = rotation
            let raw = try XCTUnwrap(document.page(at: 0)?.pageRef?.getBoxRect(.mediaBox))
            let expected = rotation % 180 == 0 ? raw.size : CGSize(width: raw.height, height: raw.width)
            var options = OperationOptions()
            options.text = "fileel watermark"
            options.watermarkHex = "FF0000"
            options.watermarkOpacity = 0.6
            let data = try PDFWatermarkEngine.data(document: document, pages: [0], options: options)
            let exported = try XCTUnwrap(PDFDocument(data: data))
            let page = try XCTUnwrap(exported.page(at: 0))
            XCTAssertEqual(page.bounds(for: .mediaBox).size, expected, "rotation \(rotation)")
            XCTAssertTrue(page.string?.contains("fileel page 1") == true, "source text must remain selectable")
            XCTAssertTrue(page.string?.contains("fileel watermark") == true)
        }
    }

    func raster(_ page: PDFPage) throws -> CGImage {
        let reference = try XCTUnwrap(page.pageRef)
        let bounds = reference.getBoxRect(.mediaBox)
        let swapped = abs(reference.rotationAngle) % 180 != 0
        let size = swapped ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let context = try ImageEngine.context(width: Int(size.width), height: Int(size.height))
        let target = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
        context.concatenate(reference.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        return try XCTUnwrap(context.makeImage())
    }

    func testWatermarkKeepsRotatedArtworkInPlaceAndPreservesChosenMetadata() throws {
        let document = try PDFEngine.load(fixture())
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "fileel fixture", PDFDocumentAttribute.authorAttribute: "test author"]
        var options = OperationOptions(); options.text = "watermark"; options.watermarkOpacity = 0
        for rotation in [0, 90, 180, 270] {
            let source = try XCTUnwrap(document.page(at: 0)); source.rotation = rotation
            let before = try raster(source)
            let data = try PDFWatermarkEngine.data(document: document, pages: [0], options: options)
            let exported = try XCTUnwrap(PDFDocument(data: data))
            let after = try raster(XCTUnwrap(exported.page(at: 0)))
            XCTAssertEqual(before.width, after.width); XCTAssertEqual(before.height, after.height)
            let first = Array(try XCTUnwrap(before.dataProvider?.data) as Data)
            let second = Array(try XCTUnwrap(after.dataProvider?.data) as Data)
            let difference = zip(first, second).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(first.count)
            XCTAssertLessThan(difference, 1, "artwork must stay in place at rotation \(rotation)")
            XCTAssertEqual(exported.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "fileel fixture")
        }
        options.stripMetadata = true
        let stripped = try XCTUnwrap(PDFDocument(data: PDFWatermarkEngine.data(document: document, pages: [0], options: options)))
        XCTAssertNil(stripped.documentAttributes?[PDFDocumentAttribute.authorAttribute])
        let runner = ProcessRunner(); runner.cancel()
        XCTAssertThrowsError(try PDFWatermarkEngine.data(document: document, pages: [0, 1, 2], options: options,
                                                        checkCancellation: { try runner.checkCancellation() }))
    }

    func testRasterExportKeepsPageRotationAndArtwork() throws {
        let document = try PDFEngine.load(fixture())
        let page = try XCTUnwrap(document.page(at: 0))
        for angle in [0, 90, 180, 270] {
            page.rotation = angle
            let expected = try raster(page)
            let result = try PDFEngine.render(page, dpi: 72)
            XCTAssertEqual(result.width, expected.width); XCTAssertEqual(result.height, expected.height)
            let first = Array(try XCTUnwrap(expected.dataProvider?.data) as Data)
            let second = Array(try XCTUnwrap(result.dataProvider?.data) as Data)
            let difference = zip(first, second).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(first.count)
            XCTAssertLessThan(difference, 1, "rotated artwork must remain in place")
        }
        XCTAssertThrowsError(try PDFEngine.render(page, dpi: .nan))
        XCTAssertThrowsError(try PDFEngine.render(page, dpi: .infinity))
        XCTAssertThrowsError(try PDFEngine.render(page, dpi: 1e12))
    }

    func testPDFCompressionReportsRealSizeAndKeepsSelectableText() throws {
        guard Engines.locate("gs") != nil else { throw XCTSkip("Ghostscript is required") }
        let input = try fixture(photograph: true)
        let original = try digest(input)
        let output = folder.appendingPathComponent("compressed.pdf")
        let result = try PDFCompressionEngine.compress(input, output: output, reduction: 60, runner: ProcessRunner())
        XCTAssertEqual(result.originalBytes, try PDFCompressionEngine.byteCount(input))
        XCTAssertEqual(result.outputBytes, try PDFCompressionEngine.byteCount(output))
        XCTAssertLessThan(result.outputBytes, result.originalBytes)
        XCTAssertTrue(result.targetReached)
        let document = try PDFEngine.load(output)
        XCTAssertEqual(document.pageCount, 3)
        for index in 0..<3 { XCTAssertTrue(document.page(at: index)?.string?.contains("fileel page \(index + 1)") == true) }
        XCTAssertEqual(try digest(input), original)
    }

    func testCompressionRejectsInvalidTargetsAndCancelledWork() throws {
        let source = try fixture()
        for reduction in [-1.0, 96, .nan, .infinity] {
            let output = folder.appendingPathComponent("invalid.pdf")
            XCTAssertThrowsError(try PDFCompressionEngine.compress(source, output: output, reduction: reduction, runner: ProcessRunner()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let runner = ProcessRunner(); runner.cancel()
        let output = folder.appendingPathComponent("cancelled.pdf")
        XCTAssertThrowsError(try PDFCompressionEngine.compress(source, output: output, reduction: 60, runner: runner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertThrowsError(try PDFCompressionEngine.compress(source, output: source, reduction: 60, runner: ProcessRunner()))
    }
}
