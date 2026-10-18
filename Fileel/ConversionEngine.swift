import Foundation

// all expensive work runs off the UI thread with cancellation shared across child processes
enum ConversionEngine {
    enum Result: Sendable { case files([URL]), clipboard(String) }

    // text extraction bypasses the output transaction and never creates a text file
    static func execute(_ operation: FileOperation, inputs: [URL], options: OperationOptions, runner: ProcessRunner) throws -> Result {
        if operation == .tool(.ocrImage) {
            guard !inputs.isEmpty else { throw FileelError.message("Choose an image first.") }
            var text: [String] = []
            for input in inputs { try runner.checkCancellation(); text.append(try ExtraTools.imageText(input)) }
            let result = text.joined(separator: "\n\n")
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileelError.message("No readable text was found in this image.") }
            try runner.checkCancellation()
            return .clipboard(result)
        }
        return .files(try perform(operation, inputs: inputs, options: options, runner: runner))
    }

    static func perform(_ operation: FileOperation, inputs: [URL], options: OperationOptions, runner: ProcessRunner) throws -> [URL] {
        if operation == .tool(.ocrImage) { throw FileelError.message("Image OCR returns clipboard text instead of a file.") }
        if let issue = OperationRequirements.issue(for: operation, inputs: inputs, options: options) { throw FileelError.message(issue) }
        let transaction = try OutputTransaction(inputs: inputs, options: options)
        defer { transaction.cleanUp() }
        var outputs: [URL] = []
        if case .tool(let tool) = operation, tool.grouped {
            let ext = tool == .collage ? "png" : tool == .joinVideos ? "mp4" : tool == .joinAudio ? "m4a" :
                tool == .compareDocuments ? "txt" : tool == .joinSubtitles ? "srt" : "pdf"
            let result = transaction.workspace.appendingPathComponent("\(inputs[0].deletingPathExtension().lastPathComponent) Combined.\(ext)")
            switch tool {
            case .createPDF: try PDFEngine.fromImages(inputs, output: result, runner: runner)
            case .mergePDF: try PDFEngine.merge(inputs, output: result, runner: runner)
            case .collage: try ImageEngine.write(ImageEngine.collage(inputs, options: options), to: result, options: options)
            case .joinVideos: try MediaEngine.join(inputs, output: result, options: options, runner: runner)
            case .joinAudio: try MediaEngine.joinAudio(inputs, output: result, options: options, runner: runner)
            case .compareDocuments: try ExtraTools.document(inputs, tool: tool, output: result, runner: runner)
            case .joinSubtitles: try ExtraTools.subtitles(inputs, tool: tool, output: result, options: options)
            default: break
            }
            outputs = [result]
        } else {
            for (index, input) in inputs.enumerated() {
                try runner.checkCancellation()
                // one private subfolder per input avoids collisions in mixed-directory selections
                let folder = transaction.workspace.appendingPathComponent("input-\(index)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                switch operation {
                case .convert(let format): outputs.append(try convert(input, format: format, folder: folder, options: options, runner: runner))
                case .tool(let tool): outputs.append(try process(input, tool: tool, folder: folder, options: options, runner: runner))
                case .action(let action):
                    let output = folder.appendingPathComponent(input.lastPathComponent + (action == .checksum ? ".sha256.txt" : ""))
                    if action == .duplicate { try FileManager.default.copyItem(at: input, to: output) }
                    else if action == .checksum {
                        try (FileActions.checksum(input, runner: runner) + "  " + input.lastPathComponent + "\n").write(to: output, atomically: true, encoding: .utf8)
                    } else { throw FileelError.message("This action requires the app coordinator.") }
                    outputs.append(output)
                }
            }
        }
        try runner.checkCancellation()
        guard outputs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw FileelError.message("The converter did not produce all expected files.") }
        return try transaction.publish(outputs)
    }

    static func convert(_ input: URL, format: String, folder: URL, options: OperationOptions, runner: ProcessRunner) throws -> URL {
        let output = folder.appendingPathComponent("\(input.deletingPathExtension().lastPathComponent) Converted.\(format == "gz" ? "tar.gz" : format)")
        switch FileFamily.detect(input) {
        case .image:
            if format == "pdf" || ImageEngine.supports(format) {
                try ImageEngine.write(ImageEngine.resized(ImageEngine.load(input), options: options), to: output, options: options, source: input)
            } else {
                // normalize SVG and HEIC inputs before sending them to a fallback encoder
                let png = folder.appendingPathComponent("source.png")
                try ImageEngine.write(ImageEngine.load(input), to: png, options: options)
                try MediaEngine.encode(png, output: output, options: options, runner: runner)
            }
        case .audio, .video:
            try MediaEngine.encode(input, output: output, options: options, runner: runner)
        case .pdf, .document, .presentation, .spreadsheet:
            return try DocumentEngine.convert(input, format: format, folder: folder, options: options, runner: runner)
        case .subtitle: try SubtitleEngine.convert(input, format: format, output: output)
        case .archive: try ArchiveEngine.convert(input, format: format, output: output, runner: runner)
        case .other: throw FileelError.message("This file type has no conversion engine.")
        }
        return output
    }

    static func process(_ input: URL, tool: FileTool, folder: URL, options: OperationOptions, runner: ProcessRunner) throws -> URL {
        let family = FileFamily.detect(input)
        let stem = input.deletingPathExtension().lastPathComponent
        if tool == .compress {
            let output = folder.appendingPathComponent("\(stem) Compressed.\(CompressionEngine.outputExtension(for: input))")
            try CompressionEngine.compress(input, output: output, options: options, runner: runner)
            return output
        }
        if tool == .extract {
            let output = folder.appendingPathComponent("\(stem) Extracted")
            try ArchiveEngine.extract(input, folder: output, runner: runner)
            return output
        }
        if [.listArchive, .testArchive, .encryptArchive].contains(tool) {
            let output = folder.appendingPathComponent("\(stem) \(tool.rawValue).\(tool == .encryptArchive ? "zip" : "txt")")
            try ArchiveEngine.inspect(input, tool: tool, output: output, options: options, runner: runner)
            return output
        }
        if [.wordCount, .cleanFormatting].contains(tool) {
            let output = folder.appendingPathComponent("\(stem) \(tool.rawValue).txt")
            try ExtraTools.document([input], tool: tool, output: output, runner: runner)
            return output
        }
        if [.shiftSubtitles, .speedSubtitles].contains(tool) {
            let output = folder.appendingPathComponent("\(stem) \(tool.rawValue).srt")
            try ExtraTools.subtitles([input], tool: tool, output: output, options: options)
            return output
        }
        if tool == .exportSheet {
            let output = folder.appendingPathComponent("\(stem) Sheet.csv")
            try SpreadsheetEngine.export(input, output: output, options: options, runner: runner)
            return output
        }
        if family == .image {
            if [.resize, .rotate, .removeBackground].contains(tool) {
                let output = folder.appendingPathComponent("\(stem) \(tool.rawValue).\("png")")
                try ExtraTools.image(input, tool: tool, output: output, options: options)
                return output
            }
            let ext = tool == .annotateImage || tool == .background || tool == .redactImage ? "png" : Catalog.canonical(input.pathExtension)
            let actual = ["svg", "bmp"].contains(ext) ? "png" : ext
            let output = folder.appendingPathComponent("\(stem) \(tool.rawValue).\(actual)")
            let image = try ImageEngine.edit(input, tool: tool, options: options)
            if ImageEngine.supports(actual) {
                var export = options
                if tool == .redactImage { export.preserveMetadata = false; export.stripMetadata = true }
                try ImageEngine.write(image, to: output, options: export, source: input)
            } else {
                let png = folder.appendingPathComponent("edited.png")
                try ImageEngine.write(image, to: png, options: options)
                try MediaEngine.encode(png, output: output, options: options, runner: runner)
            }
            return output
        }
        if family == .pdf {
            let output = folder.appendingPathComponent("\(stem) \(tool.rawValue)" + (tool == .splitPDF ? "" : ".pdf"))
            if [.protectPDF, .watermarkPDF, .ocrPDF].contains(tool) {
                try ExtraTools.pdf(input, tool: tool, output: output, options: options, runner: runner)
            } else { try PDFEngine.process(input, tool: tool, output: output, options: options, runner: runner) }
            return output
        }
        if tool == .splitVideo {
            let output = folder.appendingPathComponent("\(stem) Clips")
            try MediaEngine.split(input, folder: output, options: options, runner: runner)
            return output
        }
        let ext = tool == .metadata ? input.pathExtension.lowercased() : tool == .extractAudio ? "m4a" : tool == .extractSubtitles ? "srt" : tool == .snapshots ? "png" : tool == .visualizer || family == .video ? "mp4" :
            Catalog.canonical(input.pathExtension) == "wma" ? "m4a" : Catalog.canonical(input.pathExtension)
        let output = folder.appendingPathComponent("\(stem) \(tool.rawValue).\(ext)")
        try MediaEngine.process(input, tool: tool, output: output, options: options, runner: runner)
        return output
    }
}
