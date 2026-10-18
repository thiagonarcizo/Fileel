import AVFoundation
import AudioToolbox
import XCTest
@testable import FileelCore

// verify timeline bounds and decode a generated audio file rather than using a decorative waveform
final class MediaPreviewTests: XCTestCase {
    func testTimelineClampAndLongDurationLabels() {
        XCTAssertEqual(TimelineGeometry.time(at: -20, width: 100, duration: 50), 0)
        XCTAssertEqual(TimelineGeometry.time(at: 120, width: 100, duration: 50), 50)
        XCTAssertEqual(TimelineGeometry.position(at: 25, width: 100, duration: 50), 50)
        XCTAssertEqual(TimelineGeometry.position(at: .nan, width: 100, duration: 50), 0)
        XCTAssertEqual(TimelineGeometry.time(at: .infinity, width: 100, duration: 50), 0)
        XCTAssertEqual(TimelineGeometry.label(3661.25), "1:01:01.25")
        XCTAssertEqual(TimelineGeometry.label(62.3), "1:02.30")
        XCTAssertEqual(TimelineGeometry.label(.infinity), "0:00.00")
    }

    func testWaveformContainsDecodedAudioPeaks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-waveform-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<8000 {
            // the second half is silent, giving the decoder an independently checkable envelope
            channel[index] = index < 4000 ? Float(sin(Double(index) / 8000 * 440 * 2 * .pi)) * 0.8 : 0
        }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        try file?.write(from: buffer)
        // release the writer so the WAV header is finalized before the asset reader opens it
        file = nil
        let peaks = try await WaveformSampler.read(url, duration: 1, bins: 80)
        XCTAssertEqual(peaks.count, 80)
        XCTAssertGreaterThan(peaks.prefix(30).max() ?? 0, 0.9)
        XCTAssertLessThan(peaks.suffix(30).max() ?? 1, 0.01)
    }

    func testOppositePhaseStereoStillProducesAVisibleWaveform() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-stereo-waveform-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        let left = try XCTUnwrap(buffer.floatChannelData?[0])
        let right = try XCTUnwrap(buffer.floatChannelData?[1])
        for index in 0..<8000 {
            let value = Float(sin(Double(index) / 8000 * 440 * 2 * .pi)) * 0.8
            left[index] = value; right[index] = -value
        }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        try file?.write(from: buffer); file = nil
        let peaks = try await WaveformSampler.read(url, duration: 1, bins: 80)
        XCTAssertGreaterThan(peaks.max() ?? 0, 0.9)
        XCTAssertGreaterThan(peaks.filter { $0 > 0.5 }.count, 60)
    }
}
