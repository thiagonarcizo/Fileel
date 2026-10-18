import Foundation

// channels share one bundle identity and data store while selecting separate published release feeds
enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable, beta
    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Beta" }
    var branch: String { self == .stable ? "main" : "dev" }
    var feedURL: URL { URL(string: "https://raw.githubusercontent.com/thiagonarcizo/Fileel/updates/\(rawValue)/appcast.xml")! }

    static func initialSelection(stored: String?, installed: UpdateChannel, previousInstalled: String?) -> UpdateChannel {
        if let previousInstalled, previousInstalled != installed.rawValue { return installed }
        return stored.flatMap(UpdateChannel.init(rawValue:)) ?? installed
    }
}
