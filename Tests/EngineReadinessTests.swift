import XCTest
@testable import FileelCore

// releases must diagnose their own payload instead of silently relying on a developer's machine
final class EngineReadinessTests: XCTestCase {
    func testReleaseRejectsLocalFallbackAndAppNamePrefixLookalikes() {
        let bundle = URL(fileURLWithPath: "/Applications/Fileel.app")
        let rows = Engines.readiness(requiresBundled: true, bundle: bundle) { name in
            switch name {
            case "ffmpeg": return bundle.appendingPathComponent("Contents/MacOS/ffmpeg")
            case "soffice": return bundle.appendingPathComponent("Contents/Helpers/LibreOffice.app/Contents/MacOS/soffice")
            case "pandoc": return URL(fileURLWithPath: "/Applications/Fileel.app-backup/pandoc")
            case "ffprobe": return URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
            default: return nil
            }
        }
        XCTAssertEqual(rows.filter(\.available).map(\.name), ["ffmpeg", "soffice"])
        XCTAssertEqual(rows.filter { !$0.available }.count, 4)
    }

    func testDevelopmentAcceptsLocalToolsButKeepsMissingToolsVisible() {
        let rows = Engines.readiness(requiresBundled: false) { name in
            name == "gs" ? nil : URL(fileURLWithPath: "/opt/homebrew/bin/\(name)")
        }
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.filter(\.available).count, 5)
        XCTAssertEqual(rows.first { !$0.available }?.name, "gs")
        XCTAssertTrue(rows.filter(\.available).allSatisfy { $0.source == .local })
    }
}
