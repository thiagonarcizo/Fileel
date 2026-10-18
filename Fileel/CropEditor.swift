import AppKit
import SwiftUI

// a persistent frame with handles replaces the rubber-band area selection
struct CropOverlay: NSViewRepresentable {
    let size: CGSize
    @Binding var options: OperationOptions
    var inset: CGFloat = 24
    var alignment = 1
    var pause: () -> Void = { }

    func makeNSView(context: Context) -> CropFrameView { CropFrameView() }
    func updateNSView(_ view: CropFrameView, context: Context) {
        view.sourceSize = size
        view.inset = inset
        view.crop = CropGeometry.rectangle(options: options, size: size)
        view.ratio = CropGeometry.ratio(options: options, size: size)
        view.onBegin = pause
        view.onCrop = { CropGeometry.apply($0, to: &options, alignment: alignment) }
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

// appkit handles corners, edges, moving, and keyboard nudges without swallowing image gestures
final class CropFrameView: NSView {
    var sourceSize = CGSize.zero
    var crop = CGRect.zero
    var ratio: Double?
    var inset: CGFloat = 24
    var onCrop: ((CGRect) -> Void)?
    var onBegin: (() -> Void)?
    private var drag: (handle: CropGeometry.Handle, point: CGPoint, rect: CGRect)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var fitted: CGRect { CanvasGeometry.imageRect(size: sourceSize, in: bounds, inset: inset) }
    private var box: CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        return CGRect(x: fitted.minX + crop.minX / sourceSize.width * fitted.width,
                      y: fitted.minY + crop.minY / sourceSize.height * fitted.height,
                      width: crop.width / sourceSize.width * fitted.width, height: crop.height / sourceSize.height * fitted.height)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Crop frame")
        setAccessibilityHelp("Drag a handle to resize, drag inside to move, or use arrow keys to nudge the crop")
    }
    required init?(coder: NSCoder) { nil }

    private func point(for handle: CropGeometry.Handle) -> CGPoint {
        CGPoint(x: handle.horizontal < 0 ? box.minX : handle.horizontal > 0 ? box.maxX : box.midX,
                y: handle.vertical < 0 ? box.minY : handle.vertical > 0 ? box.maxY : box.midY)
    }
    private func handle(at point: CGPoint) -> CropGeometry.Handle? {
        if let hit = CropGeometry.Handle.allCases.first(where: { $0 != .move && hypot(self.point(for: $0).x - point.x, self.point(for: $0).y - point.y) <= 13 }) { return hit }
        return box.contains(point) ? .move : nil
    }
    override func resetCursorRects() {
        addCursorRect(box, cursor: .openHand)
        for handle in CropGeometry.Handle.allCases where handle != .move {
            let center = point(for: handle)
            let cursor: NSCursor = handle.horizontal == 0 ? .resizeUpDown : handle.vertical == 0 ? .resizeLeftRight : .crosshair
            addCursorRect(CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20), cursor: cursor)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !box.isEmpty, sourceSize.width > 0 else { return }
        let mask = NSBezierPath(rect: fitted)
        mask.appendRect(box); mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill(); mask.fill()
        let frame = NSBezierPath(rect: box)
        NSColor.black.withAlphaComponent(0.6).setStroke(); frame.lineWidth = 3; frame.stroke()
        NSColor.white.setStroke(); frame.lineWidth = 1; frame.stroke()
        let grid = NSBezierPath()
        for fraction in [1.0 / 3, 2.0 / 3] {
            grid.move(to: CGPoint(x: box.minX + box.width * fraction, y: box.minY))
            grid.line(to: CGPoint(x: box.minX + box.width * fraction, y: box.maxY))
            grid.move(to: CGPoint(x: box.minX, y: box.minY + box.height * fraction))
            grid.line(to: CGPoint(x: box.maxX, y: box.minY + box.height * fraction))
        }
        NSColor.white.withAlphaComponent(drag == nil ? 0.2 : 0.55).setStroke(); grid.lineWidth = 0.75; grid.stroke()
        let handles = NSBezierPath()
        for handle in CropGeometry.Handle.allCases where handle != .move {
            let p = point(for: handle)
            if handle.horizontal != 0, handle.vertical != 0 {
                let dx = CGFloat(handle.horizontal) * -16, dy = CGFloat(handle.vertical) * -16
                handles.move(to: CGPoint(x: p.x + dx, y: p.y)); handles.line(to: p); handles.line(to: CGPoint(x: p.x, y: p.y + dy))
            } else if handle.horizontal == 0 {
                handles.move(to: CGPoint(x: p.x - 10, y: p.y)); handles.line(to: CGPoint(x: p.x + 10, y: p.y))
            } else {
                handles.move(to: CGPoint(x: p.x, y: p.y - 10)); handles.line(to: CGPoint(x: p.x, y: p.y + 10))
            }
        }
        NSColor.white.setStroke(); handles.lineWidth = 3; handles.lineCapStyle = .square; handles.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let handle = handle(at: location), fitted.width > 0 else { return }
        window?.makeFirstResponder(self)
        onBegin?()
        drag = (handle, location, crop)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag, fitted.width > 0, fitted.height > 0 else { return }
        let location = convert(event.locationInWindow, from: nil)
        let delta = CGSize(width: (location.x - drag.point.x) / fitted.width * sourceSize.width,
                           height: (location.y - drag.point.y) / fitted.height * sourceSize.height)
        onCrop?(CropGeometry.change(drag.rect, handle: drag.handle, delta: delta, size: sourceSize, ratio: ratio))
    }
    override func mouseUp(with event: NSEvent) { drag = nil; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let drag { onCrop?(drag.rect); self.drag = nil; needsDisplay = true; return }
        let amount = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        let delta: CGSize
        switch event.keyCode {
        case 123: delta = CGSize(width: -amount, height: 0)
        case 124: delta = CGSize(width: amount, height: 0)
        case 125: delta = CGSize(width: 0, height: amount)
        case 126: delta = CGSize(width: 0, height: -amount)
        default: super.keyDown(with: event); return
        }
        onCrop?(CropGeometry.change(crop, handle: .move, delta: delta, size: sourceSize, ratio: ratio))
    }
}

// keep aspect choices prominent and exact pixel entry available without dominating the crop workflow
struct CropInspector: View {
    let size: CGSize
    @Binding var options: OperationOptions
    var alignment = 1
    @State private var precision = false
    private let aspects = ["free", "original", "1:1", "4:3", "3:2", "16:9", "5:4", "7:5"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Aspect Ratio", systemImage: "aspectratio").font(.system(size: 12, weight: .semibold))
                    Picker("Aspect Ratio", selection: Binding(get: { options.cropAspect }, set: selectAspect)) {
                        ForEach(aspects, id: \.self) { value in Text(value == "free" ? "Freeform" : value == "original" ? "Original" : value).tag(value) }
                    }.labelsHidden()
                    HStack(spacing: 8) {
                        Button(action: toggleLock) {
                            Label(options.cropAspectLocked ? "Locked" : "Unlocked", systemImage: options.cropAspectLocked ? "lock" : "lock.open")
                        }.help("Lock aspect ratio")
                        Button {
                            options.cropPortrait.toggle()
                            if options.cropAspectLocked { fitAspect() }
                        } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .help("Swap landscape and portrait").accessibilityLabel("Swap crop orientation")
                            .disabled(!options.cropAspectLocked || options.cropAspect == "1:1")
                    }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(options.width) × \(options.height)").font(.system(size: 22, weight: .medium).monospacedDigit())
                    Text("Drag an edge or corner to resize. Drag inside the frame to reposition.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                DisclosureGroup("Pixel Dimensions", isExpanded: $precision) {
                    VStack(spacing: 12) {
                        field("Width", value: $options.width)
                        field("Height", value: $options.height)
                        field("X", value: $options.x)
                        field("Y", value: $options.y)
                    }.padding(.top, 12)
                }.font(.system(size: 12))
                Button("Reset Crop") {
                    options.cropAspect = "free"; options.cropAspectLocked = false; options.cropPortrait = false
                    CropGeometry.apply(CGRect(origin: .zero, size: size), to: &options, alignment: alignment)
                }.controlSize(.small)
                Spacer(minLength: 0)
            }.padding(22)
        }
    }
    private func selectAspect(_ value: String) {
        options.cropAspect = value
        options.cropAspectLocked = value != "free"
        if options.cropAspectLocked { fitAspect() }
    }
    private func toggleLock() {
        if !options.cropAspectLocked {
            let rect = CropGeometry.rectangle(options: options, size: size)
            options.cropCustomRatio = rect.height > 0 ? rect.width / rect.height : 1
            options.cropAspect = "free"; options.cropPortrait = false
        }
        options.cropAspectLocked.toggle()
    }
    private func fitAspect() {
        guard let ratio = CropGeometry.ratio(options: options, size: size) else { return }
        CropGeometry.apply(CropGeometry.fitted(ratio: ratio, size: size), to: &options, alignment: alignment)
    }
    private func field(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            TextField(title, value: value, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
            Text("px").foregroundStyle(.tertiary)
        }
    }
}
