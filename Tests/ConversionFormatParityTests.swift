import AppKit
import XCTest
@testable import FileelCore

// cover the missing output families with real decodes rather than counting catalog entries alone
final class ConversionFormatParityTests: XCTestCase {
    private var folder: URL!
    private let runner = ProcessRunner()

    override func setUpWithError() throws {
        guard Engines.locate("ffmpeg") != nil, Engines.locate("ffprobe") != nil else { throw XCTSkip("The media runtimes are required") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-format-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    func testBMPOutputFromEveryOtherImageInput() throws {
        XCTAssertTrue(FileFamily.image.outputs.contains("bmp"))
        let context = try ImageEngine.context(width: 96, height: 64)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        let png = folder.appendingPathComponent("source.png")
        try ImageEngine.write(XCTUnwrap(context.makeImage()), to: png, options: .init())
        let svg = folder.appendingPathComponent("source.svg")
        try "<svg xmlns='http://www.w3.org/2000/svg' width='96' height='64'><rect width='96' height='64' fill='red'/></svg>".write(to: svg, atomically: true, encoding: .utf8)
        let thumbnail = try ImageEngine.load(svg, maximumPixelSize: 48)
        XCTAssertEqual(thumbnail.width, 48)
        XCTAssertEqual(thumbnail.height, 32)
        let oversizedLimit = try ImageEngine.load(svg, maximumPixelSize: 1024)
        XCTAssertEqual(oversizedLimit.width, 96)
        for ext in ["jpg", "png", "webp", "heic", "tiff", "avif", "svg"] {
            let input = ext == "png" ? png : ext == "svg" ? svg : try convert(png, to: ext)
            let original = try Data(contentsOf: input)
            let output = try convert(input, to: "bmp")
            XCTAssertEqual(try Data(contentsOf: output).prefix(2), Data([0x42, 0x4d]))
            let decoded = try ImageEngine.load(output)
            XCTAssertEqual(decoded.width, 96, ext)
            XCTAssertEqual(decoded.height, 64, ext)
            let color = try XCTUnwrap(NSBitmapImageRep(cgImage: decoded).colorAt(x: 48, y: 32)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(color.redComponent, 0.9, ext)
            XCTAssertLessThan(color.blueComponent, 0.1, ext)
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testWMAOutputFromEveryOtherAudioInput() throws {
        XCTAssertTrue(FileFamily.audio.outputs.contains("wma"))
        let wav = folder.appendingPathComponent("source.wav")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=48000:duration=0.6", wav.path])
        for ext in ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"] {
            let input = ext == "wav" ? wav : try convert(wav, to: ext)
            let original = try Data(contentsOf: input)
            let output = try convert(input, to: "wma")
            XCTAssertGreaterThan(try MediaEngine.duration(output, runner: runner), 0.5, ext)
            XCTAssertTrue(try codec(output, stream: "a:0").contains("wmav2"), ext)
            let decoded = try convert(output, to: "wav")
            XCTAssertGreaterThan(try MediaEngine.duration(decoded, runner: runner), 0.5, ext)
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testAVIAndWMVOutputsFromEveryOtherVideoInput() throws {
        XCTAssertTrue(FileFamily.video.outputs.contains("avi"))
        XCTAssertTrue(FileFamily.video.outputs.contains("wmv"))
        let gif = folder.appendingPathComponent("silent.gif")
        let movie = folder.appendingPathComponent("sound.mp4")
        XCTAssertFalse(Catalog.operations(for: [gif], mode: .convert).contains(.convert("mp3")))
        XCTAssertFalse(Catalog.operations(for: [gif, movie], mode: .convert).contains(.convert("mp3")))
        XCTAssertTrue(Catalog.operations(for: [movie], mode: .convert).contains(.convert("mp3")))
        let source = folder.appendingPathComponent("source.mp4")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=160x120:rate=10:duration=0.6", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.6",
            "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source.path])
        for ext in ["mp4", "mov", "mkv", "webm", "gif", "avi", "wmv"] {
            let input = ext == "mp4" ? source : try convert(source, to: ext)
            let original = try Data(contentsOf: input)
            for target in ["avi", "wmv"] where target != ext {
                let output = try convert(input, to: target)
                XCTAssertGreaterThan(try MediaEngine.duration(output, runner: runner), 0.4, "\(ext) to \(target)")
                let stream = try codec(output, stream: "v:0")
                XCTAssertTrue(stream.contains(target == "avi" ? "mpeg4" : "wmv2"), stream)
                let audio = try codec(output, stream: "a:0")
                XCTAssertEqual(audio.contains("codec_name"), ext != "gif", "\(ext) to \(target)")
                let frame = folder.appendingPathComponent("\(UUID().uuidString).png")
                try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-i", output.path, "-frames:v", "1", frame.path])
                let decoded = try ImageEngine.load(frame)
                XCTAssertEqual(decoded.width, 160)
                XCTAssertEqual(decoded.height, 120)
            }
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    // legacy windows audio accepts at most stereo and 48 kHz, including when stored in a video container
    func testWindowsAudioNegotiatesHighRateSurroundAndPreservesMono() throws {
        let input = folder.appendingPathComponent("surround.wav")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=96000:duration=0.6", "-ac", "6", "-c:a", "pcm_s24le", input.path])
        let original = try Data(contentsOf: input)
        let movie = folder.appendingPathComponent("surround.mkv")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=160x120:rate=10:duration=0.6", "-i", input.path,
            "-c:v", "h264_videotoolbox", "-c:a", "copy", "-shortest", movie.path])
        for (source, format) in [(input, "wma"), (movie, "wmv")] {
            let output = try convert(source, to: format)
            let info = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-select_streams", "a:0",
                "-show_entries", "stream=channels,sample_rate", "-of", "json", output.path])
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any])
            let streams = try XCTUnwrap(root["streams"] as? [[String: Any]])
            let audio = try XCTUnwrap(streams.first)
            XCTAssertEqual(audio["channels"] as? Int, 2)
            XCTAssertEqual(audio["sample_rate"] as? String, "48000")
            XCTAssertGreaterThan(try MediaEngine.duration(output, runner: runner), 0.5)
        }
        let mono = folder.appendingPathComponent("mono.wav")
        try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=44100:duration=0.6", mono.path])
        let output = try convert(mono, to: "wma")
        let info = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=channels,sample_rate", "-of", "csv=p=0", output.path])
        XCTAssertEqual(info.trimmingCharacters(in: .whitespacesAndNewlines), "44100,1")
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    private func convert(_ input: URL, to format: String) throws -> URL {
        let work = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return try ConversionEngine.convert(input, format: format, folder: work, options: .init(), runner: runner)
    }

    private func codec(_ input: URL, stream: String) throws -> String {
        try runner.run(Engines.require("ffprobe"), ["-v", "error", "-select_streams", stream,
            "-show_entries", "stream=codec_name,width,height", "-of", "json", input.path])
    }
}
