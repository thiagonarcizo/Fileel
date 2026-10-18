import AppKit
import Combine
import Sparkle

// keep update verification and installation inside sparkle instead of running downloaded scripts
@MainActor
final class UpdaterManager: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdaterManager()
    let installedChannel: UpdateChannel
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var updateVersion: String?
    @Published var automaticChecks = true {
        didSet {
            if controller != nil, controller.updater.automaticallyChecksForUpdates != automaticChecks {
                controller.updater.automaticallyChecksForUpdates = automaticChecks
            }
        }
    }
    @Published var channel: UpdateChannel {
        didSet {
            guard oldValue != channel else { return }
            UserDefaults.standard.set(channel.rawValue, forKey: "updateChannel")
            updateVersion = nil
            if started { controller.updater.resetUpdateCycle() }
        }
    }
    private var controller: SPUStandardUpdaterController!
    private var started = false
    private var subscriptions = Set<AnyCancellable>()
    private var installWait: AnyCancellable?

    var enabledInThisBuild: Bool {
        #if DEBUG && !FILEEL_UPDATE_QA
        false
        #else
        true
        #endif
    }

    private override init() {
        let installed: UpdateChannel = Bundle.main.object(forInfoDictionaryKey: "FileelUpdateBranch") as? String == "dev" ? .beta : .stable
        installedChannel = installed
        let defaults = UserDefaults.standard
        let selected = UpdateChannel.initialSelection(stored: defaults.string(forKey: "updateChannel"), installed: installed,
                                                       previousInstalled: defaults.string(forKey: "lastInstalledUpdateChannel"))
        channel = selected
        defaults.set(selected.rawValue, forKey: "updateChannel")
        defaults.set(installed.rawValue, forKey: "lastInstalledUpdateChannel")
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] value in
            guard let self else { return }; self.canCheckForUpdates = self.enabledInThisBuild && value
        }.store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).sink { [weak self] value in
            if self?.automaticChecks != value { self?.automaticChecks = value }
        }.store(in: &subscriptions)
    }

    func start() {
        guard enabledInThisBuild, !started else { return }
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard enabledInThisBuild else { return }
        // accessory apps can activate their update window without adding a dock icon
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        #if FILEEL_UPDATE_QA
        let base = ProcessInfo.processInfo.environment["FILEEL_UPDATE_QA_BASE"] ?? "http://127.0.0.1:8769"
        if Bundle.main.bundleIdentifier == "xyz.narcizo.Fileel.UpdateQA", URL(string: base)?.host == "127.0.0.1" {
            return "\(base)/\(channel.branch)/appcast.xml"
        }
        #endif
        return channel.feedURL.absoluteString
    }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel == .beta ? ["beta"] : [] }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverDidShowModalAlert() { NSApp.activate(ignoringOtherApps: true) }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updateVersion = update.displayVersionString
    }
    func standardUserDriverWillFinishUpdateSession() { updateVersion = nil }

    // finish the current file operation before the updater replaces and relaunches the app
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard AppModel.shared.busy else { return false }
        installWait = AppModel.shared.$busy.filter { !$0 }.first().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.installWait = nil
            installHandler()
        }
        return true
    }
}
