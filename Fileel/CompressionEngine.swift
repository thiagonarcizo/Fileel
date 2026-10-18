import Foundation

// use the same reduction request for previews and final exports across file families
enum CompressionEngine {
    typealias Result = PDFCompressionEngine.Result
    struct MediaBudget {
        let duration: Double
        let video: Int
        let audio: Int
        var estimatedBytes: Int64 { Int64(Double(video + audio) * duration / 8) + 16_384 }
    }

    static func outputExtension(for input: URL) -> String {
        switch FileFamily.detect(input) {
        case .pdf: return "pdf"
        case .video: return "mp4"
        case .audio:
            let ext = Catalog.canonical(input.pathExtension)
            return ["wav", "aiff", "flac", "wma"].contains(ext) ? "m4a" : ext
        case .image:
            let ext = Catalog.canonical(input.pathExtension)
            return ["svg", "bmp"].contains(ext) ? "png" : ext
        default: return input.pathExtension
        }
    }

    static func mediaBudget(_ input: URL, reduction: Double, runner: ProcessRunner) throws -> MediaBudget {
        let duration = try MediaEngine.duration(input, runner: runner)
        let original = try PDFCompressionEngine.byteCount(input)
        let available = max(0, Double(original) * (1 - reduction / 100) - 16_384) * 8 / duration
        let audioText = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=index", "-of", "csv=p=0", input.path])
        let hasAudio = !audioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let audio = hasAudio ? Int(min(192_000, max(32_000, available * 0.12))) : 0
        return MediaBudget(duration: duration, video: max(120_000, Int(available) - audio), audio: audio)
    }

    static func estimateMedia(_ input: URL, options: OperationOptions, runner: ProcessRunner) throws -> Result {
        let original = try PDFCompressionEngine.byteCount(input)
        let target = Int64(Double(original) * (1 - options.compressionReduction / 100))
        let budget = try mediaBudget(input, reduction: options.compressionReduction, runner: runner)
        let output = Catalog.canonical(input.pathExtension) == outputExtension(for: input) ? min(original, budget.estimatedBytes) : budget.estimatedBytes
        return Result(originalBytes: original, outputBytes: output, targetBytes: target)
    }

    @discardableResult
    static func compress(_ input: URL, output: URL, options: OperationOptions, runner: ProcessRunner) throws -> Result {
        let reduction = options.compressionReduction
        guard reduction.isFinite, (0...95).contains(reduction) else { throw FileelError.message("Choose a reduction from 0% to 95%.") }
        let family = FileFamily.detect(input)
        if family == .pdf { return try PDFCompressionEngine.compress(input, output: output, reduction: reduction, runner: runner) }
        let originalBytes = try PDFCompressionEngine.byteCount(input)
        let target = Int64(Double(originalBytes) * (1 - reduction / 100))
        let workspace = output.deletingLastPathComponent().appendingPathComponent("compression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sameFormat = Catalog.canonical(input.pathExtension) == Catalog.canonical(output.pathExtension)
        var best: (url: URL, bytes: Int64)? = sameFormat ? (input, originalBytes) : nil
        var meeting: (url: URL, bytes: Int64)?
        var attempt = 0

        func record(_ url: URL) throws -> Int64 {
            let bytes = try PDFCompressionEngine.byteCount(url)
            if best == nil || bytes < best!.bytes { best = (url, bytes) }
            if bytes <= target { meeting = (url, bytes) }
            return bytes
        }

        if family == .image {
            let image = try ImageEngine.load(input)
            func candidate(_ quality: Double) throws -> Int64 {
                try runner.checkCancellation()
                var settings = options; settings.quality = quality
                let path = workspace.appendingPathComponent("image-\(attempt).\(output.pathExtension)"); attempt += 1
                if ImageEngine.supports(output.pathExtension) { try ImageEngine.write(image, to: path, options: settings, source: input) }
                else {
                    let normalized = workspace.appendingPathComponent("source.png")
                    if !FileManager.default.fileExists(atPath: normalized.path) { try ImageEngine.write(image, to: normalized, options: options) }
                    try MediaEngine.encode(normalized, output: path, options: settings, runner: runner)
                }
                return try record(path)
            }
            if try candidate(1) > target, !["png", "tiff"].contains(output.pathExtension), try candidate(0.1) <= target {
                var low = 0.1, high = 1.0
                for _ in 0..<5 {
                    let quality = (low + high) / 2
                    if try candidate(quality) <= target { low = quality } else { high = quality }
                }
            }
        } else if family == .video {
            let budget = try mediaBudget(input, reduction: reduction, runner: runner)
            let path = workspace.appendingPathComponent("video.mp4")
            var extra = ["-b:v", "\(budget.video)"]
            if budget.audio > 0 { extra += ["-b:a", "\(budget.audio)"] }
            try MediaEngine.encode(input, output: path, options: options, runner: runner, extra: extra)
            _ = try record(path)
        } else if family == .audio {
            let duration = try MediaEngine.duration(input, runner: runner)
            let bitrate = max(32_000, min(320_000, Int(max(0, Double(target) - 8192) * 8 / duration)))
            let path = workspace.appendingPathComponent("audio.\(output.pathExtension)")
            try MediaEngine.encode(input, output: path, options: options, runner: runner, extra: ["-b:a", "\(bitrate)"])
            _ = try record(path)
        } else { throw FileelError.message("Compression is unavailable for this file type.") }

        try runner.checkCancellation()
        guard let chosen = meeting ?? best else { throw FileelError.message("The compressed file could not be created.") }
        try FileManager.default.copyItem(at: chosen.url, to: output)
        return Result(originalBytes: originalBytes, outputBytes: chosen.bytes, targetBytes: target)
    }
}
