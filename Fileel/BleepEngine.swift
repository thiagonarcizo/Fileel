import Foundation

// each selection keeps a stable identity while its handles move on the timeline
struct AudioRedactionRange: Identifiable, Sendable, Equatable {
    let id: UUID
    var start: Double
    var end: Double

    init(id: UUID = UUID(), start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
}

enum BleepEngine {
    static let maximumRanges = 128

    // overlapping selections form one continuous replacement rather than adding multiple tones together
    static func normalized(_ ranges: [AudioRedactionRange], duration: Double) throws -> [AudioRedactionRange] {
        guard duration.isFinite, duration > 0, !ranges.isEmpty, ranges.count <= maximumRanges,
              ranges.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < duration && $0.end > $0.start && $0.end <= duration + 0.000001 }) else {
            throw FileelError.message("Choose valid bleep ranges within the recording, up to \(maximumRanges) selections.")
        }
        var result: [AudioRedactionRange] = []
        for var range in ranges.sorted(by: { $0.start < $1.start }) {
            range.end = min(duration, range.end)
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else { result.append(range) }
        }
        return result
    }

    static func process(_ input: URL, output: URL, options: OperationOptions, runner: ProcessRunner) throws {
        let duration = try MediaEngine.duration(input, runner: runner)
        let requested = options.usesBleepRanges || !options.bleepRanges.isEmpty ? options.bleepRanges :
            [AudioRedactionRange(start: options.start, end: options.end)]
        let ranges = try normalized(requested, duration: duration)
        func number(_ value: Double) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let masks = ranges.map { "between(t,\(number($0.start)),\(number($0.end)))" }
        let tones = ranges.enumerated().map { index, range -> String in
            let start = number(range.start), end = number(range.end)
            let fade = number(max(0.000000001, min(0.005, (range.end - range.start) / 2)))
            return "if(\(masks[index]),0.15*sin(2*PI*1000*(t-\(start)))*min(1,min((t-\(start))/\(fade),(\(end)-t)/\(fade))),0)"
        }
        // aeval runs per sample; a frame-level volume enable can leave the start of a word audible
        let filter = "aeval=exprs='if(gt(\(sum(masks)),0),\(sum(tones)),val(ch))':c=same"
        var extra = ["-map", "0:a:0", "-vn"]
        if options.keepQuality { extra += try losslessSettings(input, output: output, runner: runner) }
        try MediaEngine.encode(input, output: output, options: options, runner: runner, audioFilters: [filter], extra: extra)
    }

    // keep the expression tree shallow even when a recording has many selections
    private static func sum(_ expressions: [String]) -> String {
        if expressions.count == 1 { return expressions[0] }
        let middle = expressions.count / 2
        let left = sum(Array(expressions[..<middle]))
        let right = sum(Array(expressions[middle...]))
        return "(\(left)+\(right))"
    }

    // filtering lossless audio should not silently reduce its bit depth or turn ALAC into AAC
    private static func losslessSettings(_ input: URL, output: URL, runner: ProcessRunner) throws -> [String] {
        let ext = Catalog.canonical(output.pathExtension)
        guard ["wav", "aiff", "flac", "m4a"].contains(ext) else { return [] }
        let text = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,bits_per_raw_sample", "-of", "json", input.path])
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let stream = (json?["streams"] as? [[String: Any]])?.first
        let codec = stream?["codec_name"] as? String ?? ""
        let pcm = ["pcm_u8", "pcm_s8", "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be",
                   "pcm_s32le", "pcm_s32be", "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_f64be"]
        if ["wav", "aiff"].contains(ext), pcm.contains(codec) {
            let endian = ext == "wav" ? "le" : "be"
            let compatible = codec.hasSuffix("le") || codec.hasSuffix("be") ? String(codec.dropLast(2)) + endian : codec
            return ["-c:a", compatible]
        }
        if ext == "m4a", codec == "alac" {
            let bits = Int(stream?["bits_per_raw_sample"] as? String ?? "16") ?? 16
            return bits > 16 ? ["-c:a", "alac", "-sample_fmt", "s32p", "-bits_per_raw_sample", String(min(24, bits))] : ["-c:a", "alac"]
        }
        if ext == "flac", codec == "flac", let raw = stream?["bits_per_raw_sample"] as? String,
           let bits = Int(raw), (17...24).contains(bits) { return ["-sample_fmt", "s32", "-bits_per_raw_sample", String(bits)] }
        return []
    }
}
