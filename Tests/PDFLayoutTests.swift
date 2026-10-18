import AppKit
import PDFKit
import XCTest
@testable import FileelCore

// inspect exported office objects and a rendered round trip, not just the destination extension
final class PDFLayoutTests: XCTestCase {
    private var directory: URL!
    private var source: URL!

    override func setUpWithError() throws {
        guard Engines.locate("soffice") != nil else { throw XCTSkip("The office runtime is required") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-pdf-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("layout.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &bounds, nil))
        for number in 1...2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 60, y: 400, width: 220, height: 120))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Fileel layout page \(number)" as NSString).draw(at: NSPoint(x: 60, y: 700), withAttributes: [
                .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black
            ])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func unpack(_ url: URL, name: String) throws -> URL {
        let folder = directory.appendingPathComponent(name)
        try ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", url.path, folder.path])
        return folder
    }

    func assertRoundTrip(_ office: URL, name: String) throws {
        let roundTrip = directory.appendingPathComponent(name + ".pdf")
        try DocumentEngine.office(office, format: "pdf", output: roundTrip, runner: ProcessRunner())
        let document = try PDFEngine.load(roundTrip)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.string?.contains("Fileel layout page 1") == true)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 612, accuracy: 2)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 792, accuracy: 2)
        let raster = try PDFEngine.render(page, dpi: 72)
        let bitmap = NSBitmapImageRep(cgImage: raster)
        let sample = try XCTUnwrap(bitmap.colorAt(x: 150, y: raster.height - 460)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(sample.blueComponent, 0.7, "the illustration should remain at its original page position")
        XCTAssertLessThan(sample.redComponent, 0.35)
    }

    func testPDFToWordKeepsEditableTextAndPositionedGraphics() throws {
        let original = try Data(contentsOf: source)
        let output = try DocumentEngine.convert(source, format: "docx", folder: directory, options: .init(), runner: ProcessRunner())
        let package = try unpack(output, name: "word-package")
        let xml = try String(contentsOf: package.appendingPathComponent("word/document.xml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("Fileel layout page 1"))
        XCTAssertTrue(xml.contains("<w:drawing>") || xml.contains("<w:pict>"), "positioned page content should not become plain paragraphs")
        try assertRoundTrip(output, name: "word-roundtrip")
        if Engines.locate("pandoc") != nil {
            let positioned = try Data(contentsOf: output)
            let plain = directory.appendingPathComponent("word-text.txt")
            try DocumentEngine.pandoc(output, output: plain, runner: ProcessRunner())
            let text = try String(contentsOf: plain, encoding: .utf8)
            for number in 1...2 {
                XCTAssertEqual(text.components(separatedBy: "Fileel layout page \(number)").count - 1, 1,
                               "semantic exports should include floating text once, without compatibility duplicates")
            }
            XCTAssertEqual(try Data(contentsOf: output), positioned, "text export must not reflow the saved Word document")
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPDFToSlidesKeepsEditableTextAndVectorShapes() throws {
        let output = try DocumentEngine.convert(source, format: "pptx", folder: directory, options: .init(), runner: ProcessRunner())
        let package = try unpack(output, name: "slides-package")
        let first = try String(contentsOf: package.appendingPathComponent("ppt/slides/slide1.xml"), encoding: .utf8)
        XCTAssertTrue(first.contains("Fileel layout page 1"))
        XCTAssertTrue(first.contains("<p:sp>"), "the page must contain editable shapes rather than only a screenshot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("ppt/slides/slide2.xml").path))
        try assertRoundTrip(output, name: "slides-roundtrip")
    }

    func testEditableImportsDetectMissingLettersBeforeReturningAResult() throws {
        let output = try DocumentEngine.convert(source, format: "docx", folder: directory, options: .init(), runner: ProcessRunner())
        XCTAssertTrue(try OfficeTextFidelity.retainsText(of: source, in: output, runner: ProcessRunner()))
        let package = try unpack(output, name: "damaged-package")
        let xml = package.appendingPathComponent("word/document.xml")
        let damaged = try String(contentsOf: xml, encoding: .utf8).replacingOccurrences(of: "Fileel", with: "Fleel")
        try damaged.write(to: xml, atomically: true, encoding: .utf8)
        let corrupt = directory.appendingPathComponent("missing-glyph.docx")
        try OfficePackage.pack(package, output: corrupt, runner: ProcessRunner())
        XCTAssertFalse(try OfficeTextFidelity.retainsText(of: source, in: corrupt, runner: ProcessRunner()))
    }

    func testRasterSlideFallbackFitsMixedPageOrientationsWithoutStretching() throws {
        let pdf = try PDFEngine.load(source)
        pdf.page(at: 1)?.rotation = 90
        let mixed = directory.appendingPathComponent("mixed.pdf")
        XCTAssertTrue(pdf.write(to: mixed))
        let output = directory.appendingPathComponent("fallback.pptx")
        try OfficePackage.slides(from: mixed, output: output, runner: ProcessRunner())
        let package = try unpack(output, name: "fallback-package")
        let presentation = try String(contentsOf: package.appendingPathComponent("ppt/presentation.xml"), encoding: .utf8)
        let slide = try String(contentsOf: package.appendingPathComponent("ppt/slides/slide2.xml"), encoding: .utf8)
        func numbers(_ pattern: String, in xml: String) throws -> [Double] {
            let match = try XCTUnwrap(NSRegularExpression(pattern: pattern).firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)))
            return try (1..<match.numberOfRanges).map { index in
                let range = try XCTUnwrap(Range(match.range(at: index), in: xml))
                return try XCTUnwrap(Double(xml[range]))
            }
        }
        let canvas = try numbers(#"<p:sldSz cx="([0-9]+)" cy="([0-9]+)"/>"#, in: presentation)
        let picture = try numbers(#"<a:xfrm><a:off x="([0-9]+)" y="([0-9]+)"/><a:ext cx="([0-9]+)" cy="([0-9]+)"/>"#, in: slide)
        XCTAssertEqual(canvas[0] / canvas[1], 612.0 / 792, accuracy: 0.001)
        XCTAssertEqual(picture[2] / picture[3], 792.0 / 612, accuracy: 0.001)
        XCTAssertGreaterThan(picture[1], 0, "the landscape page should be centered on the portrait canvas")
        XCTAssertLessThanOrEqual(picture[2], canvas[0]); XCTAssertLessThanOrEqual(picture[3], canvas[1])
        let rendered = directory.appendingPathComponent("fallback-check.pdf")
        try DocumentEngine.office(output, format: "pdf", output: rendered, runner: ProcessRunner())
        XCTAssertEqual(try PDFEngine.load(rendered).pageCount, 2)
    }
}
