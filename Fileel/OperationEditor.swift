import AppKit
import SwiftUI

// keep each action's settings and file snapshot independent from the general file browser
@MainActor
final class OperationWindowController: NSWindowController, NSWindowDelegate {
    private static var sessions: [UUID: OperationWindowController] = [:]
    private let sessionID = UUID()
    static func show(files: [URL], operation: FileOperation) {
        guard !files.isEmpty else { return }
        let controller = OperationWindowController(files: files, operation: operation)
        sessions[controller.sessionID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private init(files: [URL], operation: FileOperation) {
        let rect = NSRect(x: 0, y: 0, width: 1080, height: 720)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = operation.title.replacingOccurrences(of: "…", with: "")
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OperationEditor(files: files, operation: operation, onFinished: { [weak window] in window?.close() }))
        host.sizingOptions = []
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.minSize = NSSize(width: 820, height: 580)
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { Self.sessions.removeValue(forKey: sessionID) }
}

private struct OperationEditor: View {
    let files: [URL]
    let operation: FileOperation
    let onFinished: () -> Void
    @ObservedObject private var jobs = AppModel.shared
    @State private var options: OperationOptions
    @State private var selectedMark: UUID?
    @State private var jobID: UUID?
    @State private var light = true
    @State private var color = true
    @State private var detail = false
    @State private var playhead = 0.0
    @State private var duration = 0.0
    @State private var videoSize = CGSize.zero
    @State private var imageSize = CGSize.zero
    @State private var copying = false
    @State private var clipboardStatus: String?
    @State private var clipboardTask: Task<Void, Never>?
    @State private var pdfCalculating = true
    init(files: [URL], operation: FileOperation, onFinished: @escaping () -> Void) {
        self.files = files
        self.operation = operation
        self.onFinished = onFinished
        _options = State(initialValue: AppModel.shared.defaults())
    }
    private var family: FileFamily { FileFamily.detect(files[0]) }
    private var job: Job? { jobs.jobs.first { $0.id == jobID } }
    private var requirement: String? { OperationRequirements.issue(for: operation, inputs: files, options: options) }
    private var isMarkup: Bool { operation == .tool(.annotateImage) || operation == .tool(.redactImage) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: operation.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(operation.title.replacingOccurrences(of: "…", with: "")).font(.headline)
                    Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if operation == .tool(.editImage) {
                    Toggle("Auto", isOn: $options.autoAdjust).toggleStyle(.button).help("Automatically adjust tone and color").disabled(jobs.busy)
                    Button("Reset Adjustments", action: resetAdjustments).disabled(jobs.busy)
                }
                if jobs.busy { ProgressView().controlSize(.small); Button("Cancel") { jobs.cancel() } }
                else {
                    if family == .image, operation != .tool(.compress) {
                        Button(copying ? "Copying…" : "Copy", action: copyImage)
                            .disabled(copying || requirement != nil)
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                            .help("Copy the edited image at full resolution")
                    }
                    Button(isMarkup || family == .image ? "Save Copy" : operation.title.replacingOccurrences(of: "…", with: "")) {
                        jobs.run(operation, inputs: files, options: options)
                        jobID = jobs.workspaceJobID
                    }.buttonStyle(.borderedProminent)
                        .disabled(copying || requirement != nil || (operation == .tool(.compress) && pdfCalculating))
                        .keyboardShortcut("s", modifiers: .command)
                }
            }.padding(.horizontal, 22).padding(.vertical, 16)
            Divider()
            if operation == .tool(.organizePDF) {
                PDFOrganizerView(url: files[0], options: $options)
            } else if operation == .tool(.compress) {
                CompressionEditor(files: files, options: $options, onCalculating: { pdfCalculating = $0 })
            } else {
            HSplitView {
                Group {
                    if operation == .tool(.collage) {
                        CollagePreviewView(files: files, options: options)
                    } else if family == .image {
                        ImageEditorView(url: files[0], operation: operation, options: $options, dedicated: true, selectedAnnotation: $selectedMark,
                                        onDimensions: { imageSize = $0 })
                    } else if family == .video || family == .audio {
                        MediaPreviewView(url: files[0], operation: operation, options: $options,
                                         onPosition: { playhead = $0 }, onDuration: { duration = $0 }, onVideoSize: { videoSize = $0 })
                    } else if operation == .tool(.watermarkPDF) {
                        PDFWatermarkPreview(url: files[0], options: options)
                    } else { FilePreviewView(url: files[0]) }
                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(!jobs.busy)
                inspector.frame(width: 286).disabled(jobs.busy)
            }
            }
            Divider()
            HStack(spacing: 12) {
                if let clipboardStatus {
                    Text(clipboardStatus).font(.caption).foregroundStyle(.secondary)
                } else if let job {
                    Image(systemName: job.state == .completed ? "checkmark.circle.fill" : job.state == .failed ? "exclamationmark.triangle" : "clock").foregroundStyle(job.state == .completed ? Color.accentColor : .secondary)
                    Text(job.state == .completed ? "Copy saved" : job.detail).font(.caption).lineLimit(1)
                    if !job.outputs.isEmpty { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }.controlSize(.small) }
                } else { Text(requirement ?? "Your original stays unchanged").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()

            }.padding(.horizontal, 22).padding(.vertical, 12)
        }.background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: options) { _, _ in
                clipboardStatus = nil
                // playback callbacks must not detach an active save from its completion handler
                if job?.state != .running && job?.state != .completed { jobID = nil }
            }
            .onChange(of: job?.state) { _, state in if state == .completed { onFinished() } }
            .onDisappear { clipboardTask?.cancel() }
    }

