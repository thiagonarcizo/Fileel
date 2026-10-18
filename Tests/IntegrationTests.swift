import AppKit
import PDFKit
import XCTest
@testable import FileelCore

// small generated fixtures exercise each backend without touching personal files
final class IntegrationTests: XCTestCase {
    var folder: URL!
    let runner = ProcessRunner()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func perform(_ operation: FileOperation, _ inputs: [URL], options: OperationOptions = .init()) throws -> URL {
        try ConversionEngine.perform(operation, inputs: inputs, options: options, runner: runner)[0]
    }

    func require(_ engines: [String]) throws {
        for name in engines where Engines.locate(name) == nil { throw XCTSkip("\(name) is not installed on this test host") }
    }

    func audio() throws -> URL {
        let input = folder.appendingPathComponent("tone.wav")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1.2", input.path])
        return input
    }

    func video() throws -> URL {
        let input = folder.appendingPathComponent("clip.mp4")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=15:duration=1.2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1.2", "-c:v", "h264_videotoolbox", "-c:a", "aac", "-shortest", input.path])
        return input
    }

    func testEveryAudioOutputAndAudioTools() throws {
        try require(["ffmpeg", "ffprobe"])
        let input = try audio()
        for ext in FileFamily.audio.outputs {
            let output = try perform(.convert(ext), [input])
            XCTAssertGreaterThan(try MediaEngine.duration(output, runner: runner), 1, ext)
        }
        var options = OperationOptions()
        options.start = 0.1; options.end = 0.8; options.fadeIn = 0.1; options.fadeOut = 0.1
        for tool: FileTool in [.compress, .metadata, .normalize, .trimAudio, .channels, .visualizer, .bleep, .fade, .removeSilence] {
            let output = try perform(.tool(tool), [input], options: options)
            XCTAssertGreaterThan(try MediaEngine.duration(output, runner: runner), 0, tool.rawValue)
        }
        let joined = try perform(.tool(.joinAudio), [input, input])
        XCTAssertGreaterThan(try MediaEngine.duration(joined, runner: runner), 2)
    }

