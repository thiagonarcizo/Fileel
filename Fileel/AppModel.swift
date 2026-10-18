import AppKit
import Combine
import SwiftUI
import QuickLookUI

// keep observable UI state on the main actor and send immutable work to background tasks
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var files: [URL] = []
    @Published var previewFile: URL?
    @Published var section = "Files"
    @Published var mode: MenuMode = .convert
    @Published var selection: FileOperation?
    @Published var options = OperationOptions()
    @Published var jobs: [Job] = []
    @Published var workspaceJobID: UUID?
    @Published var busy = false
    private var runner: ProcessRunner?
    private var task: Task<Void, Never>?

    // workspace feedback belongs to its current file selection, not the latest global job
    var workspaceJob: Job? { jobs.first { $0.id == workspaceJobID } }
    var operations: [FileOperation] { Catalog.operations(for: files, mode: mode) }
    var requirement: String? { OperationRequirements.issue(for: selection, inputs: files, options: options) }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { setFiles(panel.urls) }
    }

    func setFiles(_ urls: [URL]) {
        workspaceJobID = nil
        files = Array(NSOrderedSet(array: urls)) as? [URL] ?? urls
        previewFile = files.first
        section = "Files"
        selection = nil
        options = defaults()
    }

    func selectOperation(_ operation: FileOperation?) {
        workspaceJobID = nil
        selection = operation
        options = defaults()
        if let operation, case .tool(let tool) = operation, tool.needsOptions, !files.isEmpty {
            OperationWindowController.show(files: files, operation: operation)
        }
    }

    func removeFile(_ url: URL) {
        workspaceJobID = nil
        files.removeAll { $0 == url }
        if previewFile == url { previewFile = files.first }
        if let selection, !operations.contains(selection) { self.selection = nil }
    }

    func defaults() -> OperationOptions {
        var options = OperationOptions()
        let defaults = UserDefaults.standard
        options.keepQuality = defaults.object(forKey: "keepQuality") as? Bool ?? true
        // preserve the manual quality between toggles without applying it in keep-quality mode
        let manualQuality = defaults.object(forKey: "quality") as? Double ?? 0.82
        options.quality = options.keepQuality ? 1 : (manualQuality.isFinite ? min(1, max(0.1, manualQuality)) : 0.82)
        options.preserveMetadata = defaults.object(forKey: "preserveMetadata") as? Bool ?? true
        if let path = defaults.string(forKey: "outputDirectory"), !path.isEmpty { options.outputDirectory = URL(fileURLWithPath: path) }
        return options
    }

    func receiveDrop(_ urls: [URL], operation: FileOperation) {
        setFiles(urls)
        // match the inspector group to the operation chosen from the global menu
        mode = operation.mode
        selection = operation
        options = defaults()
        if case .tool(let tool) = operation, tool.needsOptions {
            OperationWindowController.show(files: urls, operation: operation)
        } else {
            run(operation)
        }
    }

    func run(_ operation: FileOperation? = nil, inputs suppliedInputs: [URL]? = nil, options suppliedOptions: OperationOptions? = nil) {
        let inputs = suppliedInputs ?? files
        let snapshot = suppliedOptions ?? options
        guard let operation = operation ?? selection, !inputs.isEmpty else { return }
        // browsing has its own window and never enters the file-writing job queue
        if operation == .tool(.listArchive) {
            ArchiveWindowController.show(files: inputs)
            return
        }
        guard !busy else { return }
        if let issue = OperationRequirements.issue(for: operation, inputs: inputs, options: snapshot) { presentError(issue); return }
        selection = operation
        if case .action(let action) = operation, ![.duplicate, .checksum].contains(action) { perform(action); return }
        let runner = ProcessRunner()
        self.runner = runner
        busy = true
        let id = UUID()
        workspaceJobID = id
        jobs.insert(Job(id: id, title: operation.title.replacingOccurrences(of: "…", with: ""),
                        detail: inputs.map(\.lastPathComponent).joined(separator: ", ")), at: 0)
        task = Task {
            var failure: String?
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ConversionEngine.execute(operation, inputs: inputs, options: snapshot, runner: runner)
                }.value
                let outputs: [URL]
                switch result {
                case .files(let urls): outputs = urls
                case .clipboard(let text):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    outputs = []
                    if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].detail = "Copied \(text.count) characters to the clipboard" }
                }
                if let index = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[index].state = .completed
                    jobs[index].outputs = outputs
                }
                if UserDefaults.standard.bool(forKey: "revealResults") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            } catch is CancellationError {
                updateJob(id, state: .cancelled, detail: "Cancelled")
            } catch {
                updateJob(id, state: .failed, detail: error.localizedDescription)
                failure = error.localizedDescription
            }
            busy = false
            self.runner = nil
            task = nil
            // a failed wheel action needs only its warning, never a workspace behind it
            if let failure { presentError(failure) }
        }
    }

    func cancel() { runner?.cancel() }

    // native alerts can appear on their own while the app stays a menu bar utility
    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Operation Couldn’t Finish"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func updateJob(_ id: UUID, state: Job.State, detail: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].detail = detail
    }

    private func perform(_ action: FileAction) {
        switch action {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(files as [NSURL])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
        case .move:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Move"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            do {
                for file in files {
                    guard file.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else { continue }
                    let target = OutputTransaction.uniqueURL(in: folder, name: file.lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: target)
                }
            } catch { presentError(error.localizedDescription) }
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
                presentError("AirDrop is unavailable for this selection.")
                return
            }
            service.perform(withItems: files)
        case .float:
            FloatWindowController.shared.add(files)
        case .terminal:
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            let folders = Array(Set(files.map { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent()
            }))
            NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: .init()) { _, error in
                if let error { Task { @MainActor in self.presentError(error.localizedDescription) } }
            }
        case .quickLook: QuickLookController.shared.show(files)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(files)
        case .rename:
            if let renamed = QuickOperationDialog.rename(files) { setFiles(renamed) }
        case .duplicate, .checksum: break
        }
    }
}

// retain the quick look data source for as long as the shared preview is visible
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var files: [URL] = []

    func show(_ files: [URL]) {
        self.files = files
        NSApp.activate(ignoringOtherApps: true)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { files.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { files[index] as NSURL }
}

// history is kept in memory and never records private paths on disk
struct Job: Identifiable {
    enum State { case running, completed, failed, cancelled }
    let id: UUID
    var title: String
    var detail: String
    var state: State = .running
    var outputs: [URL] = []
}