    @ViewBuilder private var inspector: some View {
        if operation == .tool(.editImage) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    adjustmentSection("Light", symbol: "sun.max", expanded: $light) {
                        AdjustmentSlider("Exposure", value: $options.exposure, range: -3...3, defaultValue: 0)
                        AdjustmentSlider("Brightness", value: $options.brightness, range: -0.4...0.4, defaultValue: 0)
                        AdjustmentSlider("Contrast", value: $options.contrast, range: 0.5...1.5, defaultValue: 1)
                        AdjustmentSlider("Highlights", value: $options.highlights, range: 0...1, defaultValue: 1)
                        AdjustmentSlider("Shadows", value: $options.shadows, range: 0...1, defaultValue: 0)
                    }
                    adjustmentSection("Color", symbol: "circle.lefthalf.filled", expanded: $color) {
                        AdjustmentSlider("Saturation", value: $options.saturation, range: 0...2, defaultValue: 1)
                        AdjustmentSlider("Vibrance", value: $options.vibrance, range: -1...1, defaultValue: 0)
                        AdjustmentSlider("Temperature", value: $options.temperature, range: 2500...10000, defaultValue: 6500, decimals: 0)
                        AdjustmentSlider("Tint", value: $options.tint, range: -150...150, defaultValue: 0, decimals: 0)
                    }
                    adjustmentSection("Detail", symbol: "circle.dotted", expanded: $detail) {
                        AdjustmentSlider("Sharpness", value: $options.sharpness, range: 0...2, defaultValue: 0)
                    }
                }.padding(22)
            }
        } else if operation == .tool(.watermarkPDF) {
            PDFWatermarkInspector(options: $options)
        } else if operation == .tool(.cropImage) {
            CropInspector(size: imageSize, options: $options)
        } else if isMarkup {
            MarkupInspector(operation: operation, options: $options, selected: $selectedMark)
        } else if family == .video || family == .audio {
            MediaToolInspector(operation: operation, family: family, options: $options, playhead: playhead, duration: duration, videoSize: videoSize)
        } else {
            OperationOptionsView(operation: operation, family: family, options: $options)
        }
    }

    private func adjustmentSection<C: View>(_ name: String, symbol: String, expanded: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            VStack(spacing: 20, content: content).padding(.top, 16)
        } label: { Label(name, systemImage: symbol).font(.system(size: 12, weight: .semibold)) }
    }
    private func resetAdjustments() {
        options.autoAdjust = false
        options.exposure = 0; options.brightness = 0; options.contrast = 1; options.highlights = 1; options.shadows = 0
        options.saturation = 1; options.vibrance = 0; options.temperature = 6500; options.tint = 0; options.sharpness = 0
        jobID = nil
    }

    // flatten full-resolution edited pixels into PNG data without saving a temporary output file
    private func copyImage() {
        guard case .tool(let tool) = operation, !copying else { return }
        let snapshot = options
        let inputs = files
        copying = true; clipboardStatus = nil
        clipboardTask = Task {
            defer { copying = false; clipboardTask = nil }
            let worker = Task.detached(priority: .userInitiated) { try ImageEngine.clipboardPNG(inputs, tool: tool, options: snapshot) }
            do {
                let data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setData(data, forType: .png) else { throw FileelError.message("The image could not be copied.") }
                clipboardStatus = "Image copied to clipboard"
                onFinished()
            } catch is CancellationError { }
            catch { clipboardStatus = error.localizedDescription }
        }
    }
}

