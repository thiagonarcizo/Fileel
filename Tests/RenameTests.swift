import Foundation
import XCTest
@testable import FileelCore

// exercise literal names and collision preflights using disposable files
final class RenameTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func file(_ name: String, content: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    func testSingleRenameKeepsExtensionAndTreatsTokensAsLiteralText() throws {
        let original = try file("photo.jpg")
        let renamed = try XCTUnwrap(FileActions.rename([original], baseName: "Trip {n} {name}").first)
        XCTAssertEqual(renamed.lastPathComponent, "Trip {n} {name}.jpg")
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try FileActions.rename([renamed], baseName: "Trip {n} {name}"), [renamed])
    }

    func testBatchNumberingKeepsEachExtensionAndDoesNotAddDotsToFolders() throws {
        let first = try file("photo.jpg")
        let second = try file("notes")
        let directory = folder.appendingPathComponent("old.folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renamed = try FileActions.rename([first, second, directory], baseName: "Trip")
        XCTAssertEqual(renamed.map(\.lastPathComponent), ["Trip 1.jpg", "Trip 2", "Trip 3"])
        XCTAssertTrue(try renamed[2].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    func testInvalidNamesAndLaterCollisionLeaveEveryOriginalUntouched() throws {
        let first = try file("a.jpg", content: "first")
        let second = try file("b.jpg", content: "second")
        let occupied = try file("Trip 2.jpg", content: "existing")
        XCTAssertThrowsError(try FileActions.rename([first, second], baseName: "Trip"))
        for name in ["", " ", ".", "..", "../outside", "a:b", "a\0b", "a\nb"] {
            XCTAssertThrowsError(try FileActions.rename([first], baseName: name), name)
        }
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "existing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Trip 1.jpg").path))
    }
}
