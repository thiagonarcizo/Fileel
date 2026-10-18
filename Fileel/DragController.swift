import AppKit
import SwiftUI

// poll modifier state during a mouse drag without asking for keyboard-monitoring permission
@MainActor
final class DragController {
    private var timer: Timer?
    private var panel: NSPanel?
    private var wheel: DropWheelView?
    private var idlePasteboardCount = NSPasteboard(name: .drag).changeCount
    private var wasPressed = false
    private var downPoint = NSPoint.zero
    private var lastFlags: NSEvent.ModifierFlags = []
    private var cancelled = false
    private var candidate = false

    func start() {
        timer = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        dismiss(animated: false)
    }

    private func tick() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let pasteboard = NSPasteboard(name: .drag)
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { wasPressed = pressed; lastFlags = flags }
        guard UserDefaults.standard.object(forKey: "dragEnabled") as? Bool ?? true else { dismiss(); return }
        if !pressed {
            idlePasteboardCount = pasteboard.changeCount
            candidate = false
            cancelled = false
            // defer dismissal so appkit can deliver the drop after mouse-up
            if wasPressed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.dismiss() } }
            return
        }
        if !wasPressed { downPoint = NSEvent.mouseLocation }
        let distance = hypot(NSEvent.mouseLocation.x - downPoint.x, NSEvent.mouseLocation.y - downPoint.y)
        if pasteboard.changeCount != idlePasteboardCount && distance > 4 { candidate = true }
        guard candidate, !cancelled else { return }
        // escape is read only during an active drag and never consumed from another app
        if CGEventSource.keyState(.combinedSessionState, key: 53) { cancelled = true; dismiss(); return }
        guard let mode = Self.selectedMode(flags: flags, previous: lastFlags, hasMenu: wheel != nil) else { return }
        if let wheel {
            wheel.setMode(mode)
            return
        }
        let urls = Self.fileURLs(pasteboard)
        guard !urls.isEmpty, !AppModel.shared.busy else { return }
        show(at: NSEvent.mouseLocation, files: urls, mode: mode)
    }

    static func selectedMode(flags: NSEvent.ModifierFlags, previous: NSEvent.ModifierFlags, hasMenu: Bool) -> MenuMode? {
        let keys: [(String, NSEvent.ModifierFlags)] = [("shift", .shift), ("command", .command), ("control", .control), ("option", .option)]
        func held(_ flags: NSEvent.ModifierFlags) -> Set<String> { Set(keys.filter { flags.contains($0.1) }.map(\.0)) }
        var mappings: [MenuMode: String] = [:]
        for mode in MenuMode.allCases {
            mappings[mode] = UserDefaults.standard.string(forKey: "key.\(mode.rawValue)") ?? mode.defaultKey
        }
        return DragActivation.mode(current: held(flags), previous: held(previous), hasMenu: hasMenu, mappings: mappings)
    }

    private func show(at point: NSPoint, files: [URL], mode: MenuMode) {
        let size = CGFloat(WheelGeometry.canvasSize)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: max(visible.minX, min(point.x - size / 2, visible.maxX - size)),
                             y: max(visible.minY, min(point.y - size / 2, visible.maxY - size)))
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = DropWheelView(frame: NSRect(x: 0, y: 0, width: size, height: size), files: files, mode: mode)
        view.onCancel = { [weak self] in self?.cancelled = true; self?.dismiss() }
        view.onDrop = { [weak self] urls, operation in
            self?.dismiss()
            AppModel.shared.receiveDrop(urls, operation: operation)
        }
        panel.contentView = view
        self.panel = panel
        wheel = view
        panel.orderFrontRegardless()
        view.animateOpening()
    }

    func dismiss(animated: Bool = true) {
        guard let closingPanel = panel else { return }
        let closingWheel = wheel
        panel = nil; wheel = nil
        if animated, let closingWheel { closingWheel.animateClosing { closingPanel.orderOut(nil) } }
        else { closingPanel.orderOut(nil) }
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

// a distinct segmented ring uses native colors, readable labels, and a stable cancel area
@MainActor
final class DropWheelView: NSView {
    private var files: [URL]
    private var mode: MenuMode
    private var operations: [FileOperation]
    private var highlighted: Int?
    var onDrop: (([URL], FileOperation) -> Void)?
    var onCancel: (() -> Void)?
    var preview = false
    private var previewFlags: NSEvent.ModifierFlags = []
    private var tracking: NSTrackingArea?
    private let presentation = WheelPresentation()
    private var hosting: NSHostingView<WheelAppearance>?

    init(frame: NSRect, files: [URL], mode: MenuMode) {
        self.files = files
        self.mode = mode
        operations = Catalog.operations(for: files, mode: mode)
        super.init(frame: frame)
        let hosting = NSHostingView(rootView: WheelAppearance(state: presentation))
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        self.hosting = hosting
        updatePresentation()
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Fileel \(mode.rawValue)")
        setAccessibilityHelp("Drop on an option to apply it, or use the main Fileel window for keyboard and screen reader access.")
    }
    required init?(coder: NSCoder) { nil }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override var acceptsFirstResponder: Bool { preview }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // cancel stays clickable even though the real menu never activates its owner app
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isHub(point) { cancelMenu() }
    }
    override func accessibilityPerformCancel() -> Bool { cancelMenu(); return true }
    private func isHub(_ point: NSPoint) -> Bool { WheelGeometry.isHub(point, center: CGPoint(x: bounds.midX, y: bounds.midY)) }
    private func cancelMenu() {
        if let onCancel { onCancel() }
        else { let closingWindow = window; animateClosing { closingWindow?.close() } }
    }

    // opening and closing use the same center-anchored transform as the native glass content
    func animateOpening() {
        presentation.expanded = false
        DispatchQueue.main.async { [weak self] in self?.presentation.expanded = true }
    }
    func animateClosing(completion: @escaping @MainActor () -> Void) {
        presentation.expanded = false
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.16
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { completion() }
    }

    override func mouseMoved(with event: NSEvent) {
        if preview { updateHighlight(at: convert(event.locationInWindow, from: nil)) }
    }

    // the preview accepts the same modifiers so the real morph can be reviewed without a file drag
    override func flagsChanged(with event: NSEvent) {
        guard preview else { super.flagsChanged(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let next = DragController.selectedMode(flags: flags, previous: previewFlags, hasMenu: true) { setMode(next) }
        previewFlags = flags
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelMenu(); return }
        if preview, [123, 124, 125, 126].contains(event.keyCode), !operations.isEmpty {
            let direction = event.keyCode == 123 || event.keyCode == 126 ? -1 : 1
            highlighted = ((highlighted ?? 0) + direction + operations.count) % operations.count
            setAccessibilityValue(operations[highlighted!].title)
            NSAccessibility.post(element: self, notification: .valueChanged)
            SelectionFeedback.play()
            updatePresentation()
        } else { super.keyDown(with: event) }
    }

    private func updateHighlight(at point: NSPoint) {
        let next = hitIndex(point)
        if next != highlighted {
            highlighted = next
            setAccessibilityValue(next.map { operations[$0].title } ?? "Cancel")
            if next != nil { SelectionFeedback.play() }
            updatePresentation()
        }
    }

    func setMode(_ mode: MenuMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        operations = Catalog.operations(for: files, mode: mode)
        highlighted = nil
        setAccessibilityLabel("Fileel \(mode.rawValue)")
        // the modifier owns this transaction even when no slice is highlighted
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
        withAnimation(animation) { updatePresentation() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // the session's actual pasteboard is authoritative, including drags from other apps
        files = DragController.fileURLs(sender.draggingPasteboard)
        operations = Catalog.operations(for: files, mode: mode)
        updatePresentation()
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        updateHighlight(at: point)
        return files.isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil; updatePresentation() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isHub(convert(sender.draggingLocation, from: nil)) { cancelMenu(); return false }
        return highlighted != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = hitIndex(convert(sender.draggingLocation, from: nil)), operations.indices.contains(index) else { return false }
        let urls = DragController.fileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        let operation = operations[index]
        guard Catalog.operations(for: urls, mode: mode).contains(operation) else { return false }
        DispatchQueue.main.async { [weak self] in self?.onDrop?(urls, operation) }
        return true
    }

    func hitIndex(_ point: NSPoint) -> Int? {
        WheelGeometry(count: operations.count).index(at: point, center: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    // let the glass subview render without intercepting the file drag session
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    private func updatePresentation() {
        presentation.operations = operations
        presentation.mode = mode
        presentation.filename = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        presentation.highlighted = highlighted
    }

}

// provide a harmless interactive preview for checking sound, haptics, and ring legibility
@MainActor
final class WheelPreviewController: NSWindowController {
    static let shared = WheelPreviewController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: WheelGeometry.canvasSize, height: WheelGeometry.canvasSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Fileel Menu Preview"
        window.isOpaque = false
        window.backgroundColor = .clear
        let wheel = DropWheelView(frame: NSRect(x: 0, y: 0, width: WheelGeometry.canvasSize, height: WheelGeometry.canvasSize), files: [URL(fileURLWithPath: "/sample.png")], mode: .tools)
        wheel.preview = true
        window.contentView = wheel
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(wheel)
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        (window?.contentView as? DropWheelView)?.animateOpening()
    }
}

// only selection transitions trigger feedback and each channel has its own preference
@MainActor
enum SelectionFeedback {
    static func play() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "hapticsEnabled") as? Bool ?? true {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if defaults.bool(forKey: "soundsEnabled") { NSSound(named: "Tink")?.play() }
    }
}
