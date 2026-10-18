import AppKit
import PDFKit
import SwiftUI

// keep source parsing and vector preview rendering off the main thread
private actor PDFWatermarkRenderer {
    private var url: URL?
    private var document: PDFDocument?
    func render(url: URL, page: Int, options: OperationOptions) throws -> (Data, Int) {
        try Task.checkCancellation()
        if self.url != url { document = try PDFEngine.load(url); self.url = url }
        guard let document, document.pageCount > 0 else { throw FileelError.message("This PDF has no pages.") }
        let index = min(document.pageCount - 1, max(0, page))
        let data: Data
        if options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let preview = PDFDocument()
            if let copy = document.page(at: index)?.copy() as? PDFPage { preview.insert(copy, at: 0) }
            guard let plain = preview.dataRepresentation() else { throw FileelError.message("This page cannot be previewed.") }
            data = plain
        } else { data = try PDFWatermarkEngine.data(document: document, pages: [index], options: options) }
        try Task.checkCancellation()
        return (data, document.pageCount)
    }
}

struct PDFWatermarkPreview: View {
    let url: URL
    let options: OperationOptions
    @State private var renderer = PDFWatermarkRenderer()
    @State private var data: Data?
    @State private var page = 0
    @State private var count = 0
    @State private var error: String?
    private struct Request: Equatable { let url: URL; let page: Int; let options: OperationOptions }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Watermark Preview").font(.system(size: 12, weight: .medium))
                Spacer()
                Button { page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(page <= 0).help("Previous page")
                Text(count > 0 ? "\(page + 1) of \(count)" : "Loading…").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled(page + 1 >= count).help("Next page")
            }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if let error { ContentUnavailableView("Preview Unavailable", systemImage: "doc", description: Text(error)) }
            else if let data { PDFDocumentSurface(data: data) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: Request(url: url, page: page, options: options)) {
            do {
                let result = try await renderer.render(url: url, page: page, options: options)
                try Task.checkCancellation()
                data = result.0; count = result.1; error = nil
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

// pdfkit displays the actual generated PDF data so the preview matches the saved vector content
struct PDFDocumentSurface: NSViewRepresentable {
    let data: Data
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }
    final class Coordinator { var data: Data? }
}

struct PDFWatermarkInspector: View {
    @Binding var options: OperationOptions
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Watermark", systemImage: "textformat").font(.system(size: 12, weight: .semibold))
                    TextField("Watermark text", text: $options.text).textFieldStyle(.roundedBorder)
                    ColorPicker("Text Color", selection: Binding(get: {
                        Color(nsColor: NSColor(cgColor: ImageEngine.color(options.watermarkHex)) ?? .gray)
                    }, set: { options.watermarkHex = $0.hexRGB }), supportsOpacity: false)
                }
                parameter("Opacity", value: $options.watermarkOpacity, range: 0.05...1, defaultValue: 0.25, suffix: "%", multiplier: 100)
                parameter("Size", value: $options.watermarkFontSize, range: 8...200, defaultValue: 42, suffix: "pt")
                parameter("Angle", value: $options.watermarkAngle, range: -90...90, defaultValue: 35, suffix: "°")
                Picker("Position", selection: $options.watermarkPosition) {
                    Text("Top").tag("top"); Text("Center").tag("center"); Text("Bottom").tag("bottom")
                }
                Text("Applied to every page. The preview uses the same drawing as the saved copy.").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
    }
    private func parameter(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double, suffix: String, multiplier: Double = 1) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text("\(Int((value.wrappedValue * multiplier).rounded()))\(suffix)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            ResettableSlider(title: title, value: value, range: range, defaultValue: defaultValue)
        }
    }
}
