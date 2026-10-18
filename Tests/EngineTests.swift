import AppKit
import PDFKit
import XCTest
@testable import FileelCore

// verify outputs with independent decoders rather than checking only file existence
final class EngineTests: XCTestCase {
    var folder: URL!
    var source: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        source = folder.appendingPathComponent("input.png")
        let ctx = try ImageEngine.context(width: 320, height: 180)
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        try ImageEngine.write(ctx.makeImage()!, to: source, options: .init())
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func perform(_ operation: FileOperation, _ inputs: [URL]? = nil, options: OperationOptions = .init()) throws -> [URL] {
        try ConversionEngine.perform(operation, inputs: inputs ?? [source], options: options, runner: ProcessRunner())
    }

    func testImageConversionPreservesSizeAndOriginal() throws {
        for format in ["jpg", "png", "tiff", "heic", "webp", "avif"] {
            let outputs: [URL]
            do { outputs = try perform(.convert(format)) }
            catch { XCTFail("\(format.uppercased()) conversion failed: \(error)"); continue }
            let image = try ImageEngine.load(outputs[0])
            XCTAssertEqual(image.width, 320, format)
            XCTAssertEqual(image.height, 180, format)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testOutputCollisionAndAtomicFailure() throws {
        let first = try perform(.convert("jpg"))[0]
        let bytes = try Data(contentsOf: first)
        let second = try perform(.convert("jpg"))[0]
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(bytes, try Data(contentsOf: first))
        let bad = folder.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)
        XCTAssertThrowsError(try perform(.convert("tiff"), [source, bad]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("input Converted.tiff").path))
    }

    func testCropAndRotation() throws {
        var options = OperationOptions()
        options.width = 80; options.height = 50; options.x = 4; options.y = 8
        let crop = try ImageEngine.load(perform(.tool(.cropImage), options: options)[0])
        XCTAssertEqual(crop.width, 80)
        XCTAssertEqual(crop.height, 50)
        options.rotation = 90
        let rotated = try ImageEngine.load(perform(.tool(.rotate), options: options)[0])
        XCTAssertEqual(rotated.width, 180)
        XCTAssertEqual(rotated.height, 320)
    }

    func testPDFCreationSplitMergeAndProtection() throws {
        let pdf = try perform(.tool(.createPDF), [source, source])[0]
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 2)
        let split = try perform(.tool(.splitPDF), [pdf])[0]
        let pages = try FileManager.default.contentsOfDirectory(at: split, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        XCTAssertEqual(pages.count, 2)
        let merged = try perform(.tool(.mergePDF), pages)[0]
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 2)
        var options = OperationOptions(); options.password = "fileel-test-password"
        let protected = try perform(.tool(.protectPDF), [merged], options: options)[0]
        let locked = try XCTUnwrap(PDFDocument(url: protected))
        XCTAssertTrue(locked.isLocked)
        XCTAssertTrue(locked.unlock(withPassword: options.password))
    }

    func testSubtitleTimingAndDialoguePunctuation() throws {
        let input = folder.appendingPathComponent("captions.srt")
        try "1\n00:00:01,250 --> 00:00:03,000\nhello, world.\n\n2\n00:00:04,000 --> 00:00:05,000\nnext line\n".write(to: input, atomically: true, encoding: .utf8)
        let vtt = try perform(.convert("vtt"), [input])[0]
        let text = try String(contentsOf: vtt, encoding: .utf8)
        XCTAssertTrue(text.contains("00:00:01.250 --> 00:00:03.000"))
        XCTAssertTrue(text.contains("hello, world."))
        var options = OperationOptions(); options.offset = 2.5
        let shifted = try perform(.tool(.shiftSubtitles), [input], options: options)[0]
        XCTAssertTrue(try String(contentsOf: shifted, encoding: .utf8).contains("00:00:03,750"))
    }

    func testArchiveRoundTripRejectsTraversal() throws {
        XCTAssertFalse(ArchiveEngine.safePath("../outside"))
        XCTAssertFalse(ArchiveEngine.safePath("/absolute"))
        XCTAssertFalse(ArchiveEngine.safePath("safe/../../outside"))
        let zip = folder.appendingPathComponent("source.zip")
        try ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", source.path, zip.path])
        let tar = try perform(.convert("tar"), [zip])[0]
        let extracted = try perform(.tool(.extract), [tar])[0]
        let image = try ImageEngine.load(extracted.appendingPathComponent("input.png"))
        XCTAssertEqual(image.width, 320)
    }

    func testMixedSelectionAndAllToolsHaveFamilies() {
        let unknown = folder.appendingPathComponent("unknown.xyz")
        XCTAssertTrue(Catalog.operations(for: [source, unknown], mode: .convert).isEmpty)
        XCTAssertEqual(Catalog.operations(for: [source, unknown], mode: .actions).count, FileAction.allCases.count)
        for tool in FileTool.available {
            XCTAssertTrue(FileFamily.allCases.contains { $0.tools.contains(tool) }, "Unrouted tool: \(tool)")
        }
    }

    func testCancellationProducesNoOutput() throws {
        let runner = ProcessRunner(); runner.cancel()
        XCTAssertThrowsError(try ConversionEngine.perform(.convert("jpg"), inputs: [source], options: .init(), runner: runner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("input Converted.jpg").path))
    }

    func testChecksumMatchesKnownDigest() throws {
        let text = folder.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: text)
        XCTAssertEqual(try FileActions.checksum(text, runner: ProcessRunner()), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testWheelGeometryReachesEveryOperationWithoutOverlap() {
        for count in 1...16 {
            let geometry = WheelGeometry(count: count)
            for item in geometry.items {
                let point = CGPoint(x: item.radius * cos(item.angle * .pi / 180), y: item.radius * sin(item.angle * .pi / 180))
                XCTAssertEqual(geometry.index(at: point, center: .zero), item.index, "count \(count), index \(item.index)")
            }
            XCTAssertNil(geometry.index(at: .zero, center: .zero))
            XCTAssertNil(geometry.index(at: CGPoint(x: 300, y: 300), center: .zero))
        }
    }

    func testToolSymbolsAreAvailableOnTheCurrentSystem() {
        for tool in FileTool.allCases { XCTAssertNotNil(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil), tool.rawValue) }
        for action in FileAction.allCases { XCTAssertNotNil(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil), action.rawValue) }
    }
    func testHubIsSeparateFromEveryOperationAndFloatingFileSlotIsStable() {
        XCTAssertTrue(WheelGeometry.isHub(.zero, center: .zero))
        XCTAssertTrue(WheelGeometry.isHub(CGPoint(x: 60, y: 0), center: .zero))
        XCTAssertFalse(WheelGeometry.isHub(CGPoint(x: 61, y: 0), center: .zero))
        for count in 1...16 {
            let wheel = WheelGeometry(count: count)
            XCTAssertNil(wheel.index(at: CGPoint(x: 59, y: 0), center: .zero))
            XCTAssertTrue(wheel.items.allSatisfy { $0.labelWidth > 0 && $0.outer - $0.inner >= 68 })
        }
        XCTAssertEqual(FileAction.radialOrder[1], .checksum)
        XCTAssertEqual(FileAction.radialOrder.last, .float)
        XCTAssertEqual(Set(FileAction.radialOrder), Set(FileAction.allCases))
    }

}
