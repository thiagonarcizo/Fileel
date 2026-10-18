import AppKit
import Combine
import SwiftUI

// calculate actual output sizes locally and cancel obsolete requests when the target changes
@MainActor
private final class CompressionPreviewModel: ObservableObject {
    @Published var calculating = true
    @Published var originalBytes: Int64 = 0
    @Published var outputBytes: Int64?
    @Published var outputs: [URL] = []
    @Published var targetReached = false
    @Published var estimated = false
    @Published var previewOutput: URL?
    @Published var error: String?
    private var runner: ProcessRunner?
    private var requestID = UUID()
    private var folder: URL?

    func calculate(files: [URL], options: OperationOptions) async {
        let reduction = options.compressionReduction
        let id = UUID(); requestID = id
        guard reduction.isFinite, (0...95).contains(reduction) else {
            calculating = false; error = "Choose a reduction from 0% to 95%."; return
        }
        let runner = ProcessRunner(); self.runner = runner
        calculating = true; error = nil; outputBytes = nil
        originalBytes = files.reduce(0) { $0 + ((try? PDFCompressionEngine.byteCount($1)) ?? 0) }
        let working = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-pdf-preview-\(UUID().uuidString)")
        let worker = Task.detached(priority: .userInitiated) { () throws -> ([URL], Int64, Bool, Bool, URL?) in
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
            do {
                var outputs: [URL] = []
                var bytes: Int64 = 0
                var reached = true
                var estimated = false
                var firstPreview: URL?
                let settings = options
                for (index, file) in files.enumerated() {
                    try runner.checkCancellation()
                    if FileFamily.detect(file) == .video {
                        let result = try CompressionEngine.estimateMedia(file, options: settings, runner: runner)
                        bytes += result.outputBytes; reached = reached && result.targetReached; estimated = true
                        continue
                    }
                    let output = working.appendingPathComponent("Preview-\(index + 1).\(CompressionEngine.outputExtension(for: file))")
                    let result = try CompressionEngine.compress(file, output: output, options: settings, runner: runner)
                    outputs.append(output); bytes += result.outputBytes; reached = reached && result.targetReached
                    if index == 0 { firstPreview = output }
                }
                return (outputs, bytes, reached, estimated, firstPreview)
            } catch { try? FileManager.default.removeItem(at: working); throw error }
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { runner.cancel(); worker.cancel() })
            guard !Task.isCancelled, requestID == id else { try? FileManager.default.removeItem(at: working); return }
            let previous = folder
            folder = working; outputs = result.0; outputBytes = result.1; targetReached = result.2; estimated = result.3; previewOutput = result.4
            if let previous { try? FileManager.default.removeItem(at: previous) }
        } catch is CancellationError { }
        catch { if !Task.isCancelled, requestID == id { self.error = error.localizedDescription } }
        if requestID == id { calculating = false; self.runner = nil }
    }

    func clear() {
        runner?.cancel()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil; outputs = []; previewOutput = nil
    }
}

struct CompressionEditor: View {
    let files: [URL]
    @Binding var options: OperationOptions
    var onCalculating: (Bool) -> Void
    @StateObject private var preview = CompressionPreviewModel()
    @State private var showOriginal = true
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Preview").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("Preview version", selection: $showOriginal) {
                        Text("Original").tag(true)
                        Text("Compressed").tag(false)
                    }.pickerStyle(.segmented).frame(width: 200).disabled(preview.previewOutput == nil)
                }.padding(.horizontal, 20).padding(.vertical, 14)
                Divider()
                FilePreviewView(url: showOriginal ? files.first : preview.previewOutput)
            }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("Compression", systemImage: "arrow.down.right.and.arrow.up.left").font(.system(size: 12, weight: .semibold))
                    VStack(spacing: 10) {
                        LabeledContent("Desired Reduction") {
                            TextField("Desired Reduction", value: $options.compressionReduction, format: .number.precision(.fractionLength(0)))
                                .multilineTextAlignment(.trailing).frame(width: 42)
                            Text("%").foregroundStyle(.secondary)
                        }.font(.system(size: 12))
                        ResettableSlider(title: "File size reduction", value: $options.compressionReduction, range: 0...95, defaultValue: 50, step: 1)
                        HStack {
                            ForEach([25.0, 50.0, 80.0], id: \.self) { amount in
                                Button("\(Int(amount))%") { options.compressionReduction = amount }.controlSize(.small)
                            }
                        }
                    }
                    VStack(spacing: 14) {
                        LabeledContent("Original", value: bytes(preview.originalBytes))
                        LabeledContent("Target", value: bytes(Int64(Double(preview.originalBytes) * (1 - min(95, max(0, options.compressionReduction)) / 100))))
                        Divider()
                        if preview.calculating {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Calculating size…").font(.caption).foregroundStyle(.secondary) }
                        } else if let actual = preview.outputBytes {
                            LabeledContent(preview.estimated ? "Estimated" : "Compressed", value: bytes(actual)).fontWeight(.semibold)
                            let saved = preview.originalBytes > 0 ? 100 * (1 - Double(actual) / Double(preview.originalBytes)) : 0
                            Text("\(abs(saved), specifier: "%.1f")% \(saved >= 0 ? "smaller" : "larger")").foregroundStyle(.tint)
                            Text(preview.estimated ? "Estimated from duration and encoding bitrate. The final size can vary." :
                                    preview.targetReached ? "The requested size was reached." : "Best available result. This format could not reach the requested size.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 12)).monospacedDigit()
                    if let error = preview.error { Text(error).font(.caption).foregroundStyle(.red) }
                    Text(preview.estimated ? "Video size is estimated without encoding the whole clip first. Frame dimensions stay unchanged." :
                            "Sizes are measured from a local test compression. Higher reductions can soften images. Image dimensions stay unchanged; PDF text stays selectable.")
                        .font(.caption).foregroundStyle(.secondary)
                    if files.count > 1 { Text("Sizes include all \(files.count) files. The preview shows the first file.").font(.caption).foregroundStyle(.secondary) }
                }.padding(22)
            }.frame(width: 286)
        }
        .task(id: options) {
            onCalculating(true)
            do {
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
                await preview.calculate(files: files, options: options)
                if !Task.isCancelled { onCalculating(preview.error != nil) }
            } catch { }
        }
        .onDisappear { preview.clear() }
    }
}
