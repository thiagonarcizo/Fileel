import Foundation

// keep media commands explicit so format choices never become arbitrary command strings
enum MediaEngine {
    static func encode(_ input: URL, output: URL, options: OperationOptions, runner: ProcessRunner,
                       inputArguments: [String] = [], filters: [String] = [], audioFilters: [String] = [],
                       extra: [String] = []) throws {
        let ext = output.pathExtension
        let family = FileFamily.detect(input)
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + inputArguments + ["-i", input.path]
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        if !audioFilters.isEmpty { args += ["-af", audioFilters.joined(separator: ",")] }
        args += try metadataArguments(options)
        switch ext {
        case "mp3": args += ["-vn", "-c:a", "libmp3lame", "-b:a", bitrate(options)]
        case "m4a": args += ["-vn", "-c:a", "aac", "-b:a", bitrate(options)]
        case "wav": args += ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": args += ["-vn", "-c:a", "pcm_s16be"]
        case "flac": args += ["-vn", "-c:a", "flac"]
        case "ogg": args += ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": args += ["-vn", "-c:a", "libopus", "-b:a", bitrate(options)]
        case "mp4", "mov", "mkv":
            args += ["-c:v", "h264_videotoolbox", "-b:v", "\(Int(1_000_000 + options.quality * 7_000_000))", "-pix_fmt", "yuv420p", "-c:a", "aac"]
            if ext != "mkv" { args += ["-movflags", "+faststart"] }
        case "webm": args += ["-c:v", "libvpx-vp9", "-crf", "\(Int(45 - options.quality * 20))", "-b:v", "0", "-c:a", "libopus"]
        case "webp": args += ["-frames:v", "1", "-c:v", "libwebp", "-quality", "\(Int(options.quality * 100))"]
        case "avif": args += ["-frames:v", "1", "-c:v", "libaom-av1", "-still-picture", "1", "-crf", "\(Int(50 - options.quality * 35))"]
        case "heic": args += ["-frames:v", "1", "-c:v", "hevc_videotoolbox"]
        case "gif":
            // a split filter generates the palette from the actual clip
            args += ["-an"]
        case "png", "jpg", "tiff": args += ["-frames:v", "1"]
        default: throw FileelError.message("No media encoder for \(ext.uppercased()).")
        }
        if family == .image && ext != "gif" { args += ["-frames:v", "1"] }
        args += extra + [output.path]
        try runner.run(Engines.require("ffmpeg"), args)
    }

    static func bitrate(_ options: OperationOptions) -> String { "\(Int(64 + options.quality * 192))k" }

    // disable stream and chapter tag copying too, since global tags are only part of a container's metadata
    static func metadataArguments(_ options: OperationOptions) throws -> [String] {
        var args: [String] = []
        if options.stripMetadata || !options.preserveMetadata {
            args += ["-map_metadata", "-1", "-map_metadata:s", "-1", "-map_chapters", "-1"]
        }
        if !options.author.isEmpty { args += ["-metadata", "artist=\(options.author)"] }
        if !options.title.isEmpty { args += ["-metadata", "title=\(options.title)"] }
        if options.removeLocation {
            args += ["-metadata", "location=", "-metadata", "com.apple.quicktime.location.ISO6709="]
        }
        if !options.latitude.isEmpty || !options.longitude.isEmpty {
            guard let latitude = Double(options.latitude), let longitude = Double(options.longitude),
                  latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw FileelError.message("Enter latitude from −90 to 90 and longitude from −180 to 180.")
            }
            let location = String(format: "%+.6f%+.6f/", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
            args += ["-metadata", "location=\(location)", "-metadata", "com.apple.quicktime.location.ISO6709=\(location)"]
        }
        if !options.cameraMake.isEmpty { args += ["-metadata", "make=\(options.cameraMake)"] }
        if !options.cameraModel.isEmpty { args += ["-metadata", "model=\(options.cameraModel)"] }
        return args
    }

