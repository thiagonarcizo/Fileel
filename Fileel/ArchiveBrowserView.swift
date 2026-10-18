import AppKit
import SwiftUI
import UniformTypeIdentifiers

// retain each browser independently so several archives can stay open beside finder
@MainActor
final class ArchiveWindowController: NSWindowController, NSWindowDelegate {
    private static var sessions: [UUID: ArchiveWindowController] = [:]
    private let sessionID = UUID()

    static func show(files: [URL]) {
        guard !files.isEmpty else { return }
        let controller = ArchiveWindowController(files: files)
        sessions[controller.sessionID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(files: [URL]) {
        let rect = NSRect(x: 0, y: 0, width: 840, height: 620)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = files.count == 1 ? files[0].lastPathComponent : "Browse Archives"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ArchiveBrowserView(files: files))
        host.sizingOptions = []
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.minSize = NSSize(width: 680, height: 480)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { Self.sessions.removeValue(forKey: sessionID) }
}

// browse names and sizes without unpacking anything, then extract beside the source on demand
private struct ArchiveBrowserView: View {
    let files: [URL]
    @State private var archiveIndex = 0
    @State private var contents: ArchiveContents?
    @State private var folder = ""
    @State private var query = ""
    @State private var selection: String?
    @State private var loading = true
    @State private var loadError: String?
    @State private var extractionError: String?
    @State private var extracting = false
    @State private var outputs: [URL] = []
    @State private var extractionRunner: ProcessRunner?
    @State private var extractionTask: Task<Void, Never>?
    @State private var reload = UUID()

    private var archive: URL { files[archiveIndex] }
    private var rows: [ArchiveEntry] { contents?.children(of: folder, matching: query) ?? [] }
    private var selectedFolder: ArchiveEntry? { rows.first { $0.path == selection && $0.isDirectory } }
    private var destination: URL { archive.deletingLastPathComponent() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            navigation
            Divider()
            Group {
                if loading {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Reading archive…").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn’t Read Archive", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError).textSelection(.enabled)
                    } actions: {
                        Button("Try Again") { reload = UUID() }
                    }
                } else if rows.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "This Folder Is Empty" : "No Matching Files",
                                           systemImage: query.isEmpty ? "folder" : "magnifyingglass",
                                           description: Text(query.isEmpty ? "There’s nothing here to browse." : "Try another name or clear the search."))
                } else {
                    fileTable
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: "\(archiveIndex)-\(reload)") { await load() }
        .onChange(of: query) { _, _ in selection = nil }
        .onDisappear { extractionRunner?.cancel(); extractionTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: archive.path))
                .resizable().frame(width: 48, height: 48).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(archive.lastPathComponent)
                    .font(.system(size: 25, weight: .medium, design: .serif)).lineLimit(1).truncationMode(.middle)
                    .help(archive.path)
                if let contents, !loading {
                    Text("\(contents.fileCount) files · \(contents.folderCount) folders · \(size(contents.expandedSize)) expanded")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text("Archive contents").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if files.count > 1 {
                Picker("Archive", selection: $archiveIndex) {
                    ForEach(files.indices, id: \.self) { index in Text(files[index].lastPathComponent).tag(index) }
                }.labelsHidden().frame(maxWidth: 200).disabled(extracting)
            }
        }.padding(.horizontal, 24).padding(.vertical, 22)
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            Button {
                navigate(to: (folder as NSString).deletingLastPathComponent)
            } label: { Image(systemName: "chevron.left") }
                .disabled(folder.isEmpty || !query.isEmpty || loading)
                .help("Enclosing folder").accessibilityLabel("Enclosing folder")
                .keyboardShortcut(.upArrow, modifiers: .command)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Contents", systemImage: "archivebox") { navigate(to: "") }
                    ForEach(Array(folder.split(separator: "/").enumerated()), id: \.offset) { index, component in
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                        Button(String(component)) {
                            navigate(to: folder.split(separator: "/").prefix(index + 1).joined(separator: "/"))
                        }
                    }
                }.buttonStyle(.plain).font(.system(size: 12)).padding(.vertical, 4)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search archive", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(7).frame(width: 190)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.5)))
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var fileTable: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 10) {
                    Image(nsImage: icon(for: entry)).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                        if !query.isEmpty, !entry.parent.isEmpty {
                            Text(entry.parent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    if entry.isDirectory {
                        Button { navigate(to: entry.path) } label: {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }.buttonStyle(.borderless).help("Open \(entry.name)").accessibilityLabel("Open \(entry.name)")
                    }
                }
                .padding(.vertical, 5).contentShape(Rectangle())
                .onTapGesture(count: 2) { if entry.isDirectory { navigate(to: entry.path) } }
                .contextMenu {
                    if entry.isDirectory { Button("Open Folder") { navigate(to: entry.path) } }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.path, forType: .string)
                    }
                }
            }.width(min: 260, ideal: 400)
            TableColumn("Kind") { entry in
                Text(kind(for: entry)).foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 90, ideal: 130)
            TableColumn("Size") { entry in
                Text(size(entry.size)).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }.width(90)
        }
        .alternatingRowBackgrounds()
        .onKeyPress(.return) {
            guard let selectedFolder else { return .ignored }
            navigate(to: selectedFolder.path)
            return .handled
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let extractionError {
                Label(extractionError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(outputs.isEmpty ? "Extract beside original" : "Extraction complete",
                          systemImage: outputs.isEmpty ? "folder" : "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text(outputs.first?.lastPathComponent ?? "A new folder in \(destination.lastPathComponent)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(outputs.first?.path ?? destination.path)
                }
                Spacer(minLength: 0)
                if extracting {
                    ProgressView().controlSize(.small)
                    Text("Extracting…").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { extractionRunner?.cancel() }
                } else if !outputs.isEmpty {
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Extract All", systemImage: "arrow.down.to.line") { extract() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(loading || loadError != nil || contents?.entries.isEmpty != false)
                        .keyboardShortcut("e", modifiers: .command)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func navigate(to path: String) {
        folder = path == "." ? "" : path
        query = ""
        selection = nil
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func kind(for entry: ArchiveEntry) -> String {
        entry.isDirectory ? "Folder" : UTType(filenameExtension: (entry.name as NSString).pathExtension)?.localizedDescription ?? "File"
    }
    private func icon(for entry: ArchiveEntry) -> NSImage {
        NSWorkspace.shared.icon(for: entry.isDirectory ? .folder : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
    }

    private func load() async {
        loading = true; contents = nil; loadError = nil; extractionError = nil; outputs = []
        navigate(to: "")
        let input = archive
        let runner = ProcessRunner()
        let worker = Task.detached(priority: .userInitiated) { try ArchiveContents.read(input, runner: runner) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { runner.cancel() })
            try Task.checkCancellation()
            contents = result
            loading = false
        } catch is CancellationError { }
        catch { if !Task.isCancelled { loadError = error.localizedDescription; loading = false } }
    }

    private func extract() {
        guard !extracting else { return }
        extracting = true; extractionError = nil
        let input = archive
        let runner = ProcessRunner()
        extractionRunner = runner
        // this action always targets the archive's own folder, regardless of conversion defaults
        var options = OperationOptions()
        options.outputDirectory = input.deletingLastPathComponent()
        let snapshot = options
        extractionTask = Task {
            defer { extracting = false; extractionRunner = nil; extractionTask = nil }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ConversionEngine.perform(.tool(.extract), inputs: [input], options: snapshot, runner: runner)
                }.value
                try Task.checkCancellation()
                outputs = result
            } catch is CancellationError { }
            catch { extractionError = error.localizedDescription }
        }
    }
}
