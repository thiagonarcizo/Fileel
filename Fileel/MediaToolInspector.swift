import SwiftUI

// expose controls around the chosen editing task instead of a shared conversion form
struct MediaToolInspector: View {
    let operation: FileOperation
    let family: FileFamily
    @Binding var options: OperationOptions
    let playhead: Double
    let duration: Double
    let videoSize: CGSize
    private var tool: FileTool? { if case .tool(let tool) = operation { return tool }; return nil }
    private var cuts: [Double] { options.splitPoints.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.sorted() }

    var body: some View {
        if tool == .bleep {
            AudioRedactionInspector(options: $options, playhead: playhead, duration: duration)
        } else if tool == .cropVideo {
            CropInspector(size: videoSize, options: $options, alignment: 2)
        } else {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if [.trimAudio, .trimVideo, .bleep, .redactVideo].contains(tool) {
                    section("Selected Range", symbol: "scissors") {
                        TimeField("In", value: $options.start)
                        Button("Set In at Playhead") { options.start = min(playhead, max(0, options.end - 0.05)) }.controlSize(.small)
                        TimeField("Out", value: $options.end)
                        Button("Set Out at Playhead") { options.end = max(options.start + 0.05, playhead) }.controlSize(.small)
                        Text("\(TimelineGeometry.label(max(0, options.end - options.start))) selected").font(.caption).foregroundStyle(.secondary)
                        Button("Use Entire Clip") { options.start = 0; options.end = duration }.controlSize(.small)
                    }
                }
                if tool == .cropVideo || tool == .redactVideo {
                    section(tool == .cropVideo ? "Frame" : "Covered Area", symbol: "crop") {
                        Text("Draw a rectangle on the video preview.").font(.caption).foregroundStyle(.secondary)
                        dimension("Width", value: $options.width)
                        dimension("Height", value: $options.height)
                        dimension("X", value: $options.x)
                        dimension("Y", value: $options.y)
                        if tool == .cropVideo {
                            HStack {
                                ForEach(["16:9", "4:3", "1:1"], id: \.self) { ratio in
                                    Button(ratio) { setRatio(ratio) }.controlSize(.small)
                                }
                            }
                            Button("Use Full Frame") {
                                options.x = 0; options.y = 0; options.width = Int(videoSize.width); options.height = Int(videoSize.height)
                            }.controlSize(.small)
                        }
                    }
                }
                if tool == .splitVideo {
                    section("Cut Markers", symbol: "scissors") {
                        Button("Add Cut at Playhead") {
                            guard playhead > 0, playhead < duration else { return }
                            setCuts(cuts + [playhead])
                        }.controlSize(.small).disabled(playhead <= 0 || playhead >= duration)
                        Text("Scrub to a frame, then add a cut. Each segment is saved as a separate clip.").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(cuts.enumerated()), id: \.offset) { index, time in
                            HStack {
                                Text(TimelineGeometry.label(time)).font(.system(size: 12).monospacedDigit())
                                Spacer()
                                Button { var points = cuts; points.remove(at: index); setCuts(points) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).help("Remove cut")
                            }
                        }
                    }
                }
                if tool == .snapshots {
                    section("Selected Frame", symbol: "camera") {
                        Text(TimelineGeometry.label(playhead)).font(.system(size: 23, weight: .medium).monospacedDigit())
                        Text("Scrub or step through frames, then save a PNG copy.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if tool == .speed {
                    section("Playback Speed", symbol: "speedometer") {
                        Text("\(options.speed, specifier: "%.2f")×").font(.system(size: 30, weight: .medium).monospacedDigit())
                        ResettableSlider(title: "Playback speed", value: $options.speed, range: 0.25...4, defaultValue: 1)
                        HStack {
                            ForEach([0.5, 1.0, 2.0], id: \.self) { rate in Button("\(rate, specifier: "%.1f")×") { options.speed = rate }.controlSize(.small) }
                        }
                        Text("Audio keeps its pitch in the saved copy.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if ![.trimAudio, .trimVideo, .bleep, .redactVideo, .cropVideo, .splitVideo, .snapshots, .speed].contains(tool) {
                    OperationOptionsView(operation: operation, family: family, options: $options)
                        .frame(minHeight: 380)
                }
            }.padding(22)
        }
        }
    }

    private func section<C: View>(_ title: String, symbol: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
            content()
        }
    }
    private func dimension(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            TextField(title, value: value, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 85)
            Text("px").font(.caption).foregroundStyle(.tertiary)
        }
    }
    private func setCuts(_ values: [Double]) { options.splitPoints = Array(Set(values)).sorted().map { String(format: "%.3f", $0) }.joined(separator: ",") }
    private func setRatio(_ text: String) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        let ratio = parts[0] / parts[1]
        let width = min(videoSize.width, videoSize.height * ratio)
        let height = width / ratio
        options.width = Int(width) / 2 * 2; options.height = Int(height) / 2 * 2
        options.x = Int((videoSize.width - width) / 2); options.y = Int((videoSize.height - height) / 2)
    }
}

// seconds remain editable while the adjacent labels use readable timecode
private struct TimeField: View {
    let title: String
    @Binding var value: Double
    init(_ title: String, value: Binding<Double>) { self.title = title; _value = value }
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            TextField(title, value: $value, format: .number.precision(.fractionLength(3))).labelsHidden().multilineTextAlignment(.trailing).frame(width: 100)
            Text("s").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