// numeric values and reset gestures make photo adjustments precise without a generic form
private struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var decimals = 2
    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double, decimals: Int = 2) {
        self.title = title; _value = value; self.range = range; self.defaultValue = defaultValue; self.decimals = decimals
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                TextField(title, value: $value, format: .number.precision(.fractionLength(decimals)))
                    .labelsHidden().multilineTextAlignment(.trailing).textFieldStyle(.plain).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 62)
            }
            ResettableSlider(title: title, value: $value, range: range, defaultValue: defaultValue)
        }
    }
}

// annotation style and existing marks have their own inspector instead of conversion settings
private struct MarkupInspector: View {
    let operation: FileOperation
    @Binding var options: OperationOptions
    @Binding var selected: UUID?
    private var redaction: Bool { operation == .tool(.redactImage) }
    private var index: Int? { options.annotations.firstIndex { $0.id == selected } }
    private var color: Binding<Color> {
        Binding(get: {
            let hex = index.map { options.annotations[$0].hex } ?? (redaction ? options.redactionHex : options.annotationHex)
            return Color(nsColor: NSColor(cgColor: ImageEngine.color(hex)) ?? .red)
        }, set: { value in
            if let index { options.annotations[index].hex = value.hexRGB }
            else if redaction { options.redactionHex = value.hexRGB }
            else { options.annotationHex = value.hexRGB }
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(index.map { options.annotations[$0].kind.title } ?? "New Marks").font(.system(size: 13, weight: .semibold))
                ColorPicker("Fill Color", selection: color, supportsOpacity: false).font(.system(size: 12))
                if !redaction {
                    TextField("Text", text: Binding(get: { index.map { options.annotations[$0].text } ?? options.text }, set: { text in
                        if let index { options.annotations[index].text = text } else { options.text = text }
                    })).textFieldStyle(.roundedBorder)
                    AdjustmentSlider("Stroke", value: Binding(get: { index.map { options.annotations[$0].thickness } ?? options.annotationThickness }, set: { value in
                        if let index { options.annotations[index].thickness = value } else { options.annotationThickness = value }
                    }), range: 0.002...0.025, defaultValue: OperationOptions().annotationThickness, decimals: 3)
                    AdjustmentSlider("Text Size", value: Binding(get: { index.map { options.annotations[$0].fontScale } ?? options.annotationFontScale }, set: { value in
                        if let index { options.annotations[index].fontScale = value } else { options.annotationFontScale = value }
                    }), range: 0.015...0.15, defaultValue: OperationOptions().annotationFontScale, decimals: 3)
                } else {
                    Text("Random Mosaic generates new opaque blocks without using the covered pixels.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Detect faces", isOn: $options.detectFaces)
                    Toggle("Detect text", isOn: $options.detectText)
                    Text("Review detected areas before sharing.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("Marks").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(options.annotations.count)").font(.caption).foregroundStyle(.secondary)
                }
                if options.annotations.isEmpty {
                    Text("Choose a tool above the canvas, then draw directly on the image.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(options.annotations) { mark in
                    Button { selected = mark.id } label: {
                        HStack {
                            Image(systemName: mark.kind.symbol).frame(width: 18)
                            Text(mark.text.isEmpty ? mark.kind.title : mark.text).lineLimit(1)
                            Spacer()
                            if selected == mark.id { Image(systemName: "checkmark").font(.caption) }
                        }.font(.system(size: 12)).padding(8)
                            .background(selected == mark.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                if let index {
                    Button("Delete Selected Mark", role: .destructive) { options.annotations.remove(at: index); selected = nil }
                }
            }.padding(22)
        }.onChange(of: options.annotations) { _, marks in if let selected, !marks.contains(where: { $0.id == selected }) { self.selected = nil } }
    }
}
