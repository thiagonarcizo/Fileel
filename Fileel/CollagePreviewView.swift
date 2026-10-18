import AppKit
import SwiftUI

// cache small source images so changing the spacing or backdrop never decodes the originals again
private actor CollagePreviewRenderer {
    private var urls: [URL] = []
    private var images: [CGImage] = []

    func render(urls: [URL], options: OperationOptions) throws -> CGImage {
        try Task.checkCancellation()
        if self.urls != urls {
            var loaded: [CGImage] = []
            for url in urls {
                try Task.checkCancellation()
                loaded.append(try ImageEngine.load(url, maximumPixelSize: 400))
            }
            self.urls = urls
            images = loaded
        }
        let width = options.width > 0 ? options.width : 800
        let height = options.height > 0 ? options.height : 800
        let scale = min(1, 240 / Double(max(width, height)))
        var preview = options
        preview.width = max(1, Int(Double(width) * scale))
        preview.height = max(1, Int(Double(height) * scale))
        preview.padding = max(0, Int(Double(options.padding) * scale))
        preview.cornerRadius = options.cornerRadius * scale
        let result = try ImageEngine.collage(images, options: preview)
        try Task.checkCancellation()
        return result
    }
}

struct CollagePreviewView: View {
    let files: [URL]
    let options: OperationOptions
    @State private var renderer = CollagePreviewRenderer()
    @State private var image: CGImage?
    @State private var error: String?
    private struct Request: Equatable { let files: [URL]; let options: OperationOptions }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Collage Preview").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(files.count) images").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let error {
                    ContentUnavailableView("Preview Unavailable", systemImage: "photo.on.rectangle", description: Text(error))
                } else if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .padding(28).shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: Request(files: files, options: options)) {
            do {
                let result = try await renderer.render(urls: files, options: options)
                try Task.checkCancellation()
                image = result; error = nil
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
