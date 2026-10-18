import AVFoundation
import AVKit
import AudioToolbox
import Combine
import CoreMedia
import SwiftUI

// own player observers explicitly so switching files never leaves audio playing in the background
@MainActor
final class MediaPreviewModel: ObservableObject {
    let player = AVPlayer()
    @Published var duration = 0.0
    @Published var current = 0.0
    @Published var ready = false
    @Published var playing = false
    @Published var waveform: [Float] = []
    @Published var videoSize = CGSize.zero
    @Published var error: String?
    private var observer: Any?
    private var playbackObservation: NSKeyValueObservation?
    private var previewSource: MediaPreviewSource?
    private var previewRunner: ProcessRunner?
    private var loadID = UUID()
    var rangeEnd: Double?

    func load(_ url: URL) async {
        stop()
        let id = loadID
        let runner = ProcessRunner()
        previewRunner = runner
        var pending: MediaPreviewSource?
        do {
            let prepared = try await MediaPreviewSource.prepare(url, runner: runner)
            pending = prepared
            try Task.checkCancellation()
            guard loadID == id else { throw CancellationError() }
            let time = prepared.duration
            let asset = AVURLAsset(url: prepared.url)
            previewSource = prepared
            pending = nil
            videoSize = prepared.videoSize
            duration = time
            current = 0
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.loadID == id else { return }
                    self.current = time.seconds
                    if let rangeEnd = self.rangeEnd, self.current >= rangeEnd { self.player.pause() }
                }
            }
            playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let playing = player.timeControlStatus == .playing
                guard let model = self else { return }
                Task { @MainActor in if model.loadID == id { model.playing = playing } }
            }
            ready = true
            error = nil
            let peaks = (try? await WaveformSampler.read(prepared.url, duration: time)) ?? []
            try Task.checkCancellation()
            guard loadID == id else { return }
            waveform = peaks
        } catch is CancellationError { pending?.removeTemporaryFiles() }
        catch {
            pending?.removeTemporaryFiles()
            if !Task.isCancelled, loadID == id { self.error = error.localizedDescription }
        }
    }

    func seek(_ seconds: Double) {
        player.pause()
        let clamped = min(duration, max(0, seconds))
        current = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggle(start: Double, end: Double, rate: Double) {
        if playing { player.pause(); return }
        if current < start || current >= end {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard finished, let model = self else { return }
                Task { @MainActor in model.player.playImmediately(atRate: Float(rate)) }
            }
        } else { player.playImmediately(atRate: Float(rate)) }
    }

    func stop() {
        loadID = UUID()
        previewRunner?.cancel()
        previewRunner = nil
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        playbackObservation = nil
        player.replaceCurrentItem(with: nil)
        previewSource?.removeTemporaryFiles()
        previewSource = nil
        ready = false; playing = false; waveform = []; videoSize = .zero; duration = 0; current = 0; rangeEnd = nil; error = nil
    }
}

