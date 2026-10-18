import AppKit
import XCTest
@testable import FileelCore

// exports must remain usable after the private conversion workspace and original image are gone
final class MarkdownExportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        guard Engines.locate("pandoc") != nil else { throw XCTSkip("The document runtime is required") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-markdown-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    func testTextOnlyMarkdownStaysASingleFileAndExistingFoldersRemainUntouched() throws {
        let source = folder.appendingPathComponent("source.txt")
        try "# A heading\n\nText without pictures.\n".write(to: source, atomically: true, encoding: .utf8)
        let output = folder.appendingPathComponent("result.md")
        XCTAssertEqual(try DocumentEngine.pandoc(source, output: output, runner: ProcessRunner()), output)
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("Text without pictures."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.deletingPathExtension().path))
        let protectedOutput = folder.appendingPathComponent("protected.md")
        let existing = protectedOutput.deletingPathExtension()
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let sentinel = existing.appendingPathComponent("original.txt")
        let original = Data("keep this existing file".utf8)
        try original.write(to: sentinel)
        XCTAssertThrowsError(try DocumentEngine.pandoc(source, output: protectedOutput, runner: ProcessRunner()))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
    }

    func testPublishedMarkdownKeepsItsImagesAndSurvivesBeingMoved() throws {
        let image = folder.appendingPathComponent("red photo.png")
        let context = try ImageEngine.context(width: 40, height: 30)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: image, options: .init())
        let imageBytes = try Data(contentsOf: image)
        let source = folder.appendingPathComponent("a report.md")
        try "# A report\n\n![A red picture](<red photo.png>)\n\nPortable images.\n".write(to: source, atomically: true, encoding: .utf8)
        let stage = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let docx = try DocumentEngine.convert(source, format: "docx", folder: stage, options: .init(), runner: ProcessRunner())
        let original = try Data(contentsOf: docx)
        try FileManager.default.removeItem(at: image)
        try FileManager.default.removeItem(at: source)
        let destination = folder.appendingPathComponent("published")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var options = OperationOptions()
        options.outputDirectory = destination
        let output = try XCTUnwrap(ConversionEngine.perform(.convert("md"), inputs: [docx], options: options, runner: ProcessRunner()).first)
        let directory = try output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let moved = folder.appendingPathComponent(directory ? "moved export" : "moved export.md")
        try FileManager.default.moveItem(at: output, to: moved)
        let markdown: URL
        if try moved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            markdown = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: moved, includingPropertiesForKeys: nil).first { $0.pathExtension == "md" })
        } else { markdown = moved }
        let text = try String(contentsOf: markdown, encoding: .utf8)
        XCTAssertTrue(text.contains("Portable images."))
        XCTAssertFalse(text.contains("<img"), text)
        let pattern = #"src=["']([^"']+)["']|!\[[^\]]*\]\(<?([^\)\s>]+)>?\)"#
        let expression = try NSRegularExpression(pattern: pattern)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertFalse(matches.isEmpty, text)
        for match in matches {
            let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let range = try XCTUnwrap(Range(capture, in: text))
            let path = String(text[range])
            XCTAssertFalse(path.hasPrefix("/"), "image links must survive moving the export")
            let url = markdown.deletingLastPathComponent().appendingPathComponent(path.removingPercentEncoding ?? path)
            XCTAssertEqual(try Data(contentsOf: url), imageBytes)
        }
        let roundtripFolder = folder.appendingPathComponent("roundtrip")
        try FileManager.default.createDirectory(at: roundtripFolder, withIntermediateDirectories: true)
        let roundtrip = try DocumentEngine.convert(markdown, format: "docx", folder: roundtripFolder, options: .init(), runner: ProcessRunner())
        let unpacked = folder.appendingPathComponent("unpacked")
        try ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", roundtrip.path, unpacked.path])
        let files = try FileManager.default.contentsOfDirectory(at: unpacked.appendingPathComponent("word/media"), includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(try Data(contentsOf: docx), original)
    }
}
