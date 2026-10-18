import XCTest
@testable import FileelCore

// exercise job ownership and cancellation without launching pages or changing its open documents
final class PagesExportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-pages-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testExportOpensAnOwnedCopyAndRemovesItAfterSuccess() throws {
        let input = folder.appendingPathComponent("my \"draft\"\n東京.docx")
        let output = folder.appendingPathComponent("new \"copy\"\n東京.pages")
        let original = Data("untouched source bytes".utf8)
        let actualSource = folder.appendingPathComponent("original.docx")
        try original.write(to: actualSource)
        try FileManager.default.createSymbolicLink(at: input, withDestinationURL: actualSource)
        var privateSource: URL?
        try PagesExporter.export(input, output: output, runner: ProcessRunner()) { _, arguments, _ in
            XCTAssertEqual(arguments.count, 2)
            let source = URL(fileURLWithPath: arguments[0])
            privateSource = source
            XCTAssertNotEqual(source.resolvingSymlinksInPath(), input.resolvingSymlinksInPath())
            XCTAssertEqual(try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(arguments[1], output.resolvingSymlinksInPath().path)
            try Data("saved copy".utf8).write(to: output)
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(privateSource).deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: output), Data("saved copy".utf8))
    }

    func testCancellationClosesOnlyOwnedPathsUsingAnUncancelledWorker() throws {
        let input = folder.appendingPathComponent("source.docx")
        let output = folder.appendingPathComponent("copy.pages")
        try Data("original".utf8).write(to: input)
        let runner = ProcessRunner()
        var calls = 0
        var privateSource: String?
        XCTAssertThrowsError(try PagesExporter.export(input, output: output, runner: runner) { _, arguments, worker in
            calls += 1
            XCTAssertFalse(arguments.contains(input.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: arguments[0]))
            if calls == 1 {
                privateSource = arguments[0]
                runner.cancel()
                throw CancellationError()
            }
            XCTAssertEqual(arguments[0], privateSource)
            XCTAssertEqual(arguments[1], output.resolvingSymlinksInPath().path)
            XCTAssertNoThrow(try worker.checkCancellation())
            throw FileelError.message("Simulated close failure")
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(privateSource)))
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), "original")
    }

    func testPrecancelledAndMissingOutputJobsLeaveNoPrivateCopy() throws {
        let input = folder.appendingPathComponent("source.docx")
        let output = folder.appendingPathComponent("copy.pages")
        try Data("original".utf8).write(to: input)
        let runner = ProcessRunner()
        runner.cancel()
        XCTAssertThrowsError(try PagesExporter.export(input, output: output, runner: runner) { _, _, _ in
            XCTFail("A cancelled job must not start the scripting helper")
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try PagesExporter.export(input, output: output, runner: ProcessRunner()) { _, _, _ in })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [input.lastPathComponent])
    }

    func testScriptArgumentsRemainLiteralAcrossQuotesAndNewlines() throws {
        let arguments = ["first \"quoted\" path\\with\nnewlines", "second 'path' 東京"]
        let output = folder.appendingPathComponent("arguments.txt")
        // this script only returns arguments and never sends an apple event to another app
        let script = "on run argv\nreturn (item 1 of argv) & linefeed & (item 2 of argv)\nend run"
        try ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script, "--"] + arguments, output: output)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), arguments.joined(separator: "\n") + "\n")
    }

    func testCancellationTerminatesARealScriptWorkerBeforeCleanup() throws {
        let input = folder.appendingPathComponent("source.docx")
        let output = folder.appendingPathComponent("copy.pages")
        try Data("original".utf8).write(to: input)
        let runner = ProcessRunner()
        var calls = 0
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { runner.cancel() }
        XCTAssertThrowsError(try PagesExporter.export(input, output: output, runner: runner) { _, _, worker in
            calls += 1
            // a plain delay exercises process termination without sending any event to pages
            try PagesExporter.runScript(calls == 1 ? "delay 30" : "return \"closed\"", arguments: [], runner: worker)
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [input.lastPathComponent])
    }
}
