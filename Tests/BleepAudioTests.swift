import XCTest
@testable import FileelCore

// inspect decoded samples so a successful encode cannot hide audio leaking across the selected boundaries
final class BleepAudioTests: XCTestCase {
    private var folder: URL!
    private let rate = 48_000

    override func setUpWithError() throws {
        guard Engines.locate("ffmpeg") != nil, Engines.locate("ffprobe") != nil else { throw XCTSkip("The media runtimes are required") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-bleep-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    func testSingleSelectionReplacesExactSamplesWithoutChangingAudioOutsideIt() throws {
        let input = try fixture()
        let original = try Data(contentsOf: input)
        let before = try samples(input)
        var options = OperationOptions()
        options.start = 0.21337
        options.end = 0.47919
        let output = folder.appendingPathComponent("single.wav")
        try MediaEngine.process(input, tool: .bleep, output: output, options: options, runner: ProcessRunner())
        let after = try samples(output)
        XCTAssertEqual(after.count, before.count)
        let first = Int(ceil(options.start * Double(rate)))
        let last = Int(floor(options.end * Double(rate)))
        // a short attack starts quietly inside the chosen range rather than leaving the old frame audible
        XCTAssertLessThan(abs(after[first * 2]), 0.005)
        XCTAssertLessThan(abs(after[first * 2 + 1]), 0.005)
        for frame in [0, first - 1, last + 1, rate] {
            XCTAssertEqual(after[frame * 2], before[frame * 2], "left channel outside the selection at \(frame)")
            XCTAssertEqual(after[frame * 2 + 1], before[frame * 2 + 1], "right channel outside the selection at \(frame)")
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testMultipleAndOverlappingRangesReplaceBothChannelsAndKeepEveryOtherSample() throws {
        let input = try fixture()
        let before = try samples(input)
        var options = OperationOptions()
        options.usesBleepRanges = true
        options.bleepRanges = [AudioRedactionRange(start: 0.2, end: 0.4), AudioRedactionRange(start: 0.8, end: 1),
                               AudioRedactionRange(start: 0.95, end: 1.1)]
        let output = folder.appendingPathComponent("multiple.wav")
        try MediaEngine.process(input, tool: .bleep, output: output, options: options, runner: ProcessRunner())
        let after = try samples(output)
        XCTAssertEqual(after.count, before.count)
        var changedOutside = 0
        for frame in 0..<min(before.count, after.count) / 2 {
            let time = Double(frame) / Double(rate)
            let replaced = options.bleepRanges.contains { time >= $0.start && time <= $0.end }
            if !replaced, after[frame * 2] != before[frame * 2] || after[frame * 2 + 1] != before[frame * 2 + 1] { changedOutside += 1 }
        }
        XCTAssertEqual(changedOutside, 0)
        for start in [0.24, 0.84] {
            for channel in 0..<2 {
                XCTAssertGreaterThan(amplitude(after, frequency: 1000, channel: channel, start: start), 0.14)
                XCTAssertLessThan(amplitude(after, frequency: channel == 0 ? 440 : 660, channel: channel, start: start), 0.001)
            }
        }
    }

    func testKeepQualityPreservesFloatPCMAnd24BitLosslessAudio() throws {
        let input = try fixture(codec: "pcm_f32le")
        let pcm24 = try fixture(codec: "pcm_s24le")
        let alac = folder.appendingPathComponent("source.m4a")
        let flac = folder.appendingPathComponent("source.flac")
        let runner = ProcessRunner()
        for (url, codec) in [(alac, "alac"), (flac, "flac")] {
            try runner.run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-i", pcm24.path,
                "-c:a", codec, "-sample_fmt", codec == "alac" ? "s32p" : "s32", "-bits_per_raw_sample", "24", url.path])
        }
        for source in [input, alac, flac] {
            let before = try samples(source)
            var options = OperationOptions()
            options.start = 0.2; options.end = 0.4
            let output = folder.appendingPathComponent("edited-\(source.lastPathComponent)")
            try MediaEngine.process(source, tool: .bleep, output: output, options: options, runner: runner)
            let after = try samples(output)
            XCTAssertEqual(after.count, before.count)
            for frame in [100, 25_003, 50_001] {
                XCTAssertEqual(after[frame * 2], before[frame * 2], source.lastPathComponent)
                XCTAssertEqual(after[frame * 2 + 1], before[frame * 2 + 1], source.lastPathComponent)
            }
            let codec = try runner.run(Engines.require("ffprobe"), ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,bits_per_raw_sample", "-of", "json", output.path])
            if source == input { XCTAssertTrue(codec.contains("pcm_f32le")) }
            else { XCTAssertTrue(codec.contains("24"), codec) }
        }
    }

    func testInvalidOrRemovedSelectionsCannotProduceAnOutput() throws {
        let input = try fixture()
        let original = try Data(contentsOf: input)
        let output = folder.appendingPathComponent("invalid.wav")
        var options = OperationOptions()
        options.usesBleepRanges = true
        XCTAssertNotNil(OperationRequirements.issue(for: .tool(.bleep), inputs: [input], options: options))
        for ranges: [AudioRedactionRange] in [[], [.init(start: .nan, end: 1)], [.init(start: 0, end: .infinity)],
                                            [.init(start: -1, end: 0.5)], [.init(start: 1, end: 0.5)], [.init(start: 0, end: 2)]] {
            options.bleepRanges = ranges
            XCTAssertThrowsError(try MediaEngine.process(input, tool: .bleep, output: output, options: options, runner: ProcessRunner()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    private func fixture(codec: String = "pcm_s16le") throws -> URL {
        let input = folder.appendingPathComponent("source-\(codec).wav")
        try ProcessRunner().run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            "aevalsrc=0.2*sin(2*PI*440*t)|0.2*sin(2*PI*660*t):s=48000:d=1.4", "-c:a", codec, input.path])
        return input
    }

    private func amplitude(_ samples: [Float], frequency: Double, channel: Int, start: Double) -> Double {
        let begin = Int((start * Double(rate)).rounded())
        let count = rate / 10
        var real = 0.0, imaginary = 0.0
        for frame in begin..<begin + count {
            let phase = 2 * Double.pi * frequency * Double(frame) / Double(rate)
            let value = Double(samples[frame * 2 + channel])
            real += value * cos(phase)
            imaginary += value * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(count)
    }

    private func samples(_ input: URL) throws -> [Float] {
        let raw = folder.appendingPathComponent("\(UUID().uuidString).f32")
        try ProcessRunner().run(Engines.require("ffmpeg"), ["-v", "error", "-nostdin", "-y", "-i", input.path,
            "-map", "0:a:0", "-f", "f32le", "-c:a", "pcm_f32le", raw.path])
        let data = try Data(contentsOf: raw)
        return data.withUnsafeBytes { buffer in
            stride(from: 0, to: buffer.count, by: MemoryLayout<Float>.size).map { buffer.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
    }
}
