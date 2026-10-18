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
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let ctx = try ImageEngine.context(width: Int(ceil(bounds.width * scale)), height: Int(ceil(bounds.height * scale)))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()!
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
