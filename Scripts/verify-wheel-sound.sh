#!/bin/zsh
set -eu

# compile the real player with same-file inspection so the check can render its private graph offline
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/fileel-wheel-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
cat "$repo_root/Fileel/WheelSelectionSound.swift" > "$check_dir/main.swift"
cat >> "$check_dir/main.swift" <<'SWIFT'
// render rapid hover transitions offline and check that no queued clicks trail behind them
extension WheelSelectionSound {
    func startOffline() throws {
        try queue.sync {
            guard ready(), let engine, let buffer else { throw NSError(domain: "audio", code: 1) }
            engine.stop()
            try engine.enableManualRenderingMode(.offline, format: buffer.format, maximumFrameCount: 1024)
            try engine.start()
        }
    }
    func render(_ frames: AVAudioFrameCount) throws -> [Float] {
        try queue.sync {
            guard let engine, let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else { return [] }
            var status = try engine.renderOffline(frames, to: output)
            while status == .cannotDoInCurrentContext { status = try engine.renderOffline(frames, to: output) }
            guard status == .success, let samples = output.floatChannelData?[0] else { throw NSError(domain: "audio", code: 2) }
            return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        }
    }
}
let player = WheelSelectionSound(url: URL(fileURLWithPath: CommandLine.arguments[1]))
try player.startOffline()
var audio: [Float] = []
var activeBlocks = 0
for _ in 0..<160 {
    player.play()
    let block = try player.render(200)
    if block.contains(where: { abs($0) > 0.001 }) { activeBlocks += 1 }
    audio += block
}
var tail: [Float] = []
for _ in 0..<24 { tail += try player.render(200) }
let peak = audio.map { abs($0) }.max() ?? 0
let trailing = tail.suffix(2400).map { abs($0) }.max() ?? 0
print("240 transitions/s, \(activeBlocks)/160 active blocks, peak \(peak), final 50 ms peak \(trailing)")
precondition(activeBlocks >= 155, "feedback went silent during rapid hover")
precondition(trailing < 0.0001, "audio queued up after hover stopped")
precondition(peak < 1, "overlapping ticks clipped")
SWIFT
swiftc "$check_dir/main.swift" -o "$check_dir/verify-wheel-sound"
"$check_dir/verify-wheel-sound" "$repo_root/Fileel/WheelTick.wav"
