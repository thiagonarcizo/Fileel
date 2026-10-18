import AVFAudio
import Foundation

// keep disk reads and audio setup off the hover path, with a small pool for overlapping detents
final class WheelSelectionSound: @unchecked Sendable {
    static let shared = WheelSelectionSound(url: Bundle.main.url(forResource: "WheelTick", withExtension: "wav"))
    private let url: URL?
    private let queue = DispatchQueue(label: "xyz.narcizo.Fileel.wheel-sound", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var buffer: AVAudioPCMBuffer?
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var idleTimer: DispatchSourceTimer?

    init(url: URL?) { self.url = url }

    // warm up while the ring opens so the first hover only needs to schedule a buffer
    func prepare() {
        queue.async { [self] in
            guard ready() else { return }
            idleTimer?.schedule(deadline: .now() + .milliseconds(600))
        }
    }

    func play() {
        let requested = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            guard ready(), let buffer else { return }
            idleTimer?.schedule(deadline: .now() + .milliseconds(600))
            // discard stale feedback after a device stall instead of replaying old hovers in a burst
            guard DispatchTime.now().uptimeNanoseconds - requested < 80_000_000 else { return }
            let voice = voices[nextVoice]
            nextVoice = (nextVoice + 1) % voices.count
            // reuse voices without stopping the engine or queuing a tail behind earlier selections
            voice.scheduleBuffer(buffer, at: nil, options: .interrupts)
            if !voice.isPlaying { voice.play() }
        }
    }

    private func ready() -> Bool {
        do {
            if engine == nil {
                guard let url else { return false }
                let file = try AVAudioFile(forReading: url)
                guard let samples = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return false }
                try file.read(into: samples)
                let audio = AVAudioEngine()
                let players = (0..<4).map { _ in AVAudioPlayerNode() }
                for player in players {
                    audio.attach(player)
                    audio.connect(player, to: audio.mainMixerNode, format: samples.format)
                    player.prepare(withFrameCount: samples.frameLength)
                }
                audio.prepare()
                engine = audio; buffer = samples; voices = players
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.setEventHandler { [weak self] in
                    // release the render thread when the menu is quiet, keeping the decoded sound ready
                    self?.engine?.pause()
                }
                timer.schedule(deadline: .distantFuture)
                timer.resume()
                idleTimer = timer
            }
            if engine?.isRunning == false { try engine?.start() }
            return true
        } catch {
            // sound failures stay silent and never interfere with selecting a file operation
            return false
        }
    }

    deinit { idleTimer?.cancel() }
}
