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
            let listing = try ArchiveContents.read(input, runner: runner)
            XCTAssertEqual(listing.entries.map(\.path), ["notes.txt"])
            let output = try perform(.tool(.testArchive), input)
            XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("Everything is Ok"))
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

    // browsing must preserve unicode paths, infer folders, and leave the source directory untouched
    func testZipBrowsingAndExtractionBesideOriginal() throws {
        let source = folder.appendingPathComponent("source")
        let nested = source.appendingPathComponent("Photos/東京")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Empty folder"), withIntermediateDirectories: true)
        let bytes = Data("portrait fixture".utf8)
        try bytes.write(to: nested.appendingPathComponent("photo = 01.txt"))
        let input = folder.appendingPathComponent("Delivery.zip")
        try runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", "--noextattr", source.path, input.path])
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let original = try Data(contentsOf: input)
        let contents = try ArchiveContents.read(input, runner: runner)
        XCTAssertEqual(contents.fileCount, 1)
        XCTAssertEqual(contents.folderCount, 3)
        XCTAssertEqual(contents.expandedSize, Int64(bytes.count))
        XCTAssertEqual(contents.children(of: "").map(\.name), ["Empty folder", "Photos"])
        XCTAssertEqual(contents.children(of: "Photos/東京").map(\.name), ["photo = 01.txt"])
        XCTAssertEqual(contents.children(of: "", matching: "photo =").map(\.path), ["Photos/東京/photo = 01.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before)
        XCTAssertThrowsError(try ConversionEngine.perform(.tool(.listArchive), inputs: [input], options: .init(), runner: runner))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before)

        let first = try XCTUnwrap(ConversionEngine.perform(.tool(.extract), inputs: [input], options: .init(), runner: runner).first)
        let second = try XCTUnwrap(ConversionEngine.perform(.tool(.extract), inputs: [input], options: .init(), runner: runner).first)
        XCTAssertEqual(first.deletingLastPathComponent().path, folder.path)
        XCTAssertNotEqual(first, second)
        for extracted in [first, second] {
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Photos/東京/photo = 01.txt")), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("Empty folder").path))
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    // implicit folders need the same totals and navigation as explicitly stored ones
    func testTechnicalListingInfersFoldersAndRejectsUnsafePaths() throws {
        let contents = try ArchiveContents.parse("Path = Photos/東京/a.txt\nFolder = -\nSize = 12\n\nPath = Photos/b.txt\nFolder = -\nSize = 8\n")
        XCTAssertEqual(contents.folderCount, 2)
        XCTAssertEqual(contents.entries.first { $0.path == "Photos" }?.size, 20)
        XCTAssertEqual(contents.entries.first { $0.path == "Photos/東京" }?.size, 12)
        XCTAssertThrowsError(try ArchiveContents.parse("Path = ../outside.txt\nSize = 1\n"))
        XCTAssertThrowsError(try ArchiveContents.parse("Path = /outside.txt\nSize = 1\n"))
        XCTAssertThrowsError(try ArchiveContents.parse("Path = Photos\nFolder = -\n\nPath = Photos/a.txt\nSize = 1\n"))
        XCTAssertTrue(try ArchiveContents.parse("").entries.isEmpty)
    }

    private func perform(_ operation: FileOperation, _ input: URL) throws -> URL {
        var options = OperationOptions()
        options.outputDirectory = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: options.outputDirectory!, withIntermediateDirectories: true)
        return try XCTUnwrap(ConversionEngine.perform(operation, inputs: [input], options: options, runner: runner).first)
    }
}
