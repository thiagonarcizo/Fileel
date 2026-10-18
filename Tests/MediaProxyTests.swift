import AVFoundation
import XCTest
@testable import FileelCore

// exercise real unsupported containers and decode the proxy through the same native player stack
final class MediaProxyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        guard Engines.locate("ffmpeg") != nil, Engines.locate("ffprobe") != nil else { throw XCTSkip("The media runtime is required") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-playback-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    func testUnsupportedVideoGetsPlayableCopyWithOriginalCropDimensions() async throws {
        let input = folder.appendingPathComponent("lossless.mkv")
        try ProcessRunner().run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=1920x1080:rate=10:duration=0.6", "-c:v", "ffv1", input.path])
        let original = try Data(contentsOf: input)
        let preview = try await MediaPreviewSource.prepare(input, runner: ProcessRunner())
        defer { preview.removeTemporaryFiles() }
        XCTAssertNotEqual(preview.url, input)
        XCTAssertNotNil(preview.temporaryDirectory)
        XCTAssertEqual(preview.videoSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(preview.duration, 0.6, accuracy: 0.15)
        let asset = AVURLAsset(url: preview.url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertLessThanOrEqual(size.width, 1440)
        XCTAssertEqual(size.width / size.height, 1920.0 / 1080, accuracy: 0.01)
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600))
        XCTAssertGreaterThan(frame.image.width, 0, "the native stack must decode a real frame")
        XCTAssertEqual(try Data(contentsOf: input), original)
        preview.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.url.path))
    }

    func testUnsupportedAudioGetsPlayableCopyAndNativeAudioKeepsOriginal() async throws {
        let input = folder.appendingPathComponent("tone.ogg")
        try ProcessRunner().run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "sine=frequency=440:duration=0.6", "-c:a", "libvorbis", input.path])
        let original = try Data(contentsOf: input)
        let preview = try await MediaPreviewSource.prepare(input, runner: ProcessRunner())
        defer { preview.removeTemporaryFiles() }
        XCTAssertEqual(preview.videoSize, .zero)
        XCTAssertEqual(preview.duration, 0.6, accuracy: 0.15)
        let playable = try await AVURLAsset(url: preview.url).load(.isPlayable)
        XCTAssertTrue(playable)
        let peaks = try await WaveformSampler.read(preview.url, duration: preview.duration)
        XCTAssertGreaterThan(peaks.max() ?? 0, 0.1, "the native stack must decode audible samples")
        XCTAssertEqual(try Data(contentsOf: input), original)
        let native = folder.appendingPathComponent("native.m4a")
        try ProcessRunner().run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-i", input.path, "-c:a", "aac", native.path])
        let direct = try await MediaPreviewSource.prepare(native, runner: ProcessRunner())
        XCTAssertEqual(direct.url, native)
        XCTAssertNil(direct.temporaryDirectory)
    }

    func testCancelledPreparationDoesNotCreateAPlaybackCopy() async throws {
        let input = folder.appendingPathComponent("cancelled.mkv")
        try ProcessRunner().run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=320x180:rate=10:duration=0.6", "-c:v", "ffv1", input.path])
        let runner = ProcessRunner()
        runner.cancel()
        do {
            let unexpected = try await MediaPreviewSource.prepare(input, runner: runner)
            unexpected.removeTemporaryFiles()
            XCTFail("a cancelled preparation must not start a converter")
        } catch is CancellationError { }
    }

    func testCompatibleVideoIsRemuxedWithoutReencodingItsFrames() async throws {
        let runner = ProcessRunner()
        let input = folder.appendingPathComponent("compatible.mkv")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=320x180:rate=10:duration=0.6", "-c:v", "h264_videotoolbox", input.path])
        let preview = try await MediaPreviewSource.prepare(input, runner: runner)
        defer { preview.removeTemporaryFiles() }
        func encodedHash(_ url: URL) throws -> String {
            try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-i", url.path,
                "-map", "0:v:0", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"])
        }
        XCTAssertEqual(try encodedHash(input), try encodedHash(preview.url))
        XCTAssertEqual(preview.videoSize, CGSize(width: 320, height: 180))
    }
}
