import AppKit
import Combine
import SwiftUI

// cancel stale previews so a slow render cannot replace a more recent adjustment
@MainActor
final class ImagePreviewModel: ObservableObject {
    @Published var image: CGImage?
    @Published var original: CGImage?
    @Published var dimensions = CGSize.zero
    @Published var error: String?
    @Published var rendering = false
    private let renderer = ImagePreviewRenderer()

    func render(url: URL, operation: FileOperation?, options: OperationOptions) async {
        rendering = true
        do {
            let result = try await renderer.render(url: url, operation: operation, options: options)
            try Task.checkCancellation()
            original = result.original
            image = result.rendered
            dimensions = result.dimensions
            rendering = false
            error = nil
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { self.error = error.localizedDescription; rendering = false } }
    }

}

// the preview is useful before a tool is selected and becomes an editing canvas when needed
struct ImageEditorView: View {
    let url: URL
    let operation: FileOperation?
    @Binding var options: OperationOptions
    @StateObject private var preview = ImagePreviewModel()
    var dedicated = false
    var selectedAnnotation: Binding<UUID?>?
    var onDimensions: (CGSize) -> Void = { _ in }
    @State private var restoringHistory = false
    private var kind: ImageAnnotation.Kind { operation == .tool(.redactImage) ? options.redactionKind : options.annotationKind }
    private var markHex: String { operation == .tool(.redactImage) ? options.redactionHex : options.annotationHex }
    private var kindBinding: Binding<ImageAnnotation.Kind> {
        Binding(get: { kind }, set: { value in
            if operation == .tool(.redactImage) { options.redactionKind = value } else { options.annotationKind = value }
        })
    }
    private var markColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(cgColor: ImageEngine.color(markHex)) ?? .red) }, set: { value in
            if operation == .tool(.redactImage) { options.redactionHex = value.hexRGB } else { options.annotationHex = value.hexRGB }
        })
    }
    @State private var compareOriginal = false
    @State private var undoStack: [[ImageAnnotation]] = []
    @State private var redoStack: [[ImageAnnotation]] = []

    private var annotationMode: Bool { operation == .tool(.annotateImage) || operation == .tool(.redactImage) }
    private var cropMode: Bool { operation == .tool(.cropImage) }
    // report the rotated output orientation while keeping crop coordinates in source space
    private var displayDimensions: CGSize {
        if operation == .tool(.rotate), !compareOriginal, [90, 270].contains(options.rotation) {
            return CGSize(width: preview.dimensions.height, height: preview.dimensions.width)
        }
        return preview.dimensions
    }
    private var request: Request { Request(url: url, operation: operation, options: options) }
    private struct Request: Equatable { let url: URL; let operation: FileOperation?; let options: OperationOptions }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(cropMode ? "Crop Preview" : "Preview").font(.headline)
                if preview.rendering { ProgressView().controlSize(.mini).accessibilityLabel("Rendering preview") }
                Spacer()
                if preview.dimensions.width > 0 {
                    Text("\(Int(displayDimensions.width)) × \(Int(displayDimensions.height))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Toggle("Original", isOn: $compareOriginal).toggleStyle(.button).controlSize(.small)
                    .help("Compare with the original image")
            }.padding(.horizontal, 18).padding(.vertical, 12)
            if annotationMode { annotationToolbar }
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let error = preview.error {
                    ContentUnavailableView("Preview Unavailable", systemImage: "photo", description: Text(error))
                } else if let image = compareOriginal ? preview.original : preview.image {
                    ImageCanvas(image: image, dimensions: preview.dimensions, crop: nil,
                                cropEnabled: false,
                                drawing: annotationMode && !compareOriginal ? kind : nil,
                                hex: markHex, text: options.text, thickness: options.annotationThickness, fontScale: options.annotationFontScale, editable: !compareOriginal,
                                onCrop: setCrop, onMark: addMark, onUndo: undo, onRedo: redo)
                        .overlay {
                            if cropMode, !compareOriginal { CropOverlay(size: preview.dimensions, options: $options) }
                        }
                } else { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(cropMode ? "Drag the handles to crop · drag inside to move" : annotationMode ? "Draw on the image · ⌘Z to undo" : "The original file stays unchanged")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if cropMode {
                    Button("Reset Crop") { setCrop(CGRect(origin: .zero, size: preview.dimensions)) }.controlSize(.small)
                }
            }.padding(.horizontal, 18).padding(.vertical, 10)
        }
        .task(id: request) { await preview.render(url: url, operation: operation, options: options) }
        .onChange(of: preview.dimensions) { _, size in
            onDimensions(size)
            if cropMode, options.width <= 0, size.width > 0 { CropGeometry.apply(CGRect(origin: .zero, size: size), to: &options) }
        }
        .onChange(of: operation) { _, operation in
            compareOriginal = false
            undoStack = []; redoStack = []
        }
        .onChange(of: url) { _, _ in undoStack = []; redoStack = [] }
        .onChange(of: options.annotations) { old, _ in
            if restoringHistory { restoringHistory = false }
            else { undoStack.append(old); redoStack = [] }
        }
    }

    private var annotationToolbar: some View {
        HStack(spacing: 6) {
            ForEach(ImageAnnotation.Kind.allCases.filter { item in
                operation == .tool(.redactImage) ? [.cover, .pixelate, .randomPixels, .blur].contains(item) : ![.cover, .pixelate, .randomPixels, .blur].contains(item)
            }) { item in
                Button {
                    kindBinding.wrappedValue = item
                    selectedAnnotation?.wrappedValue = nil
                } label: {
                    Image(systemName: item.symbol).font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(kind == item ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(kind == item ? Color.accentColor : .primary)
                }.buttonStyle(.plain).help(item.title).accessibilityLabel(item.title)
            }
            ColorPicker("Mark Color", selection: markColor, supportsOpacity: false).labelsHidden().help("Color for new marks")
            Spacer(minLength: 0)
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undoStack.isEmpty).help("Undo last edit")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redoStack.isEmpty).help("Redo last edit")
            Button("Clear") { options.annotations = [] }.disabled(options.annotations.isEmpty)
        }.controlSize(.small).padding(.horizontal, 18).padding(.bottom, 10)
    }

    private var cropRectangle: CGRect? {
        guard options.width > 0, options.height > 0 else { return nil }
        return CGRect(x: options.x, y: options.y, width: options.width, height: options.height)
    }
    private func setCrop(_ rect: CGRect) {
        options.x = Int(rect.minX); options.y = Int(rect.minY)
        options.width = Int(rect.width); options.height = Int(rect.height)
    }
    private func addMark(_ mark: ImageAnnotation) {
        var mark = mark
        if mark.kind == .number { mark.text = String(options.annotations.filter { $0.kind == .number }.count + 1) }
        options.annotations.append(mark)
        selectedAnnotation?.wrappedValue = mark.id
    }
    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(options.annotations); restoringHistory = true; options.annotations = previous
    }
    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(options.annotations); restoringHistory = true; options.annotations = next
    }
}

