import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import FileelCore

// privacy choices must survive the fallback used when an encode cannot make a file smaller
final class CompressionMetadataTests: XCTestCase {
    private var folder: URL!
    private let marker = "private fixture owner"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-compression-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testSmallImageFallbackRespectsMetadataRemovalAndKeepsPixels() throws {
        let input = folder.appendingPathComponent("small.png")
        let context = try ImageEngine.context(width: 8, height: 8)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: marker]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: input)
        XCTAssertTrue(try imageProperties(input).description.contains(marker))
        var options = OperationOptions()
        options.compressionReduction = 0
        let retained = folder.appendingPathComponent("retained.png")
        try CompressionEngine.compress(input, output: retained, options: options, runner: ProcessRunner())
        XCTAssertEqual(try Data(contentsOf: retained), original, "the fixture must exercise the original-file fallback")
        options.preserveMetadata = false
        let output = folder.appendingPathComponent("stripped.png")
        let result = try CompressionEngine.compress(input, output: output, options: options, runner: ProcessRunner())
        XCTAssertFalse(try imageProperties(output).description.contains(marker))
        let decoded = try ImageEngine.load(output)
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
        let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: decoded).colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.99)
        XCTAssertLessThan(pixel.blueComponent, 0.01)
        XCTAssertEqual(result.outputBytes, try PDFCompressionEngine.byteCount(output))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testZeroReductionPDFRemovesInfoAndXMPWhileKeepingTextAndAnnotations() throws {
        let input = folder.appendingPathComponent("source.pdf")
        try writePDFFixture(input)
        let original = try Data(contentsOf: input)
        let originalDocument = try PDFEngine.load(input)
        let originalBookmark = try XCTUnwrap(originalDocument.outlineRoot?.child(at: 0))
        XCTAssertEqual(originalBookmark.label, "fixture bookmark")
        XCTAssertEqual(try PDFEngine.load(input).documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, marker)
        XCTAssertTrue(try pdfMetadata(input)?.contains(marker) == true)
        var options = OperationOptions()
        options.compressionReduction = 0
        options.preserveMetadata = false
        let output = folder.appendingPathComponent("stripped.pdf")
        try CompressionEngine.compress(input, output: output, options: options, runner: ProcessRunner())
        let result = try PDFEngine.load(output)
        XCTAssertNil(result.documentAttributes?[PDFDocumentAttribute.authorAttribute])
        XCTAssertFalse(try pdfMetadata(output)?.contains(marker) == true)
        XCTAssertTrue(result.string?.contains("selectable fixture text") == true)
        XCTAssertTrue(result.page(at: 0)?.annotations.contains { $0.contents == "visible annotation" } == true)
        XCTAssertEqual(result.page(at: 0)?.annotations.first { $0.fieldName == "fixture field" }?.widgetStringValue, "editable value")
        let savedBookmark = try XCTUnwrap(result.outlineRoot?.child(at: 0))
        XCTAssertEqual(savedBookmark.label, "fixture bookmark")
        XCTAssertEqual(savedBookmark.destination?.page, result.page(at: 0))
        let metadataOutput = folder.appendingPathComponent("metadata-tool.pdf")
        try PDFEngine.process(input, tool: .metadata, output: metadataOutput, options: options, runner: ProcessRunner())
        XCTAssertFalse(try pdfMetadata(metadataOutput)?.contains(marker) == true)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testLosslessMetadataRemovalKeepsOrientedJPEGPixels() throws {
        let input = folder.appendingPathComponent("source.jpg")
        let context = try ImageEngine.context(width: 32, height: 16)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 16, y: 0, width: 16, height: 16))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImageDestinationLossyCompressionQuality: 0.1, kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: marker],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 20, kCGImagePropertyGPSLongitudeRef: "E"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: input)
        let output = folder.appendingPathComponent("stripped.jpg")
        var options = OperationOptions()
        options.preserveMetadata = false
        options.compressionReduction = 0
        try CompressionEngine.compress(input, output: output, options: options, runner: ProcessRunner())
        let before = try ImageEngine.load(input)
        let after = try ImageEngine.load(output)
        XCTAssertEqual(after.width, 16)
        XCTAssertEqual(after.height, 32)
        let beforePixels = try XCTUnwrap(before.dataProvider?.data) as Data
        let afterPixels = try XCTUnwrap(after.dataProvider?.data) as Data
        XCTAssertEqual(beforePixels, afterPixels, "metadata removal must not introduce a second lossy JPEG encode")
        let properties = try imageProperties(output)
        XCTAssertFalse(properties.description.contains(marker))
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testSmallVideoFallbackRemovesMetadataWithoutReencodingPackets() throws {
        guard Engines.locate("ffmpeg") != nil, Engines.locate("ffprobe") != nil else { throw XCTSkip("The media runtime is required") }
        let runner = ProcessRunner()
        let input = folder.appendingPathComponent("small.mp4")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "color=black:size=64x64:rate=10:duration=0.4", "-c:v", "mpeg4", "-an", "-metadata", "title=\(marker)",
            "-metadata:s:v:0", "handler_name=\(marker)", input.path])
        let original = try Data(contentsOf: input)
        XCTAssertTrue(try tags(input, runner: runner).contains(marker))
        var options = OperationOptions()
        options.compressionReduction = 0
        options.preserveMetadata = false
        let output = folder.appendingPathComponent("stripped.mp4")
        try CompressionEngine.compress(input, output: output, options: options, runner: runner)
        XCTAssertFalse(try tags(output, runner: runner).contains(marker))
        XCTAssertEqual(try packets(input, runner: runner), try packets(output, runner: runner))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    // write a small standards-based fixture so the native PDF writer cannot silently omit features from the test input
    private func writePDFFixture(_ url: URL) throws {
        let content = "BT /F1 16 Tf 10 200 Td (selectable fixture text) Tj ET"
        let xmp = "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description xmlns:dc='http://purl.org/dc/elements/1.1/' dc:creator='\(marker)'/></rdf:RDF></x:xmpmeta>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Metadata 7 0 R /Outlines 8 0 R /AcroForm << /Fields [6 0 R] /DA (/F1 12 Tf 0 g) /DR << /Font << /F1 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 320] /Contents 5 0 R /Resources << /Font << /F1 4 0 R >> >> /Annots [6 0 R 10 0 R] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (fixture field) /V (editable value) /Rect [10 70 160 100] /P 3 0 R /F 4 >>",
            "<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n\(xmp)\nendstream",
            "<< /Type /Outlines /First 9 0 R /Last 9 0 R /Count 1 >>",
            "<< /Title (fixture bookmark) /Parent 8 0 R /Dest [3 0 R /XYZ 10 200 0] >>",
            "<< /Type /Annot /Subtype /Text /Rect [20 20 120 60] /Contents (visible annotation) /P 3 0 R >>",
            "<< /Author (\(marker)) >>"
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 11 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: url)
    }

    private func imageProperties(_ url: URL) throws -> NSDictionary {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)) as NSDictionary
    }

    private func pdfMetadata(_ url: URL) throws -> String? {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        var stream: CGPDFStreamRef?
        var format = CGPDFDataFormat.raw
        guard let catalog = document.catalog, CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream,
              let data = CGPDFStreamCopyData(stream, &format) else { return nil }
        return String(data: data as Data, encoding: .utf8)
    }

    private func tags(_ url: URL, runner: ProcessRunner) throws -> String {
        try runner.run(Engines.require("ffprobe"), ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", url.path])
    }

    private func packets(_ url: URL, runner: ProcessRunner) throws -> String {
        try runner.run(Engines.require("ffprobe"), ["-v", "error", "-select_streams", "v:0", "-show_packets", "-show_entries",
            "packet=data_hash", "-show_data_hash", "sha256", "-of", "csv=p=0", url.path])
    }
}
