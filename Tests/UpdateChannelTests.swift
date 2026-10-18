import XCTest
@testable import FileelCore

// channel choices survive ordinary updates but follow an explicitly installed channel change
final class UpdateChannelTests: XCTestCase {
    func testNewInstallsAndInvalidPreferencesUseTheInstalledChannel() {
        for channel in UpdateChannel.allCases {
            XCTAssertEqual(UpdateChannel.initialSelection(stored: nil, installed: channel, previousInstalled: nil), channel)
            XCTAssertEqual(UpdateChannel.initialSelection(stored: "invalid", installed: channel, previousInstalled: nil), channel)
        }
    }

    func testOptingOutOfBetaSurvivesAnotherBetaBuild() {
        XCTAssertEqual(UpdateChannel.initialSelection(stored: "stable", installed: .beta, previousInstalled: "beta"), .stable)
        XCTAssertEqual(UpdateChannel.initialSelection(stored: "beta", installed: .stable, previousInstalled: "stable"), .beta)
    }

    func testInstallingTheOtherChannelFollowsItsFeed() {
        XCTAssertEqual(UpdateChannel.initialSelection(stored: "stable", installed: .beta, previousInstalled: "stable"), .beta)
        XCTAssertEqual(UpdateChannel.initialSelection(stored: "beta", installed: .stable, previousInstalled: "beta"), .stable)
        XCTAssertEqual(UpdateChannel.stable.branch, "main")
        XCTAssertEqual(UpdateChannel.beta.branch, "dev")
        XCTAssertNotEqual(UpdateChannel.stable.feedURL, UpdateChannel.beta.feedURL)
        XCTAssertEqual(UpdateChannel.stable.feedURL.scheme, "https")
        XCTAssertEqual(UpdateChannel.beta.feedURL.scheme, "https")
    }
}