// keep playback, scrubbing, and trim handles beside the media rather than in a separate dialog
struct MediaPreviewView: View {
    let url: URL
    let operation: FileOperation?
    @Binding var options: OperationOptions
    @StateObject private var media = MediaPreviewModel()
    @ObservedObject private var jobs = AppModel.shared
    var onPosition: (Double) -> Void = { _ in }
    var onDuration: (Double) -> Void = { _ in }
    var onVideoSize: (CGSize) -> Void = { _ in }
    private var editsRectangle: Bool { operation == .tool(.cropVideo) || operation == .tool(.redactVideo) }
    private var isVideo: Bool { FileFamily.detect(url) == .video }
    private var editsRange: Bool {
        if operation == .tool(.bleep) { return !options.bleepRanges.isEmpty }
        return [.tool(.trimAudio), .tool(.trimVideo), .tool(.redactVideo)].contains(operation)
    }
    private var speed: Double { operation == .tool(.speed) ? options.speed : 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                if media.duration > 0 { Text(TimelineGeometry.label(media.duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }.padding(.horizontal, 18).padding(.vertical, 12)
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let error = media.error {
                    ContentUnavailableView("Preview Unavailable", systemImage: isVideo ? "film" : "waveform", description: Text(error))
                } else if media.ready {
                    if isVideo {
                        if editsRectangle {
                            MediaPlayerSurface(player: media.player)
                                .overlay {
                                    if operation == .tool(.cropVideo) {
                                        CropOverlay(size: media.videoSize, options: $options, inset: 0, alignment: 2, pause: { media.player.pause() })
                                    } else {
                                        VideoRectangleOverlay(size: media.videoSize, options: $options, redaction: true, pause: { media.player.pause() })
                                    }
                                }
                        } else { VideoPlayer(player: media.player) }
                    }
                    else {
                        VStack(spacing: 16) {
                            Image(systemName: "waveform").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text(url.lastPathComponent).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                            Text("Ready to preview").font(.caption).foregroundStyle(.secondary)
                        }.padding(24)
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Preparing Preview").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if media.ready {
                VStack(spacing: 12) {
                    MediaTimeline(waveform: media.waveform, duration: media.duration, current: media.current,
                                  start: $options.start, end: $options.end, editsRange: editsRange,
                                  cuts: operation == .tool(.splitVideo) ? options.splitPoints.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } : [],
                                  markedRanges: operation == .tool(.bleep) ? options.bleepRanges : [], seek: media.seek)
                        .frame(height: 68)
                    HStack(spacing: 12) {
                        Button { media.toggle(start: editsRange ? options.start : 0, end: editsRange ? options.end : media.duration, rate: speed) } label: {
                            Label(media.playing ? "Pause" : operation == .tool(.bleep) ? "Play Original" : "Play", systemImage: media.playing ? "pause.fill" : "play.fill")
                        }.controlSize(.small).keyboardShortcut(.space, modifiers: []).help("Play / Pause (Space)")
                        if isVideo {
                            Button { media.player.pause(); media.player.currentItem?.step(byCount: -1) } label: { Image(systemName: "backward.frame") }.help("Previous frame")
                            Button { media.player.pause(); media.player.currentItem?.step(byCount: 1) } label: { Image(systemName: "forward.frame") }.help("Next frame")
                        }
                        Spacer(minLength: 0)
                        Text(TimelineGeometry.label(media.current)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                    if editsRange {
                        Text("Drag the handles to choose the range. Playback stops at the selection’s end.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16)
            }
        }
        .task(id: url) { await media.load(url) }
        .onChange(of: jobs.busy) { _, busy in if busy { media.player.pause() } }
        .onChange(of: media.duration) { _, duration in
            resetSelection()
            onDuration(duration)
        }
        .onChange(of: operation) { _, _ in
            media.player.pause()
            resetSelection()
        }
        .onChange(of: options.end) { _, end in media.rangeEnd = editsRange ? end : nil }
        .onChange(of: editsRange) { _, editing in media.rangeEnd = editing ? options.end : nil }
        .onChange(of: options.speed) { _, _ in if media.playing { media.player.rate = Float(speed) } }
        .onChange(of: media.current) { _, current in
            onPosition(current)
            if operation == .tool(.snapshots) { options.start = current }
        }
        .onChange(of: media.videoSize) { _, size in
            onVideoSize(size)
            if operation == .tool(.cropVideo), options.width <= 0, size.width > 0 {
                CropGeometry.apply(CGRect(origin: .zero, size: size), to: &options, alignment: 2)
            }
        }
        .onDisappear { media.stop() }
    }

    private func resetSelection() {
        guard media.duration > 0 else { return }
        if operation == .tool(.bleep) {
            if !options.usesBleepRanges {
                options.usesBleepRanges = true
            }
            if let first = options.bleepRanges.first { options.start = first.start; options.end = first.end }
        } else if editsRange { options.start = 0; options.end = media.duration }
        media.rangeEnd = editsRange ? options.end : nil
    }
}

private struct MediaTimeline: View {
    let waveform: [Float]
    let duration: Double
    let current: Double
    @Binding var start: Double
    @Binding var end: Double
    let editsRange: Bool
    let cuts: [Double]
    let markedRanges: [AudioRedactionRange]
    var seek: (Double) -> Void
    @State private var handle: Int?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let startX = TimelineGeometry.position(at: start, width: size.width, duration: duration)
                let endX = TimelineGeometry.position(at: end, width: size.width, duration: duration)
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Color(nsColor: .controlBackgroundColor)))
                for range in markedRanges {
                    let a = TimelineGeometry.position(at: range.start, width: size.width, duration: duration)
                    let b = TimelineGeometry.position(at: range.end, width: size.width, duration: duration)
                    context.fill(Path(roundedRect: CGRect(x: a, y: 0, width: max(0, b - a), height: size.height), cornerRadius: 4), with: .color(.accentColor.opacity(0.12)))
                }
                if editsRange {
                    context.fill(Path(CGRect(x: startX, y: 0, width: max(0, endX - startX), height: size.height)), with: .color(.accentColor.opacity(0.14)))
                }
                for (index, amplitude) in waveform.enumerated() {
                    let x = Double(index) / Double(max(1, waveform.count - 1)) * size.width
                    let height = max(2, Double(amplitude) * (size.height - 14))
                    context.fill(Path(roundedRect: CGRect(x: x, y: (size.height - height) / 2, width: max(1, size.width / Double(max(1, waveform.count)) - 1), height: height), cornerRadius: 1), with: .color(.secondary.opacity(0.7)))
                }
                if editsRange {
                    for x in [startX, endX] {
                        context.fill(Path(roundedRect: CGRect(x: min(size.width - 6, max(0, x - 3)), y: 0, width: 6, height: size.height), cornerRadius: 3), with: .color(.accentColor))
                    }
                }
                for time in cuts where time > 0 && time < duration {
                    let x = TimelineGeometry.position(at: time, width: size.width, duration: duration)
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.accentColor))
                }
                let cursor = TimelineGeometry.position(at: current, width: size.width, duration: duration)
                context.fill(Path(CGRect(x: min(size.width - 1.5, cursor), y: 2, width: 1.5, height: size.height - 4)), with: .color(.primary))
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if handle == nil {
                    let a = TimelineGeometry.position(at: start, width: geometry.size.width, duration: duration)
                    let b = TimelineGeometry.position(at: end, width: geometry.size.width, duration: duration)
                    handle = editsRange && abs(value.startLocation.x - a) < 16 ? 0 : editsRange && abs(value.startLocation.x - b) < 16 ? 1 : 2
                }
                let time = TimelineGeometry.time(at: value.location.x, width: geometry.size.width, duration: duration)
                if handle == 0 { start = min(max(0, end - 0.05), time); seek(start) }
                else if handle == 1 { end = min(duration, max(start + 0.05, time)); seek(end) }
                else { seek(time) }
            }.onEnded { _ in handle = nil })
        }
        .accessibilityElement()
        .accessibilityLabel("Media timeline")
        .accessibilityValue(TimelineGeometry.label(current))
        .accessibilityAdjustableAction { direction in seek(current + (direction == .increment ? 1 : -1)) }
    }
}

