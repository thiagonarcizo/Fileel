import AppKit
import ServiceManagement
import SwiftUI

// use a native settings window and grouped forms, with feedback preferences kept independent
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Fileel Settings"
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "FileelSettingsToolbar")
        let hosting = NSHostingView(rootView: SettingsView().frame(minWidth: 720, minHeight: 560))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.minSize = NSSize(width: 720, height: 560)
        window.setContentSize(NSSize(width: 720, height: 560))
        window.setFrameAutosaveName("FileelSettings")
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @AppStorage("settingsPane") private var pane = "General"
    @AppStorage("dragEnabled") private var dragEnabled = true
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage("soundsEnabled") private var sounds = false
    @AppStorage("preserveMetadata") private var preserveMetadata = true
    @AppStorage("keepQuality") private var keepQuality = true
    @AppStorage("revealResults") private var reveal = false
    @AppStorage("outputDirectory") private var outputDirectory = ""
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $pane) {
                Label("General", systemImage: "gearshape").tag("General")
                Label("Conversion", systemImage: "arrow.triangle.2.circlepath").tag("Conversion")
                Label("Engines", systemImage: "shippingbox").tag("Engines")
                Label("About", systemImage: "info.circle").tag("About")
            }.listStyle(.sidebar).frame(width: 170).background(.regularMaterial)
            Divider()
            Form {
                if pane == "General" {
                    Section("Drag and Drop") {
                        Toggle("Enable drag shortcuts", isOn: $dragEnabled)
                        ForEach(MenuMode.allCases) { mode in ShortcutPicker(mode: mode) }
                    }
                    Section("Feedback") {
                        Toggle("Trackpad haptics", isOn: $haptics)
                        Toggle("Selection sounds", isOn: $sounds)
                        Text("Feedback plays when the highlighted option changes. Haptics require a compatible trackpad.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Test Feedback") { SelectionFeedback.play() }
                            Button("Preview Menu…") { WheelPreviewController.shared.show() }
                        }
                    }
                    Section("Startup") {
                        Toggle("Launch at login", isOn: $login).onChange(of: login) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch { loginError = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
                        }
                        if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
                    }
                } else if pane == "Conversion" {
                    Section("Defaults") {
                        Toggle("Keep Quality", isOn: $keepQuality).toggleStyle(.button)
                        Toggle("Preserve metadata", isOn: $preserveMetadata)
                        Toggle("Reveal results in Finder", isOn: $reveal)
                    }
                    Section("Save Results") {
                        Text(outputDirectory.isEmpty ? "Beside the original file" : outputDirectory).textSelection(.enabled)
                        HStack {
                            Button("Choose Folder…") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                if panel.runModal() == .OK { outputDirectory = panel.url?.path ?? "" }
                            }
                            Button("Use Original Folder") { outputDirectory = "" }.disabled(outputDirectory.isEmpty)
                        }
                        Text("Existing files are never overwritten by conversions.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if pane == "Engines" {
                    Section("Installed Locally") {
                        ForEach(["ffmpeg", "ffprobe", "pandoc", "soffice", "7zz"], id: \.self) { engine in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(engine, systemImage: Engines.locate(engine) == nil ? "exclamationmark.circle" : "checkmark.circle")
                                Text(Engines.locate(engine)?.path ?? "Not installed").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Text("Media uses FFmpeg, documents use Pandoc and LibreOffice, and encrypted ZIP uses 7-Zip. Pages output requires Apple Pages. Engines are currently discovered on this Mac; release packaging is still in development.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Fileel") {
                        Text("Local file conversion and tools for Mac.")
                        LabeledContent("Version", value: "0.0.1 — Development")
                        LabeledContent("Architecture", value: "Apple Silicon")
                        Text("Independent implementation. Fileel is not affiliated with Tangerine. Third-party engines retain their own licenses.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(pane)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// swapping an assigned key keeps the three shortcuts distinct
struct ShortcutPicker: View {
    let mode: MenuMode
    @AppStorage private var key: String

    init(mode: MenuMode) {
        self.mode = mode
        _key = AppStorage(wrappedValue: mode.defaultKey, "key.\(mode.rawValue)")
    }

    var body: some View {
        Picker(mode.rawValue, selection: $key) {
            Text("⇧ Shift").tag("shift")
            Text("⌘ Command").tag("command")
            Text("⌃ Control").tag("control")
            Text("⌥ Option").tag("option")
        }.onChange(of: key) { old, new in
            for other in MenuMode.allCases where other != mode {
                let otherKey = "key.\(other.rawValue)"
                if (UserDefaults.standard.string(forKey: otherKey) ?? other.defaultKey) == new {
                    UserDefaults.standard.set(old, forKey: otherKey)
                }
            }
        }
    }
}
