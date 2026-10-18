import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

// bin decoded PCM peaks without keeping the whole recording in memory
enum WaveformSampler {
    static func read(_ url: URL, duration: Double, bins: Int = 160) async throws -> [Float] {
        guard bins > 0, duration.isFinite, duration > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let worker = Task.detached(priority: .utility) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 8000
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? FileelError.message("Cannot read the audio waveform.") }
            var peaks = [Float](repeating: 0, count: bins)
            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var pointer: UnsafeMutablePointer<Int8>?
                var length = 0
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                      let pointer else { continue }
                let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let frameCount = CMSampleBufferGetNumSamples(sample)
                let channels = max(1, length / MemoryLayout<Float>.size / max(1, frameCount))
                for index in 0..<(length / MemoryLayout<Float>.size) {
                    // peak across channels instead of downmixing, which can cancel opposite-phase audio
                    let bin = min(bins - 1, max(0, Int((start + Double(index / channels) / 8000) / duration * Double(bins))))
                    peaks[bin] = max(peaks[bin], abs(samples[index]))
                }
            }
            if reader.status == .failed { throw reader.error ?? FileelError.message("Cannot finish the audio waveform.") }
            let maximum = max(peaks.max() ?? 0, 0.001)
            return peaks.map { min(1, $0 / maximum) }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
