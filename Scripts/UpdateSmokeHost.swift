import AppKit
import Sparkle

// this fixture exercises sparkle's real installer without opening windows or touching the user's app
@MainActor
final class UpdateSmokeHost: NSObject, NSApplicationDelegate, SPUUserDriver, SPUUpdaterDelegate {
    private var updater: SPUUpdater!
    private var configuration: [String: String] = [:]
    private var selected = UpdateChannel.stable
    private var watchdog: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard Bundle.main.bundleIdentifier == "xyz.narcizo.Fileel.UpdateSmoke",
              let path = UserDefaults.standard.string(forKey: "proofConfiguration"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              let address = values["server"], let url = URL(string: address), url.host == "127.0.0.1" else {
            NSApp.terminate(nil)
            return
        }
        configuration = values
        let defaults = UserDefaults.standard
        let installed: UpdateChannel = Bundle.main.object(forInfoDictionaryKey: "FileelUpdateBranch") as? String == "dev" ? .beta : .stable
        selected = UpdateChannel.initialSelection(stored: defaults.string(forKey: "updateChannel"), installed: installed,
                                                  previousInstalled: defaults.string(forKey: "installedUpdateChannel"))
        defaults.set(selected.rawValue, forKey: "updateChannel")
        defaults.set(installed.rawValue, forKey: "installedUpdateChannel")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        record("launch", ["build": build, "installed": installed.rawValue, "selected": selected.rawValue,
                          "marker": defaults.string(forKey: "proofMarker") ?? "missing"])
        if build == configuration["expectedBuild"] {
            record("updated", ["build": build, "marker": defaults.string(forKey: "proofMarker") ?? "missing"])
            NSApp.terminate(nil)
            return
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in
            MainActor.assumeIsolated {
                self.record("timeout")
                NSApp.terminate(nil)
            }
        }
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            let background = configuration["background"] == "true"
            updater.automaticallyChecksForUpdates = background
            if background { updater.checkForUpdatesInBackground() }
            else { updater.checkForUpdates() }
        } catch {
            record("startup-error", ["description": error.localizedDescription])
            NSApp.terminate(nil)
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        configuration["server"].map { "\($0)/\(selected.rawValue)/appcast.xml" }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        selected == .beta ? ["beta"] : []
    }

    func record(_ event: String, _ values: [String: String] = [:]) {
        guard let path = configuration["log"], let data = try? JSONSerialization.data(withJSONObject: values.merging(["event": event]) { _, next in next }, options: [.sortedKeys]) else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([10]))
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { record("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("found", ["version": appcastItem.versionString, "userInitiated": String(state.userInitiated)])
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { record("release-notes-error") }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        record("not-found", ["description": error.localizedDescription])
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let value = error as NSError
        record("update-error", ["domain": value.domain, "code": String(value.code), "description": value.localizedDescription])
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { record("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { }
    func showDownloadDidReceiveData(ofLength length: UInt64) { }
    func showDownloadDidStartExtractingUpdate() { record("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) { }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("ready-to-install")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        record("installing", ["terminated": String(applicationTerminated)])
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        record("installed", ["relaunched": String(relaunched)])
        acknowledgement()
    }
    func dismissUpdateInstallation() { record("dismissed") }
}

@main
enum UpdateSmokeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let host = UpdateSmokeHost()
        app.delegate = host
        withExtendedLifetime(host) { app.run() }
    }
}
