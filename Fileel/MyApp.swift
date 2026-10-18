import AppKit
import SwiftUI

// retain the drag coordinator for the whole app lifetime
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let dragController = DragController()
    func applicationWillFinishLaunching(_ notification: Notification) {
        // stay out of the dock and app switcher even when a utility window is open
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.showWorkspace = { WorkspaceWindowController.shared.show() }
        dragController.start()
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") { OnboardingWindowController.shared.show() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        dragController.stop()
        AppModel.shared.cancel()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.setFiles(urls)
        WorkspaceWindowController.shared.show()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }
}

@main
struct FileelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("dragEnabled") private var dragEnabled = true

    var body: some Scene {
        MenuBarExtra {
            Text("Fileel").font(.headline)
            Toggle("Drag Shortcuts", isOn: $dragEnabled)
            Button("Welcome to Fileel…") { OnboardingWindowController.shared.show() }
            Button("Preview Radial Menu…") { WheelPreviewController.shared.show() }
            Divider()
            Button("Open File Editor…") { WorkspaceWindowController.shared.show() }
            Button("Choose Files…") { WorkspaceWindowController.shared.show(); AppModel.shared.chooseFiles() }
            Divider()
            Button("Settings…") { SettingsWindowController.shared.show() }
            Divider()
            Button("Quit Fileel") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(nsImage: FileelIcon.menuBarImage).accessibilityLabel("Fileel")
        }.commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { SettingsWindowController.shared.show() }.keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .newItem) {
                    Button("Choose Files…") { WorkspaceWindowController.shared.show(); AppModel.shared.chooseFiles() }.keyboardShortcut("o", modifiers: .command)
                    Button("Show Fileel") { WorkspaceWindowController.shared.show() }
                }
            }
    }
}

// appkit owns window sizing while swiftui lays out content inside explicit bounds
@MainActor
final class WorkspaceWindowController: NSWindowController {
    static let shared = WorkspaceWindowController()
    private init() {
        let rect = NSRect(x: 0, y: 0, width: 960, height: 680)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Fileel"
        let hosting = NSHostingView(rootView: ContentView())
        hosting.sizingOptions = []
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.minSize = NSSize(width: 820, height: 600)
        window.setContentSize(rect.size)
        window.setFrameAutosaveName("FileelWorkspace")
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { nil }
    func show() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}
