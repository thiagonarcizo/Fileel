import AppKit
import PDFKit
import XCTest
@testable import FileelCore

// verify native mac document inputs with real packages and clipping data, without touching the clipboard
final class NativeDocumentInputTests: XCTestCase {
    private var folder: URL!
    private let phrase = "Café, ação e Ω — a local document"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-native-documents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testRTFDKeepsTextStylesAndImageAttachmentsThroughDOCXAndPDF() throws {
        guard Engines.locate("soffice") != nil, Engines.locate("pandoc") != nil else { throw XCTSkip("The office runtimes are required") }
        let source = folder.appendingPathComponent("rich document.rtfd")
        let content = NSMutableAttributedString(string: phrase + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
        let context = try ImageEngine.context(width: 80, height: 60)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let image = try XCTUnwrap(context.makeImage())
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = NSTextAttachment()
        attachment.fileWrapper = FileWrapper(regularFileWithContents: data)
        attachment.fileWrapper?.preferredFilename = "red.png"
        content.append(NSAttributedString(attachment: attachment))
        content.append(NSAttributedString(attachment: attachment))
        let wrapper = try content.fileWrapper(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try wrapper.write(to: source, options: .atomic, originalContentsURL: nil)
        let before = try packageContents(source)
        let docx = try convert(source, format: "docx")
        let unpacked = folder.appendingPathComponent("docx")
        try ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", docx.path, unpacked.path])
        let xml = try String(contentsOf: unpacked.appendingPathComponent("word/document.xml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("Café"))
        XCTAssertTrue(xml.contains("ação"))
        XCTAssertTrue(xml.contains("<w:b"), "bold formatting must survive")
        XCTAssertTrue(xml.contains("<w:drawing"), "the image must be a real document drawing")
        XCTAssertEqual(xml.components(separatedBy: "<w:drawing").count - 1, 2, "repeated attachments must retain both positions")
        let media = try FileManager.default.contentsOfDirectory(at: unpacked.appendingPathComponent("word/media"), includingPropertiesForKeys: nil)
        XCTAssertFalse(media.isEmpty, "the embedded picture must remain part of the converted document")
        let pdf = try convert(source, format: "pdf")
        let document = try PDFEngine.load(pdf)
        XCTAssertTrue(document.string?.contains("Café") == true)
        let page = try XCTUnwrap(document.page(at: 0))
        let rendered = try PDFEngine.render(page, dpi: 72)
        let pixels = Array(try XCTUnwrap(rendered.dataProvider?.data) as Data)
        let redPixels = stride(from: 0, to: pixels.count - 3, by: 4).filter {
            pixels[$0] > 200 && pixels[$0 + 1] < 50 && pixels[$0 + 2] < 50
        }.count
        XCTAssertGreaterThan(redPixels, 100, "the attachment must actually render in the exported PDF")
        let plain = try convert(source, format: "txt")
        XCTAssertTrue(try String(contentsOf: plain, encoding: .utf8).contains(phrase))
        let html = try convert(source, format: "html")
        let htmlText = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(htmlText.contains("data:image/png;base64,"), "HTML must contain its image rather than depend on a deleted temporary file")
        let epub = try convert(source, format: "epub")
        let epubFolder = folder.appendingPathComponent("epub")
        try ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", epub.path, epubFolder.path])
        XCTAssertTrue(try packageContents(epubFolder).keys.contains { $0.hasSuffix(".png") }, "EPUB must include the attachment")
        let markdown = try convert(source, format: "md")
        XCTAssertTrue(try markdown.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let markdownFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: markdown, includingPropertiesForKeys: nil).first { $0.pathExtension == "md" })
        let markdownText = try String(contentsOf: markdownFile, encoding: .utf8)
        XCTAssertTrue(markdownText.contains("!["), "rich text conversions must return the portable image folder")
        XCTAssertFalse(markdownText.contains("<img"))
        XCTAssertEqual(try packageContents(source), before)
    }

    func testUnsupportedRTFDAttachmentFailsInsteadOfSilentlyDroppingIt() throws {
        let source = folder.appendingPathComponent("attachment.rtfd")
        let attachment = NSTextAttachment()
        attachment.fileWrapper = FileWrapper(regularFileWithContents: Data("an embedded file, not an image".utf8))
        attachment.fileWrapper?.preferredFilename = "original.bin"
        let content = NSAttributedString(attachment: attachment)
        let wrapper = try content.fileWrapper(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try wrapper.write(to: source, options: .atomic, originalContentsURL: nil)
        let before = try packageContents(source)
        XCTAssertThrowsError(try convert(source, format: "docx"))
        XCTAssertEqual(try packageContents(source), before)
    }

    func testModernFinderClippingExportsItsRichTextInsteadOfReadingANamedPasteboard() throws {
        guard Engines.locate("pandoc") != nil, Engines.locate("soffice") != nil else { throw XCTSkip("The document runtimes are required") }
        let source = folder.appendingPathComponent("notes.textClipping")
        let content = NSAttributedString(string: phrase, attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        let rtf = try content.data(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let plist: [String: Any] = ["UTI-Data": ["public.utf8-plain-text": phrase, "public.rtf": try XCTUnwrap(String(data: rtf, encoding: .utf8))]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: source)
        let text = try convert(source, format: "txt")
        XCTAssertTrue(try String(contentsOf: text, encoding: .utf8).contains(phrase))
        let docx = try convert(source, format: "docx")
        let unpacked = folder.appendingPathComponent("clipping-docx")
        try ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", docx.path, unpacked.path])
        let xml = try String(contentsOf: unpacked.appendingPathComponent("word/document.xml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("<w:b"))
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testClassicFinderClippingReadsItsUTF8ResourceForkAndRejectsBrokenMaps() throws {
        guard Engines.locate("pandoc") != nil, Engines.locate("soffice") != nil else { throw XCTSkip("The document runtimes are required") }
        let runner = ProcessRunner()
        guard (try? runner.run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["--find", "Rez"])) != nil else { throw XCTSkip("The Apple resource compiler is required for this fixture") }
        let source = folder.appendingPathComponent("classic.textClipping")
        let recipe = folder.appendingPathComponent("fixture.r")
        let hex = Data(phrase.utf8).map { String(format: "%02x", $0) }.joined()
        try "data 'utf8' (256) { $\"\(hex)\" };\n".write(to: recipe, atomically: true, encoding: .utf8)
        try runner.run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["Rez", recipe.path, "-o", source.path])
        let forkURL = URL(fileURLWithPath: source.path + "/..namedfork/rsrc")
        let original = try Data(contentsOf: forkURL)
        XCTAssertFalse(original.isEmpty)
        let output = try convert(source, format: "txt")
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains(phrase))
        XCTAssertEqual(try Data(contentsOf: forkURL), original)
        let damaged = folder.appendingPathComponent("damaged.textClipping")
        for count in [0, 15, 16, original.count / 2, original.count - 1] {
            try Data(original.prefix(count)).write(to: damaged)
            XCTAssertThrowsError(try NativeDocumentInput.clipping(damaged), "truncated fork at \(count) bytes")
        }
        try Data(repeating: 255, count: 128).write(to: damaged)
        XCTAssertThrowsError(try NativeDocumentInput.clipping(damaged))
    }

    private func convert(_ input: URL, format: String) throws -> URL {
        let workspace = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return try DocumentEngine.convert(input, format: format, folder: workspace, options: OperationOptions(), runner: ProcessRunner())
    }

    private func packageContents(_ input: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey]))
        var result = [String: Data]()
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(input.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
}