// spatial tools use the video surface without a transport overlay competing for the pointer
private struct MediaPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

// draw directly over the displayed frame with the same top-left pixel coordinates used by ffmpeg
private struct VideoRectangleOverlay: View {
    let size: CGSize
    @Binding var options: OperationOptions
    let redaction: Bool
    var pause: () -> Void
    @State private var origin: CGPoint?
    var body: some View {
        GeometryReader { geometry in
            let fitted = CanvasGeometry.imageRect(size: size, in: CGRect(origin: .zero, size: geometry.size), inset: 0)
            Canvas { context, _ in
                guard size.width > 0, size.height > 0, options.width > 0, options.height > 0 else { return }
                let box = CGRect(x: fitted.minX + CGFloat(options.x) / size.width * fitted.width,
                                 y: fitted.minY + CGFloat(options.y) / size.height * fitted.height,
                                 width: CGFloat(options.width) / size.width * fitted.width,
                                 height: CGFloat(options.height) / size.height * fitted.height)
                if redaction { context.fill(Path(box), with: .color(.black)) }
                else {
                    var mask = Path(fitted); mask.addRect(box)
                    context.fill(mask, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                    var thirds = Path()
                    for fraction in [1.0 / 3, 2.0 / 3] {
                        thirds.move(to: CGPoint(x: box.minX + box.width * fraction, y: box.minY))
                        thirds.addLine(to: CGPoint(x: box.minX + box.width * fraction, y: box.maxY))
                        thirds.move(to: CGPoint(x: box.minX, y: box.minY + box.height * fraction))
                        thirds.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * fraction))
                    }
                    context.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 1)
                }
                context.stroke(Path(box), with: .color(.white), lineWidth: 2)
                context.stroke(Path(box), with: .color(.accentColor), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard size.width > 0, size.height > 0, fitted.contains(value.startLocation) else { return }
                if origin == nil { origin = CanvasGeometry.normalized(value.startLocation, imageRect: fitted); pause() }
                guard let origin else { return }
                let end = CanvasGeometry.normalized(value.location, imageRect: fitted)
                let crop = CanvasGeometry.crop(from: origin, to: end, imageSize: size)
                options.x = Int(crop.minX); options.y = Int(crop.minY)
                options.width = Int(crop.width); options.height = Int(crop.height)
            }.onEnded { _ in origin = nil })
        }.accessibilityLabel(redaction ? "Video redaction region" : "Video crop region")
            .accessibilityHint("Drag over the frame or enter precise dimensions in the inspector")
    }
}
