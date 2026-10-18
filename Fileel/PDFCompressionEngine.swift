import Foundation
import PDFKit

// search real compressed outputs for a size target while preserving PDF text and vector drawing
enum PDFCompressionEngine {
    struct Result: Sendable {
        let originalBytes: Int64
        let outputBytes: Int64
        let targetBytes: Int64
        var reduction: Double { originalBytes > 0 ? 1 - Double(outputBytes) / Double(originalBytes) : 0 }
        var targetReached: Bool { outputBytes <= targetBytes }
    }

    static func byteCount(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    @discardableResult
    static func compress(_ input: URL, output: URL, reduction: Double, runner: ProcessRunner) throws -> Result {
        guard input.standardizedFileURL != output.standardizedFileURL else { throw FileelError.message("Choose a different output file.") }
        guard reduction.isFinite, (0...95).contains(reduction) else { throw FileelError.message("Choose a reduction from 0% to 95%.") }
        let original = try byteCount(input)
        let target = Int64(Double(original) * (1 - reduction / 100))
        let workspace = output.deletingLastPathComponent().appendingPathComponent("pdf-compression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        var smallest = (url: input, bytes: original)
        var meeting: (url: URL, bytes: Int64)?
        let pageCount = try PDFEngine.load(input).pageCount
        var attempt = 0

        func candidate(_ strength: Double) throws -> Int64 {
            try runner.checkCancellation()
            let path = workspace.appendingPathComponent("attempt-\(attempt).pdf")
            attempt += 1
            let dpi = Int((300 - strength * 264).rounded())
            let factor = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), 0.1 + strength * 0.9)
            let parameters = "<< /ColorImageDict << /QFactor \(factor) >> /GrayImageDict << /QFactor \(factor) >> >> setdistillerparams"
            let args = ["-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.7",
                        "-dAutoRotatePages=/None", "-dPreserveAnnots=true", "-dDetectDuplicateImages=true", "-dCompressFonts=true", "-dSubsetFonts=true",
                        "-dDownsampleColorImages=true", "-dColorImageDownsampleType=/Bicubic", "-dColorImageResolution=\(dpi)",
                        "-dDownsampleGrayImages=true", "-dGrayImageDownsampleType=/Bicubic", "-dGrayImageResolution=\(dpi)",
                        "-dDownsampleMonoImages=true", "-dMonoImageResolution=\(max(150, dpi * 2))",
                        "-dAutoFilterColorImages=false", "-dColorImageFilter=/DCTEncode", "-dAutoFilterGrayImages=false", "-dGrayImageFilter=/DCTEncode",
                        "-dPassThroughJPEGImages=false", "-sOutputFile=\(path.path)", "-c", parameters, "-f", input.path]
            try runner.run(Engines.require("gs"), args)
            try runner.checkCancellation()
            guard try PDFEngine.load(path).pageCount == pageCount else { throw FileelError.message("Compression changed the number of pages.") }
            let bytes = try byteCount(path)
            if bytes < smallest.bytes { smallest = (path, bytes) }
            if bytes <= target { meeting = (path, bytes) }
            return bytes
        }

        if reduction > 0, original > 0 {
            if try candidate(0) > target, try candidate(1) <= target {
                var lower = 0.0, upper = 1.0
                // choose the least aggressive tested setting that still reaches the requested size
                for _ in 0..<4 {
                    let middle = (lower + upper) / 2
                    if try candidate(middle) <= target { upper = middle }
                    else { lower = middle }
                }
            }
        }
        try runner.checkCancellation()
        let chosen = meeting ?? smallest
        try FileManager.default.copyItem(at: chosen.url, to: output)
        return Result(originalBytes: original, outputBytes: chosen.bytes, targetBytes: target)
    }
}
