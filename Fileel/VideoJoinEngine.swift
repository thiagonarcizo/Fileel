import Foundation

// keep compatible streams intact and normalize only clips that need a common playback format
enum VideoJoinEngine {
    private struct Clip {
        let duration: Double
        let width: Int
        let height: Int
        let fps: Double
        let bitrate: Double
        let hasAudio: Bool
        let canCopyToMP4: Bool
        let signature: Data
    }

    static func join(_ inputs: [URL], output: URL, options: OperationOptions, runner: ProcessRunner) throws {
        guard inputs.count >= 2 else { throw FileelError.message("Choose at least two videos to join.") }
        let clips = try inputs.map { try inspect($0, runner: runner) }
        let first = clips[0]
        let workspace = output.deletingLastPathComponent().appendingPathComponent("join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        if options.keepQuality, clips.allSatisfy({ $0.canCopyToMP4 && $0.signature == first.signature }) {
            // safe local aliases keep quotes, line breaks and protocol-looking filenames out of concat scripts
            let aliases = try inputs.enumerated().map { index, source in
                let link = workspace.appendingPathComponent("source-\(index).media")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
                return link
            }
            do {
                try concatenate(aliases, metadataSource: inputs[0], output: output, options: options, runner: runner, workspace: workspace, preservePackets: true)
                return
            } catch is CancellationError { throw CancellationError() }
            catch { try? FileManager.default.removeItem(at: output) }
        }
        // the first clip defines the canvas instead of forcing every selection down to 720p
        let width = max(2, first.width / 2 * 2), height = max(2, first.height / 2 * 2)
        let fps = clips.map(\.fps).max() ?? 30
        let hasAudio = clips.contains(where: \.hasAudio)
        let preservedBitrate = max(clips.map(\.bitrate).max() ?? 0, Double(width) * Double(height) * fps * 0.16)
        let bitrate = options.keepQuality ? max(1_000_000, preservedBitrate) : 1_000_000 + options.quality * 7_000_000
        var normalized: [URL] = []
        for (index, input) in inputs.enumerated() {
            try runner.checkCancellation()
            let spec = clips[index]
            let destination = workspace.appendingPathComponent("clip-\(index).mp4")
            var args = ["-v", "error", "-nostdin", "-y", "-i", input.path]
            if hasAudio, !spec.hasAudio {
                args += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]
            }
            args += ["-map", "0:v:0", "-vf", "scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps)",
                     "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p", "-b:v", String(Int(min(500_000_000, bitrate)))]
            if hasAudio {
                args += ["-map", spec.hasAudio ? "0:a:0" : "1:a:0", "-af", "aresample=async=1:first_pts=0,apad",
                         "-ar", "48000", "-ac", "2", "-c:a", "aac", "-b:a", "256k"]
            } else { args += ["-an"] }
            args += ["-t", String(spec.duration), "-shortest", "-map_metadata", "-1", destination.path]
            try runner.run(Engines.require("ffmpeg"), args)
            normalized.append(destination)
        }
        try concatenate(normalized, metadataSource: inputs[0], output: output, options: options, runner: runner, workspace: workspace, preservePackets: false)
    }

    private static func concatenate(_ inputs: [URL], metadataSource: URL, output: URL, options: OperationOptions, runner: ProcessRunner,
                                    workspace: URL, preservePackets: Bool) throws {
        let list = workspace.appendingPathComponent("clips.ffconcat")
        let lines = inputs.map { "file '\($0.lastPathComponent)'" }.joined(separator: "\n")
        try ("ffconcat version 1.0\n" + lines + "\n").write(to: list, atomically: true, encoding: .utf8)
        var args = ["-v", "error", "-nostdin", "-y", "-f", "concat", "-safe", "1"]
        if preservePackets { args += ["-auto_convert", "0"] }
        args += ["-i", list.path]
        let keepMetadata = options.preserveMetadata && !options.stripMetadata
        if keepMetadata { args += ["-i", metadataSource.path] }
        args += ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-movflags", "+faststart",
                 "-map_metadata", keepMetadata ? "1" : "-1"]
        if !options.author.isEmpty { args += ["-metadata", "artist=\(options.author)"] }
        if !options.title.isEmpty { args += ["-metadata", "title=\(options.title)"] }
        try runner.run(Engines.require("ffmpeg"), args + [output.path])
    }

    private static func inspect(_ input: URL, runner: ProcessRunner) throws -> Clip {
        let text = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-show_streams", "-show_format", "-show_data", "-of", "json", input.path])
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let streams = json?["streams"] as? [[String: Any]] ?? []
        guard let video = streams.first(where: { $0["codec_type"] as? String == "video" }),
              let rawWidth = video["width"] as? Int, let rawHeight = video["height"] as? Int,
              (1...16384).contains(rawWidth), (1...16384).contains(rawHeight) else {
            throw FileelError.message("One of the selected files has no supported video track.")
        }
        let format = json?["format"] as? [String: Any] ?? [:]
        let duration = Double(video["duration"] as? String ?? "") ?? Double(format["duration"] as? String ?? "") ?? 0
        guard duration.isFinite, duration > 0 else { throw FileelError.message("One of the selected videos has no readable duration.") }
        let parts = (video["avg_frame_rate"] as? String ?? "").split(separator: "/").compactMap { Double($0) }
        let rate = parts.count == 2 && parts[1] != 0 ? parts[0] / parts[1] : 30
        let fps = rate.isFinite && rate > 0 ? rate : 30
        let sampleAspect = (video["sample_aspect_ratio"] as? String ?? "").split(separator: ":").compactMap { Double($0) }
        let aspect = sampleAspect.count == 2 && sampleAspect[1] > 0 ? sampleAspect[0] / sampleAspect[1] : 1
        let displayWidth = (Double(rawWidth) * (aspect.isFinite && aspect > 0 ? aspect : 1)).rounded()
        guard (1...16384).contains(displayWidth) else { throw FileelError.message("The video's display dimensions are too large to join.") }
        let tagRotation = (video["tags"] as? [String: String])?["rotate"].flatMap(Double.init)
        let side = (video["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Double }.first ?? tagRotation ?? 0
        let rotated = abs(side.truncatingRemainder(dividingBy: 180)) > 45 && abs(side.truncatingRemainder(dividingBy: 180)) < 135
        // compare decoder setup and orientation rather than guessing compatibility from the file extension
        let keys = ["codec_type", "codec_name", "codec_tag_string", "profile", "width", "height", "pix_fmt", "sample_rate", "channels",
                    "channel_layout", "time_base", "r_frame_rate", "sample_aspect_ratio", "extradata", "color_space", "color_transfer", "color_primaries", "side_data_list"]
        let signature = try JSONSerialization.data(withJSONObject: streams.map { stream in stream.filter { keys.contains($0.key) } }, options: [.sortedKeys])
        let bitrate = Double(video["bit_rate"] as? String ?? "") ?? Double(format["bit_rate"] as? String ?? "") ?? 0
        let nativeVideo = ["h264", "hevc"].contains(video["codec_name"] as? String ?? "")
        let nativeAudio = streams.filter { $0["codec_type"] as? String == "audio" }.allSatisfy {
            ["aac", "alac", "mp3"].contains($0["codec_name"] as? String ?? "")
        }
        return Clip(duration: duration, width: rotated ? rawHeight : Int(displayWidth), height: rotated ? Int(displayWidth) : rawHeight,
                    fps: fps, bitrate: bitrate.isFinite ? max(0, bitrate) : 0,
                    hasAudio: streams.contains { $0["codec_type"] as? String == "audio" }, canCopyToMP4: nativeVideo && nativeAudio,
                    signature: signature)
    }
}
