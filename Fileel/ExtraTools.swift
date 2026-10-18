import AppKit
import CoreText
import CoreImage
import CryptoKit
import PDFKit
import Vision

// implement the additional tools using the same transactional output path as conversions
enum ExtraTools {
    // return recognized text directly without writing a text document
    static func imageText(_ url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try VisionExecution.perform([request], handler: VNImageRequestHandler(cgImage: ImageEngine.load(url)))
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func image(_ input: URL, tool: FileTool, output: URL, options: OperationOptions) throws {
        let original = try ImageEngine.load(input)
        if tool == .removeBackground {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: original)
            try VisionExecution.perform([request], handler: handler)
            guard let observation = request.results?.first else { throw FileelError.message("No foreground subject was found.") }
            let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
            let ciImage = CIImage(cvPixelBuffer: buffer)
            guard let image = CIContext().createCGImage(ciImage, from: ciImage.extent) else { throw FileelError.message("Cannot render the foreground mask.") }
            try ImageEngine.write(image, to: output, options: options, source: input)
        } else if tool == .rotate {
            let rotated = options.rotation == 90 || options.rotation == 270
            let ctx = try ImageEngine.context(width: rotated ? original.height : original.width, height: rotated ? original.width : original.height)
            ctx.translateBy(x: CGFloat(ctx.width) / 2, y: CGFloat(ctx.height) / 2)
            ctx.rotate(by: -CGFloat(options.rotation) * .pi / 180)
            if options.flipHorizontal { ctx.scaleBy(x: -1, y: 1) }
            ctx.draw(original, in: CGRect(x: -CGFloat(original.width) / 2, y: -CGFloat(original.height) / 2, width: CGFloat(original.width), height: CGFloat(original.height)))
            try ImageEngine.write(ctx.makeImage()!, to: output, options: options, source: input)
        } else {
            try ImageEngine.write(ImageEngine.resized(original, options: options), to: output, options: options, source: input)
        }
    }

