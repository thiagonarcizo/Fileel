import AppKit
import Combine
import QuickLookThumbnailing
import SwiftUI

// request previews asynchronously so large documents never block a floating shelf
@MainActor
final class FileThumbnailModel: ObservableObject {
    @Published var image: NSImage?
    private var request: QLThumbnailGenerator.Request?
    private var generation = UUID()

    func load(_ url: URL) {
        cancel()
        let token = generation
        let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 480, height: 360), scale: 2, representationTypes: .all)
        self.request = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let model = self else { return }
            Task { @MainActor in
                guard model.generation == token else { return }
                model.image = representation?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }

    func cancel() {
        if let request { QLThumbnailGenerator.shared.cancel(request) }
        request = nil
        generation = UUID()
    }
}

// a borderless utility panel keeps the shelf independent of the current app and space
@MainActor
private final class FloatingShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// one shelf collects files across separate radial-menu actions for the whole session
@MainActor
final class FloatingShelfModel: ObservableObject {
    static let shared = FloatingShelfModel()
    @Published private(set) var files: [URL] = []
    func add(_ urls: [URL]) {
        var known = Set(files)
        for url in urls.map(\.standardizedFileURL) where known.insert(url).inserted { files.append(url) }
    }
    func remove(_ url: URL) { files.removeAll { $0 == url } }
}

@MainActor
final class FloatWindowController: NSWindowController {
    static let shared = FloatWindowController()
    private var placed = false
    private init() {
        let rect = NSRect(x: 0, y: 0, width: 260, height: 310)
        let panel = FloatingShelfPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Floating Files"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: FloatingShelf(close: { [weak panel] in panel?.close() }))
        hosting.sizingOptions = []
        hosting.frame = rect
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        super.init(window: panel)
    }
    required init?(coder: NSCoder) { nil }

    func add(_ files: [URL]) {
        FloatingShelfModel.shared.add(files)
        resizeShelf()
        if !placed { window?.center(); placed = true }
        window?.orderFrontRegardless()
    }

    // grow around the current position and keep the shelf on the display where the user left it
    func resizeShelf() {
        let count = FloatingShelfModel.shared.files.count
        guard count > 0, let window else { window?.close(); return }
        let width = count == 1 ? 260.0 : min(660, Double(count) * 190 + 36)
        var frame = window.frame
        frame.size = NSSize(width: width, height: 310)
        if let screen = window.screen {
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX - width))
            frame.origin.y = max(screen.visibleFrame.minY, min(frame.origin.y, screen.visibleFrame.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
    }
}

// provide an explicit native drag handle instead of relying on swiftui background hit testing
private struct ShelfDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> ShelfDragView { ShelfDragView() }
    func updateNSView(_ view: ShelfDragView, context: Context) { }
}
private final class ShelfDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

// thumbnails carry the visual hierarchy while the original file URLs remain the drag payload
private struct FloatingShelf: View {
    @ObservedObject private var shelf = FloatingShelfModel.shared
    private var files: [URL] { shelf.files }
    var close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                ShelfDragRegion()
                    .overlay(alignment: .leading) {
                        HStack(spacing: 6) {
                            Image(systemName: "pin.fill").font(.system(size: 10))
                            Text(files.count == 1 ? "Floating File" : "\(files.count) Floating Files").font(.system(size: 11, weight: .medium))
                        }.allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                    .accessibilityLabel("Move floating files")
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).frame(width: 22, height: 22).contentShape(Circle())
                    .help("Close shelf").accessibilityLabel("Close floating files")
            }.foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(files, id: \.self) { file in FloatingFileCard(url: file, wide: files.count == 1) }
                }.padding(.horizontal, 2)
            }.scrollIndicators(.hidden).frame(height: 202)
            HStack(spacing: 4) {
                Image(systemName: "hand.draw").font(.system(size: 10))
                Text("Drag a preview into any app").font(.system(size: 10))
            }.foregroundStyle(.secondary)
        }
        .padding(18)
        .modifier(ShelfMaterial(opaque: reduceTransparency))
        .padding(1)
        .dropDestination(for: URL.self) { urls, _ in
            FloatWindowController.shared.add(urls)
            return !urls.isEmpty
        }
        .onChange(of: files.count) { _, _ in FloatWindowController.shared.resizeShelf() }
        .accessibilityLabel("Floating files")
    }
}

private struct FloatingFileCard: View {
    let url: URL
    let wide: Bool
    @StateObject private var thumbnail = FileThumbnailModel()
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.035))
                if let image = thumbnail.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(10)
                        .shadow(color: .black.opacity(0.15), radius: 7, y: 4)
                } else { ProgressView().controlSize(.small) }
            }
            .frame(width: wide ? 218 : 172, height: 160)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovered ? Color.accentColor.opacity(0.5) : .primary.opacity(0.06), lineWidth: 1))
            Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center).lineLimit(2).frame(height: 32, alignment: .top)
        }
        .frame(width: wide ? 218 : 172)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .onDrag { NSItemProvider(object: url as NSURL) }
        .contextMenu {
            Button("Remove from Shelf") { FloatingShelfModel.shared.remove(url) }
            Divider()
            Button("Quick Look") { QuickLookController.shared.show([url]) }
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .task(id: url) { thumbnail.load(url) }
        .onDisappear { thumbnail.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityHint("Drag to another app, or open the context menu for more actions")
    }
}

// let the system draw the glass and its lighting instead of baking a translucent rectangle
private struct ShelfMaterial: ViewModifier {
    let opaque: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !opaque {
            content.glassEffect(.regular, in: .rect(cornerRadius: 23))
        } else {
            content.background(opaque ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 23))
        }
    }
}
