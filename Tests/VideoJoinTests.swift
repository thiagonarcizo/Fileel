import AVFoundation
import XCTest
@testable import FileelCore

// inspect encoded packets and the decoded audio timeline to catch silent-clip joins that only look successful
final class VideoJoinTests: XCTestCase {
    private var folder: URL!
    private let runner = ProcessRunner()

    override func setUpWithError() throws {
        guard Engines.locate("ffmpeg") != nil, Engines.locate("ffprobe") != nil else { throw XCTSkip("The media runtime is required") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-video-join-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func clip(_ name: String, size: String, rate: Int, audio: Bool) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var args = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=\(rate):duration=0.8"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=0.8"] }
        args += ["-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p"]
        if audio { args += ["-c:a", "aac", "-shortest"] }
        try runner.run(Engines.require("ffmpeg"), args + ["-metadata", "title=Join Fixture", url.path])
        return url
    }

    func testCompatibleClipsRetainEncodedFramesAndNativeDimensions() throws {
        let source = try clip("quote's\nsource.mp4", size: "1920x1080", rate: 15, audio: false)
        let original = try Data(contentsOf: source)
        let output = folder.appendingPathComponent("combined.mp4")
        try MediaEngine.join([source, source], output: output, options: .init(), runner: runner)
        func packets(_ input: URL, name: String) throws -> Data {
            let target = folder.appendingPathComponent(name)
            try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-i", input.path, "-map", "0:v:0", "-c", "copy", "-f", "data", target.path])
            return try Data(contentsOf: target)
        }
        let sourcePackets = try packets(source, name: "source-packets.bin")
        XCTAssertEqual(try packets(output, name: "joined-packets.bin"), sourcePackets + sourcePackets,
                       "keep quality should copy compatible encoded frames without another generation")
        let streams = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", output.path])
        XCTAssertEqual(streams.trimmingCharacters(in: .whitespacesAndNewlines), "1920,1080")
        XCTAssertEqual(try MediaEngine.duration(output, runner: runner), 1.6, accuracy: 0.15)
        let tags = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-show_entries", "format_tags=title", "-of", "json", output.path])
        XCTAssertTrue(tags.contains("Join Fixture"))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMixedSilentAndAudibleClipsKeepTheirAudioTimeline() async throws {
        let silent = try clip("silent.mp4", size: "640x360", rate: 15, audio: false)
        let audible = try clip("audible.mp4", size: "320x180", rate: 25, audio: true)
        let output = folder.appendingPathComponent("mixed.mp4")
        try MediaEngine.join([silent, audible], output: output, options: .init(), runner: runner)
        let duration = try MediaEngine.duration(output, runner: runner)
        XCTAssertEqual(duration, 1.6, accuracy: 0.2)
        let asset = AVURLAsset(url: output)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videos.first)
        let size = try await track.load(.naturalSize)
        let rate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(size, CGSize(width: 640, height: 360))
        XCTAssertEqual(rate, 25, accuracy: 0.1)
        let peaks = try await WaveformSampler.read(output, duration: duration, bins: 100)
        XCTAssertLessThan(peaks.prefix(35).max() ?? 1, 0.01, "the first silent clip must not inherit the second clip's audio")
        XCTAssertGreaterThan(peaks.suffix(35).max() ?? 0, 0.5, "the second clip's audio must survive the join")
    }

    func testAnamorphicClipsUseTheirDisplayAspectAndSilentJoinsStaySilent() async throws {
        let source = try clip("anamorphic-source.mp4", size: "720x576", rate: 10, audio: false)
        let anamorphic = folder.appendingPathComponent("anamorphic.mp4")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-i", source.path,
            "-vf", "setsar=64/45", "-c:v", "h264_videotoolbox", "-an", anamorphic.path])
        let squarePixels = try clip("square.mp4", size: "320x180", rate: 15, audio: false)
        let output = folder.appendingPathComponent("display-aspect.mp4")
        try MediaEngine.join([anamorphic, squarePixels], output: output, options: .init(), runner: runner)
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(video.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1024, height: 576))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "joining silent clips should not invent an audio track")
    }
}