    static func pdf(_ input: URL, tool: FileTool, output: URL, options: OperationOptions, runner: ProcessRunner) throws {
        let document = try PDFEngine.load(input)
        if tool == .watermarkPDF {
            let data = try PDFWatermarkEngine.data(document: document, pages: Array(0..<document.pageCount), options: options,
                                                   checkCancellation: { try runner.checkCancellation() })
            try runner.checkCancellation()
            try data.write(to: output, options: .atomic)
            return
        }
        if tool == .protectPDF {
            guard !options.password.isEmpty else { throw FileelError.message("Enter a password for this PDF.") }
            let settings: [PDFDocumentWriteOption: Any] = [.userPasswordOption: options.password, .ownerPasswordOption: UUID().uuidString]
            guard document.write(to: output, withOptions: settings) else { throw FileelError.message("Cannot save the protected PDF.") }
            return
        }
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw FileelError.message("Cannot create a PDF context.") }
        for index in 0..<document.pageCount {
            try runner.checkCancellation()
            let page = document.page(at: index)!
            var box = page.bounds(for: .mediaBox)
            let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
            page.draw(with: .mediaBox, to: context)
            if tool != .watermarkPDF {
                // overlay invisible OCR glyphs only on pages without selectable text
                if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.automaticallyDetectsLanguage = true
                    try VisionExecution.perform([request], handler: VNImageRequestHandler(cgImage: PDFEngine.render(page)))
                    for observation in request.results ?? [] {
                        guard let string = observation.topCandidates(1).first?.string else { continue }
                        let rect = observation.boundingBox
                        let font = CTFontCreateWithName("Helvetica" as CFString, max(6, rect.height * box.height), nil)
                        let text = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                        let line = CTLineCreateWithAttributedString(text)
                        context.saveGState()
                        context.setTextDrawingMode(.invisible)
                        context.textPosition = CGPoint(x: box.minX + rect.minX * box.width, y: box.minY + rect.minY * box.height)
                        CTLineDraw(line, context)
                        context.restoreGState()
                    }
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func document(_ inputs: [URL], tool: FileTool, output: URL, runner: ProcessRunner) throws {
        let strings = try inputs.enumerated().map { index, input -> String in
            if input.pathExtension == "txt" || input.pathExtension == "md" { return try String(contentsOf: input, encoding: .utf8) }
            let folder = output.deletingLastPathComponent().appendingPathComponent("text-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let text = try DocumentEngine.convert(input, format: "txt", folder: folder, options: .init(), runner: runner)
            return try String(contentsOf: text, encoding: .utf8)
        }
        var text = strings[0]
        if tool == .wordCount {
            text = "Words: \(text.split(whereSeparator: { $0.isWhitespace }).count)\nCharacters: \(text.count)\nLines: \(text.components(separatedBy: .newlines).count)\n"
        } else if tool == .compareDocuments {
            guard strings.count == 2 else { throw FileelError.message("Choose exactly two documents to compare.") }
            let before = strings[0].components(separatedBy: .newlines)
            let after = strings[1].components(separatedBy: .newlines)
            let diff = after.difference(from: before)
            let changes = diff.map { change -> String in
                switch change {
                case .insert(let offset, let line, _): return "+ line \(offset + 1): \(line)"
                case .remove(let offset, let line, _): return "- line \(offset + 1): \(line)"
                }
            }
            text = "Before: \(inputs[0].lastPathComponent)\nAfter: \(inputs[1].lastPathComponent)\n\n" + (changes.isEmpty ? "No text changes." : changes.joined(separator: "\n"))
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    static func subtitles(_ inputs: [URL], tool: FileTool, output: URL, options: OperationOptions) throws {
        var cues = try inputs.flatMap { SubtitleEngine.parse(try String(contentsOf: $0, encoding: .utf8)) }
        if tool == .shiftSubtitles || tool == .speedSubtitles {
            guard options.speed > 0 else { throw FileelError.message("Subtitle speed must be greater than zero.") }
            cues = try cues.map { cue in
                let sides = cue.timing.components(separatedBy: " --> ")
                guard sides.count == 2 else { throw FileelError.message("Invalid subtitle timing.") }
                var result = cue
                result.timing = try sides.map { side in
                    let stamp = String(side.split(separator: " ").first ?? "")
                    let value = try seconds(stamp)
                    let new = tool == .shiftSubtitles ? value + options.offset : value / options.speed
                    return timestamp(max(0, new))
                }.joined(separator: " --> ")
                return result
            }
        }
        let text = cues.enumerated().map { "\($0.offset + 1)\n\($0.element.timing.replacingOccurrences(of: ".", with: ","))\n\($0.element.lines.joined(separator: "\n"))" }.joined(separator: "\n\n")
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    static func seconds(_ stamp: String) throws -> Double {
        let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { throw FileelError.message("Invalid subtitle timestamp.") }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func timestamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

// filesystem actions share the same collision policy as conversions
enum FileActions {
    static func rename(_ files: [URL], template: String) throws {
        guard !template.isEmpty, !template.contains("/"), !template.contains(":"), !template.contains("\0") else {
            throw FileelError.message("Enter a filename template without path separators.")
        }
        let pairs = files.enumerated().map { index, file in
            let name = template.replacingOccurrences(of: "{name}", with: file.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "{n}", with: String(index + 1))
            return (file, file.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(file.pathExtension))
        }
        guard Set(pairs.map { $0.1 }).count == pairs.count,
              pairs.allSatisfy({ $0.0 == $0.1 || !FileManager.default.fileExists(atPath: $0.1.path) }) else {
            throw FileelError.message("The template produces a filename that already exists.")
        }
        var moved: [(URL, URL)] = []
        do {
            for (source, target) in pairs where source != target {
                try FileManager.default.moveItem(at: source, to: target)
                moved.append((source, target))
            }
        } catch {
            for (source, target) in moved.reversed() { try? FileManager.default.moveItem(at: target, to: source) }
            throw error
        }
    }

    static func checksum(_ input: URL, runner: ProcessRunner) throws -> String {
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try runner.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