    static func duration(_ input: URL, runner: ProcessRunner) throws -> Double {
        let text = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", input.path])
        guard let duration = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), duration.isFinite, duration > 0 else {
            throw FileelError.message("Cannot determine the media duration.")
        }
        return duration
    }

    static func process(_ input: URL, tool: FileTool, output: URL, options: OperationOptions, runner: ProcessRunner) throws {
        switch tool {
        case .compress:
            try encode(input, output: output, options: options, runner: runner)
        case .metadata:
            // remux metadata edits so the audio and video streams keep their original encoded bytes
            let args = ["-v", "error", "-nostdin", "-y", "-i", input.path, "-map", "0", "-c", "copy"] + (try metadataArguments(options))
            try runner.run(Engines.require("ffmpeg"), args + [output.path])
        case .resize:
            guard options.width > 0 || options.height > 0 else { throw FileelError.message("Enter at least one output dimension.") }
            let width = options.width > 0 ? options.width : -2
            let height = options.height > 0 ? options.height : -2
            try encode(input, output: output, options: options, runner: runner, filters: ["scale=\(width):\(height):force_divisible_by=2"])
        case .rotate:
            var filters: [String] = []
            if options.rotation == 90 { filters.append("transpose=1") }
            if options.rotation == 180 { filters += ["hflip", "vflip"] }
            if options.rotation == 270 { filters.append("transpose=2") }
            if options.flipHorizontal { filters.append("hflip") }
            try encode(input, output: output, options: options, runner: runner, filters: filters)
        case .extractAudio:
            try encode(input, output: output, options: options, runner: runner)
        case .extractSubtitles:
            try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-i", input.path, "-map", "0:s:0", output.path])
        case .embedSubtitles:
            let subtitle = URL(fileURLWithPath: options.subtitlePath)
            guard FileManager.default.fileExists(atPath: subtitle.path) else { throw FileelError.message("Choose a subtitle file.") }
            try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-i", input.path, "-i", subtitle.path,
                "-map", "0:v", "-map", "0:a?", "-map", "1:0", "-c:v", "h264_videotoolbox", "-c:a", "aac", "-c:s", "mov_text", output.path])
        case .fade:
            let total = try duration(input, runner: runner)
            guard options.fadeIn >= 0, options.fadeOut >= 0, options.fadeIn + options.fadeOut <= total else { throw FileelError.message("Fade times must fit within the recording.") }
            try encode(input, output: output, options: options, runner: runner,
                       audioFilters: ["afade=t=in:d=\(options.fadeIn)", "afade=t=out:st=\(total - options.fadeOut):d=\(options.fadeOut)"])
        case .removeSilence:
            try encode(input, output: output, options: options, runner: runner,
                       audioFilters: ["silenceremove=start_periods=1:start_duration=0.1:start_threshold=\(options.silenceThreshold)dB:stop_periods=-1:stop_duration=0.3:stop_threshold=\(options.silenceThreshold)dB"])
        case .mute:
            try encode(input, output: output, options: options, runner: runner, extra: ["-an"])
        case .normalize:
            try encode(input, output: output, options: options, runner: runner, audioFilters: ["loudnorm=I=-16:TP=-1.5:LRA=11"])
        case .channels:
            try encode(input, output: output, options: options, runner: runner, extra: ["-ac", String(options.channels)])
        case .trimAudio, .trimVideo:
            guard options.start >= 0, options.end > options.start else { throw FileelError.message("The end must be after the start.") }
            try encode(input, output: output, options: options, runner: runner,
                       inputArguments: ["-ss", String(options.start)], extra: ["-t", String(options.end - options.start)])
        case .speed:
            guard (0.25...4).contains(options.speed) else { throw FileelError.message("Choose a speed between 0.25× and 4×.") }
            // atempo accepts 0.5 through 2 per stage while preserving pitch
            let tempo: [String] = options.speed < 0.5 ? ["atempo=0.5", "atempo=\(options.speed * 2)"] :
                options.speed > 2 ? ["atempo=2", "atempo=\(options.speed / 2)"] : ["atempo=\(options.speed)"]
            try encode(input, output: output, options: options, runner: runner,
                       filters: ["setpts=PTS/\(options.speed)"], audioFilters: tempo)
        case .cropVideo:
            guard options.width > 0, options.height > 0, options.x >= 0, options.y >= 0 else { throw FileelError.message("Enter a valid crop rectangle in pixels.") }
            try encode(input, output: output, options: options, runner: runner,
                       filters: ["crop=\(options.width):\(options.height):\(options.x):\(options.y)"])
        case .redactVideo:
            guard options.width > 0, options.height > 0, options.end > options.start else { throw FileelError.message("Enter the rectangle and time range to cover.") }
            try encode(input, output: output, options: options, runner: runner,
                       filters: ["drawbox=x=\(options.x):y=\(options.y):w=\(options.width):h=\(options.height):color=black:t=fill:enable='between(t,\(options.start),\(options.end))'"])
        case .bleep:
            try BleepEngine.process(input, output: output, options: options, runner: runner)
        case .snapshots:
            try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-ss", String(max(0, options.start)), "-i", input.path, "-frames:v", "1", output.path])
        case .visualizer:
            let width = options.width > 0 ? min(3840, options.width) : 1280
            let height = options.height > 0 ? min(2160, options.height) : 720
            try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-i", input.path,
                "-filter_complex", "[0:a]showwaves=s=\(width)x\(height):mode=cline:colors=0x50C8DC:rate=30,format=yuv420p[v]",
                "-map", "[v]", "-map", "0:a", "-c:v", "h264_videotoolbox", "-c:a", "aac", "-shortest", output.path])
        default: throw FileelError.message("This is not a media operation.")
        }
    }

    static func split(_ input: URL, folder: URL, options: OperationOptions, runner: ProcessRunner) throws {
        let total = try duration(input, runner: runner)
        let values = options.splitPoints.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.allSatisfy({ $0 != nil && $0! > 0 && $0! < total }) else {
            throw FileelError.message("Enter split times in seconds, separated by commas, within the video duration.")
        }
        let points = [0] + Array(Set(values.compactMap { $0 })).sorted() + [total]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<(points.count - 1) {
            try runner.checkCancellation()
            var segment = options
            segment.start = points[index]
            segment.end = points[index + 1]
            try process(input, tool: .trimVideo, output: folder.appendingPathComponent("Clip \(index + 1).mp4"), options: segment, runner: runner)
        }
    }

    static func join(_ inputs: [URL], output: URL, options: OperationOptions, runner: ProcessRunner) throws {
        try VideoJoinEngine.join(inputs, output: output, options: options, runner: runner)
    }

    static func joinAudio(_ inputs: [URL], output: URL, options: OperationOptions, runner: ProcessRunner) throws {
        var clips: [URL] = []
        for (index, input) in inputs.enumerated() {
            let clip = output.deletingLastPathComponent().appendingPathComponent("audio-\(index).wav")
            try encode(input, output: clip, options: options, runner: runner, extra: ["-ar", "48000", "-ac", "2"])
            clips.append(clip)
        }
        let list = output.deletingLastPathComponent().appendingPathComponent("audio-clips.txt")
        try clips.map { "file '\($0.lastPathComponent)'" }.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "concat", "-safe", "1", "-i", list.path,
            "-c:a", "aac", "-b:a", bitrate(options), output.path])
    }
}
