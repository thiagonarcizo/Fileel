import AVFoundation
import Foundation

// temporary playback copies never become the source used by an edit or export
struct MediaPreviewSource: @unchecked Sendable {
    let url: URL
    let duration: Double
    let videoSize: CGSize
    let temporaryDirectory: URL?

    func removeTemporaryFiles() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    static func prepare(_ input: URL, runner: ProcessRunner) async throws -> MediaPreviewSource {
        try runner.checkCancellation()
        if let native = try? await inspect(input) { return native }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        do {
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try runner.checkCancellation()
                    let isVideo = FileFamily.detect(input) == .video
                    let output = directory.appendingPathComponent(isVideo ? "preview.mp4" : "preview.m4a")
                    let base = ["-v", "error", "-nostdin", "-y", "-i", input.path]
                    let tracks = isVideo ? ["-map", "0:v:0", "-map", "0:a:0?"] : ["-map", "0:a:0", "-vn"]
                    // try a quick container change first so compatible encoded streams need no extra processing
                    do {
                        try runner.run(Engines.require("ffmpeg"), base + tracks + ["-c", "copy", "-map_metadata", "-1", "-movflags", "+faststart", output.path])
                        if let remuxed = try? await inspect(output) {
                            try runner.checkCancellation()
                            return MediaPreviewSource(url: output, duration: remuxed.duration,
                                                      videoSize: remuxed.videoSize, temporaryDirectory: directory)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { try runner.checkCancellation() }
                    let dimensions = isVideo ? try sourceVideoSize(input, runner: runner) : .zero
                    var encoding = ["-c:a", "aac", "-b:a", "160k"]
                    if isVideo {
                        encoding += ["-c:v", "h264_videotoolbox", "-b:v", "4000k", "-pix_fmt", "yuv420p",
                                     "-vf", "scale=w='min(1440,iw)':h='min(1440,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1"]
                    }
                    try runner.run(Engines.require("ffmpeg"), base + tracks + encoding + ["-map_metadata", "-1", "-movflags", "+faststart", output.path])
                    let playable = try await inspect(output)
                    try runner.checkCancellation()
                    // crop coordinates stay in original pixels even when playback uses a smaller proxy
                    return MediaPreviewSource(url: output, duration: playable.duration,
                                              videoSize: isVideo ? dimensions : .zero, temporaryDirectory: directory)
                }.value
            } onCancel: { runner.cancel() }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func inspect(_ url: URL) async throws -> MediaPreviewSource {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw FileelError.message("The playback format is unavailable.") }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw FileelError.message("The media duration is unavailable.") }
        var size = CGSize.zero
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let displayed = natural.applying(transform)
            size = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        }
        try Task.checkCancellation()
        return MediaPreviewSource(url: url, duration: duration, videoSize: size, temporaryDirectory: nil)
    }

    private static func sourceVideoSize(_ input: URL, runner: ProcessRunner) throws -> CGSize {
        let text = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-select_streams", "v:0", "-show_entries",
            "stream=width,height:stream_side_data=rotation:stream_tags=rotate", "-of", "json", input.path])
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        guard let stream = (json?["streams"] as? [[String: Any]])?.first,
              let width = stream["width"] as? Double, let height = stream["height"] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw FileelError.message("The video dimensions are unavailable.")
        }
        let side = (stream["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Double }.first
        let tag = (stream["tags"] as? [String: String])?["rotate"].flatMap(Double.init)
        let rotation = abs((side ?? tag ?? 0).truncatingRemainder(dividingBy: 180))
        return rotation > 45 && rotation < 135 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
