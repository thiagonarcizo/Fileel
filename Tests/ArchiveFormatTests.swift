import XCTest
@testable import FileelCore

// plain gzip streams and tarballs share an extension but must retain their different content layouts
final class ArchiveFormatTests: XCTestCase {
    private var folder: URL!
    private let runner = ProcessRunner()

    override func setUpWithError() throws {
        guard Engines.locate("7zz") != nil else { throw XCTSkip("The archive runtime is required") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-archive-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    func testPlainGzipCanBeListedExtractedConvertedAndVerified() throws {
        let source = folder.appendingPathComponent("notes.txt")
        let bytes = Data("Fileel gzip fixture · 東京\n".utf8) + Data([0, 1, 2, 255])
        try bytes.write(to: source)
        for ext in ["gz", "GZ"] {
            let input = folder.appendingPathComponent("notes.txt.\(ext)")
            try runner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-n", "-c", source.path], output: input)
            let original = try Data(contentsOf: input)
            for tool in [FileTool.listArchive, .testArchive] {
                let output = try perform(.tool(tool), input)
                let report = try String(contentsOf: output, encoding: .utf8)
                XCTAssertTrue(report.contains(tool == .listArchive ? "notes.txt" : "Everything is Ok"))
            }
            let extracted = try perform(.tool(.extract), input)
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("notes.txt")), bytes)
            for format in ["zip", "tar"] {
                let converted = try perform(.convert(format), input)
                let unpacked = try perform(.tool(.extract), converted)
                XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("notes.txt")), bytes)
            }
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testTarballsStayExpandedAcrossArchiveConversions() throws {
        let contents = folder.appendingPathComponent("contents")
        let nested = contents.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let bytes = Data("nested archive fixture".utf8)
        try bytes.write(to: nested.appendingPathComponent("東京.txt"))
        let input = folder.appendingPathComponent("source.zip")
        try runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", "--noextattr", contents.path, input.path])
        let tar = try perform(.convert("tar"), input)
        let gzip = try perform(.convert("gz"), input)
        for archive in [input, tar, gzip] {
            let original = try Data(contentsOf: archive)
            for format in ["zip", "tar", "gz"] where Catalog.canonical(archive.pathExtension) != format {
                let converted = try perform(.convert(format), archive)
                let unpacked = try perform(.tool(.extract), converted)
                XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("nested/東京.txt")), bytes)
            }
            XCTAssertEqual(try Data(contentsOf: archive), original)
        }
    }

    private func perform(_ operation: FileOperation, _ input: URL) throws -> URL {
        var options = OperationOptions()
        options.outputDirectory = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: options.outputDirectory!, withIntermediateDirectories: true)
        return try XCTUnwrap(ConversionEngine.perform(operation, inputs: [input], options: options, runner: runner).first)
    }
}
