import AppKit
import PDFKit
import Vision

// preserve page objects for structural edits and rasterize only when an operation requires it
enum PDFEngine {
    static func load(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw FileelError.message("The PDF is empty, locked, or unreadable.")
        }
        return document
    }

    static func save(_ document: PDFDocument, to url: URL) throws {
        guard document.write(to: url) else { throw FileelError.message("Cannot write the PDF.") }
    }

    static func render(_ page: PDFPage, dpi: Double = 300) throws -> CGImage {
        let bounds = try displayedBounds(page)
        guard dpi.isFinite, dpi > 0 else { throw FileelError.message("Choose a positive PDF image resolution.") }
        let scale = dpi / 72
        let width = ceil(bounds.width * scale), height = ceil(bounds.height * scale)
        guard width.isFinite, height.isFinite, (1...16384).contains(width), (1...16384).contains(height) else {
            throw FileelError.message("Choose a resolution that keeps each page within 16384 pixels.")
        }
        let ctx = try ImageEngine.context(width: Int(width), height: Int(height))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        try draw(page, in: ctx, bounds: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return ctx.makeImage()!
    }

    static func displayedBounds(_ page: PDFPage) throws -> CGRect {
        guard let reference = page.pageRef else { throw FileelError.message("A PDF page cannot be rendered.") }
        var size = reference.getBoxRect(.mediaBox).size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw FileelError.message("The PDF page has invalid dimensions.")
        }
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 { size = CGSize(width: size.height, height: size.width) }
        return CGRect(origin: .zero, size: size)
    }

    // use the same explicit page transform for raster exports, OCR and vector watermarking
    static func draw(_ page: PDFPage, in context: CGContext, bounds: CGRect) throws {
        guard let reference = page.pageRef else { throw FileelError.message("A PDF page cannot be rendered.") }
        let requested = ((page.rotation % 360) + 360) % 360
        let intrinsic = ((Int(reference.rotationAngle) % 360) + 360) % 360
        let displayed = try displayedBounds(page)
        let scale = min(bounds.width / displayed.width, bounds.height / displayed.height)
        context.saveGState()
        defer { context.restoreGState() }
        // quartz fits pages down but does not enlarge them, so apply requested raster scaling explicitly
        context.translateBy(x: bounds.midX - displayed.width * scale / 2, y: bounds.midY - displayed.height * scale / 2)
        context.scaleBy(x: scale, y: scale)
        context.concatenate(reference.getDrawingTransform(.mediaBox, rect: displayed, rotate: Int32(requested - intrinsic), preserveAspectRatio: true))
        context.drawPDFPage(reference)
        for annotation in page.annotations where annotation.shouldPrint { annotation.draw(with: .mediaBox, in: context) }
    }

    static func text(_ input: URL, runner: ProcessRunner) throws -> String {
        let document = try load(input)
        return try (0..<document.pageCount).map { index in
            try runner.checkCancellation()
            let page = document.page(at: index)!
            if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            try VisionExecution.perform([request], handler: VNImageRequestHandler(cgImage: render(page)))
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func exportImages(_ input: URL, format: String, folder: URL, options: OperationOptions, runner: ProcessRunner) throws {
        let document = try load(input)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<document.pageCount {
            try runner.checkCancellation()
            try ImageEngine.write(render(document.page(at: index)!), to: folder.appendingPathComponent(String(format: "Page %04d.%@", index + 1, format)), options: options)
        }
    }

    static func merge(_ inputs: [URL], output: URL, runner: ProcessRunner) throws {
        let merged = PDFDocument()
        for input in inputs {
            let document = try load(input)
            for index in 0..<document.pageCount {
                try runner.checkCancellation()
                merged.insert(document.page(at: index)!, at: merged.pageCount)
            }
        }
        try save(merged, to: output)
    }

    static func fromImages(_ inputs: [URL], output: URL, runner: ProcessRunner) throws {
        let document = PDFDocument()
        for input in inputs {
            try runner.checkCancellation()
            guard let page = PDFPage(image: NSImage(cgImage: try ImageEngine.load(input), size: .zero)) else { throw FileelError.message("Cannot create an image page.") }
            document.insert(page, at: document.pageCount)
        }
        try save(document, to: output)
    }

    static func process(_ input: URL, tool: FileTool, output: URL, options: OperationOptions, runner: ProcessRunner) throws {
        let document = try load(input)
        if tool == .splitPDF {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for index in 0..<document.pageCount {
                try runner.checkCancellation()
                let single = PDFDocument()
                single.insert(document.page(at: index)!, at: 0)
                try save(single, to: output.appendingPathComponent("Page \(index + 1).pdf"))
            }
        } else if tool == .organizePDF {
            let pages: [PDFPageEdit]
            if !options.pdfPages.isEmpty { pages = options.pdfPages }
            else {
                let values = options.pageOrder.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard !values.isEmpty, values.allSatisfy({ $0 != nil && (1...document.pageCount).contains($0!) }) else {
                    throw FileelError.message("Choose valid pages to keep in the PDF.")
                }
                pages = values.map { PDFPageEdit(sourceIndex: $0! - 1, rotation: options.rotation) }
            }
            guard pages.allSatisfy({ (0..<document.pageCount).contains($0.sourceIndex) && $0.rotation % 90 == 0 }) else {
                throw FileelError.message("A selected page or rotation is invalid.")
            }
            let result = PDFDocument()
            if options.preserveMetadata { result.documentAttributes = document.documentAttributes }
            for edit in pages {
                try runner.checkCancellation()
                let page = document.page(at: edit.sourceIndex)!.copy() as! PDFPage
                page.rotation = ((page.rotation + edit.rotation) % 360 + 360) % 360
                result.insert(page, at: result.pageCount)
            }
            try save(result, to: output)
        } else if tool == .metadata {
            var attributes = options.stripMetadata ? [:] : document.documentAttributes ?? [:]
            if !options.author.isEmpty { attributes[PDFDocumentAttribute.authorAttribute] = options.author }
            if !options.title.isEmpty { attributes[PDFDocumentAttribute.titleAttribute] = options.title }
            document.documentAttributes = attributes
            try save(document, to: output)
        } else if tool == .compress {
            try PDFCompressionEngine.compress(input, output: output, reduction: options.compressionReduction, runner: runner)
        }
    }
}