// native pointer events preserve precise drag coordinates and standard keyboard handling
private struct ImageCanvas: NSViewRepresentable {
    let image: CGImage
    let dimensions: CGSize
    let crop: CGRect?
    let cropEnabled: Bool
    let drawing: ImageAnnotation.Kind?
    let hex: String
    let text: String
    let thickness: Double
    let fontScale: Double
    let editable: Bool
    var onCrop: (CGRect) -> Void
    var onMark: (ImageAnnotation) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void

    func makeNSView(context: Context) -> ImageCanvasView { ImageCanvasView() }
    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.image = image; view.dimensions = dimensions; view.crop = crop
        view.thickness = thickness; view.fontScale = fontScale
        view.drawing = drawing; view.hex = hex; view.text = text; view.editable = editable; view.cropEnabled = false
        view.onCrop = onCrop; view.onMark = onMark; view.onUndo = onUndo; view.onRedo = onRedo
        view.needsDisplay = true
    }
}

private final class ImageCanvasView: NSView {
    var image: CGImage?
    var dimensions = CGSize.zero
    var crop: CGRect?
    var cropEnabled = false
    var drawing: ImageAnnotation.Kind?
    var hex = "EF4444"
    var text = ""
    var thickness = 0.006
    var fontScale = 0.05
    private var gestureSeed = UInt64.random(in: 1...UInt64.max)
    var editable = true
    var onCrop: ((CGRect) -> Void)?
    var onMark: ((ImageAnnotation) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    private var start: CGPoint?
    private var end: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var fitted: CGRect { image.map { CanvasGeometry.imageRect(size: CGSize(width: $0.width, height: $0.height), in: bounds) } ?? .zero }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image preview")
        setAccessibilityHelp("Use the inspector fields as an alternative to drawing or cropping with the pointer.")
    }
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        if editable, cropEnabled || drawing != nil { addCursorRect(fitted, cursor: .crosshair) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = fitted
        var display = image
        if let drawing, let start, let end {
            let label = drawing == .text && text.isEmpty ? "Text" : text
            let mark = ImageAnnotation(kind: drawing, startX: start.x, startY: start.y, endX: end.x, endY: end.y,
                                       text: label, hex: hex, thickness: thickness, fontScale: fontScale, seed: gestureSeed)
            display = (try? ImageDrawing.annotated(image, marks: [mark])) ?? image
        }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(display, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
        var selection: CGRect?
        if drawing == nil, let start, let end {
            selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        } else if drawing == nil, let crop, dimensions.width > 0, dimensions.height > 0 {
            selection = CGRect(x: crop.minX / dimensions.width, y: crop.minY / dimensions.height, width: crop.width / dimensions.width, height: crop.height / dimensions.height)
        }
        if let selection {
            let box = CGRect(x: rect.minX + selection.minX * rect.width, y: rect.minY + selection.minY * rect.height, width: selection.width * rect.width, height: selection.height * rect.height)
            if drawing == nil {
                let mask = NSBezierPath(rect: rect)
                mask.appendRect(box); mask.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.45).setFill(); mask.fill()
            }
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: box); outline.lineWidth = 3; outline.stroke()
            NSColor.controlAccentColor.setStroke(); outline.lineWidth = 1.5; outline.setLineDash([5, 4], count: 2, phase: 0); outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard editable, cropEnabled || drawing != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard fitted.contains(point) else { return }
        window?.makeFirstResponder(self)
        gestureSeed = UInt64.random(in: 1...UInt64.max)
        start = CanvasGeometry.normalized(point, imageRect: fitted); end = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard start != nil else { return }
        end = CanvasGeometry.normalized(convert(event.locationInWindow, from: nil), imageRect: fitted)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; end = nil; needsDisplay = true }
        guard let start else { return }
        let end = CanvasGeometry.normalized(convert(event.locationInWindow, from: nil), imageRect: fitted)
        if let drawing {
            if ![.text, .number].contains(drawing), hypot(end.x - start.x, end.y - start.y) < 0.005 { return }
            let label = drawing == .text && text.isEmpty ? "Text" : text
            onMark?(ImageAnnotation(kind: drawing, startX: start.x, startY: start.y, endX: end.x, endY: end.y, text: label, hex: hex, thickness: thickness, fontScale: fontScale, seed: gestureSeed))
        } else {
            let rect = CanvasGeometry.crop(from: start, to: end, imageSize: dimensions)
            if rect.width >= 1, rect.height >= 1 { onCrop?(rect) }
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { onRedo?() } else { onUndo?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { start = nil; end = nil; needsDisplay = true }
        else { super.keyDown(with: event) }
    }
}

// bridge native color wells to the portable RGB values stored with an operation
extension Color {
    var hexRGB: String {
        let rgb = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