    func testEveryVideoOutputAndVideoTools() throws {
        try require(["ffmpeg", "ffprobe"])
        let input = try video()
        for ext in FileFamily.video.outputs {
            let output = try perform(.convert(ext), [input])
            XCTAssertGreaterThan(try MediaEngine.duration(output, runner: runner), 0, ext)
        }
        var options = OperationOptions()
        options.start = 0.1; options.end = 0.8; options.width = 120; options.height = 80
        options.x = 10; options.y = 10; options.rotation = 90; options.speed = 1.5; options.splitPoints = "0.4,0.8"
        for tool: FileTool in [.compress, .metadata, .trimVideo, .cropVideo, .speed, .mute, .redactVideo, .resize, .rotate, .extractAudio] {
            let output = try perform(.tool(tool), [input], options: options)
            XCTAssertGreaterThan(try MediaEngine.duration(output, runner: runner), 0, tool.rawValue)
        }
        let snapshot = try perform(.tool(.snapshots), [input], options: options)
        XCTAssertEqual(try ImageEngine.load(snapshot).width, 320)
        let split = try perform(.tool(.splitVideo), [input], options: options)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: split.path).count, 3)
        let joined = try perform(.tool(.joinVideos), [input, input], options: options)
        XCTAssertGreaterThan(try MediaEngine.duration(joined, runner: runner), 2)
    }

    func testSubtitleEmbeddingAndExtraction() throws {
        try require(["ffmpeg"])
        let input = try video()
        let subtitles = folder.appendingPathComponent("text.srt")
        try "1\n00:00:00,100 --> 00:00:01,000\nhello Fileel\n".write(to: subtitles, atomically: true, encoding: .utf8)
        var options = OperationOptions(); options.subtitlePath = subtitles.path
        let embedded = try perform(.tool(.embedSubtitles), [input], options: options)
        let extracted = try perform(.tool(.extractSubtitles), [embedded])
        XCTAssertTrue(try String(contentsOf: extracted, encoding: .utf8).contains("hello Fileel"))
    }

    func testMediaMetadataEditingKeepsEncodedStreams() throws {
        try require(["ffmpeg", "ffprobe"])
        let input = try video()
        var options = OperationOptions()
        options.author = "Fileel Fixture"
        options.title = "Edited Title"
        let output = try perform(.tool(.metadata), [input], options: options)
        func digest(_ url: URL, stream: String) throws -> String {
            try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-i", url.path, "-map", stream, "-c", "copy", "-f", "hash", "-hash", "sha256", "-"])
        }
        XCTAssertEqual(try digest(input, stream: "0:v:0"), try digest(output, stream: "0:v:0"))
        XCTAssertEqual(try digest(input, stream: "0:a:0"), try digest(output, stream: "0:a:0"))
        let tags = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-show_entries", "format_tags=title,artist", "-of", "json", output.path])
        XCTAssertTrue(tags.contains("Edited Title"))
        XCTAssertTrue(tags.contains("Fileel Fixture"))
    }

    func testOfficeConversionAndPDFExports() throws {
        try require(["soffice", "pandoc"])
        let input = folder.appendingPathComponent("notes.md")
        try "# Fileel Test\n\nThis document contains editable text.\n\n- first\n- second\n".write(to: input, atomically: true, encoding: .utf8)
        let docx = try perform(.convert("docx"), [input])
        let pdf = try perform(.convert("pdf"), [docx])
        XCTAssertGreaterThan(try PDFEngine.load(pdf).pageCount, 0)
        for ext in ["txt", "md", "html", "epub"] {
            let output = try perform(.convert(ext), [docx])
            XCTAssertGreaterThan((try Data(contentsOf: output)).count, 20, ext)
        }
        let exported = try perform(.convert("docx"), [pdf])
        let plain = try perform(.convert("txt"), [exported])
        let exportedText = try String(contentsOf: plain, encoding: .utf8)
        XCTAssertTrue(exportedText.contains("editable text"), exportedText)
        let pptx = try perform(.convert("pptx"), [pdf])
        let slidesPDF = try perform(.convert("pdf"), [pptx])
        XCTAssertEqual(try PDFEngine.load(slidesPDF).pageCount, 1)
        let xlsx = try perform(.convert("xlsx"), [pdf])
        let sheet = try perform(.tool(.exportSheet), [xlsx])
        let exportedSheet = try String(contentsOf: sheet, encoding: .utf8)
        XCTAssertTrue(exportedSheet.contains("editable text"), exportedSheet)
        let imageFolder = try perform(.convert("png"), [pdf])
        let firstPage = try FileManager.default.contentsOfDirectory(at: imageFolder, includingPropertiesForKeys: nil)[0]
        XCTAssertGreaterThan(try ImageEngine.load(firstPage).width, 2000)
    }

    func testSpreadsheetFormatsAndTextTools() throws {
        try require(["soffice", "pandoc"])
        let input = folder.appendingPathComponent("budget.csv")
        try "name,value\nalpha,10\nbeta,20\n".write(to: input, atomically: true, encoding: .utf8)
        let xlsx = try perform(.convert("xlsx"), [input])
        for ext in ["ods", "csv", "tsv", "pdf"] {
            let output = try perform(.convert(ext), [xlsx])
            XCTAssertGreaterThan((try Data(contentsOf: output)).count, 0, ext)
        }
        let before = folder.appendingPathComponent("before.txt"), after = folder.appendingPathComponent("after.txt")
        try "one\ntwo".write(to: before, atomically: true, encoding: .utf8)
        try "one\nthree".write(to: after, atomically: true, encoding: .utf8)
        let diff = try perform(.tool(.compareDocuments), [before, after])
        let text = try String(contentsOf: diff, encoding: .utf8)
        XCTAssertTrue(text.contains("+ line 2: three"))
        XCTAssertTrue(text.contains("- line 2: two"))
        let count = try perform(.tool(.wordCount), [before])
        XCTAssertTrue(try String(contentsOf: count, encoding: .utf8).contains("Words: 2"))
    }

    func testEncryptedZIPAndIntegrity() throws {
        try require(["7zz"])
        let input = folder.appendingPathComponent("original.zip")
        let text = folder.appendingPathComponent("test.txt")
        try "fileel encrypted fixture".write(to: text, atomically: true, encoding: .utf8)
        try runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", text.path, input.path])
        var options = OperationOptions(); options.password = "test password with spaces"
        let timeout = DispatchWorkItem { self.runner.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer { timeout.cancel() }
        let encrypted = try perform(.tool(.encryptArchive), [input], options: options)
        let result = try runner.run(Engines.require("7zz"), ["t", "--", encrypted.path], input: Data((options.password + "\n").utf8))
        XCTAssertTrue(result.contains("Everything is Ok"))
        let listing = try ArchiveContents.read(input, runner: runner)
        XCTAssertTrue(listing.entries.contains { $0.path == "test.txt" })
        let integrity = try perform(.tool(.testArchive), [input])
        XCTAssertTrue(try String(contentsOf: integrity, encoding: .utf8).contains("Everything is Ok"))
    }
}
