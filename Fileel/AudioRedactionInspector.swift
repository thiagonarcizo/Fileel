import SwiftUI

// keep the selected word range editable while showing every replacement in the recording
struct AudioRedactionInspector: View {
    @Binding var options: OperationOptions
    let playhead: Double
    let duration: Double
    @State private var selected: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Bleep Ranges", systemImage: "speaker.slash").font(.headline)
                    Text("Replace marked words with a soft tone. Play the original to check the timing.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button(action: addRange) { Label("Add Range at Playhead", systemImage: "plus") }
                    .disabled(duration <= 0 || options.bleepRanges.count >= BleepEngine.maximumRanges)
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                LazyVStack(spacing: 6) {
                    ForEach(Array(options.bleepRanges.enumerated()), id: \.element.id) { index, range in
                        HStack(spacing: 10) {
                            Button { select(range) } label: {
                                HStack(spacing: 10) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).frame(width: 22, height: 22)
                                        .background(.primary.opacity(0.06), in: Circle())
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Range \(index + 1)").font(.system(size: 12, weight: .medium))
                                        Text("\(TimelineGeometry.label(range.start)) – \(TimelineGeometry.label(range.end))")
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Select range \(index + 1)")
                            Button { options.bleepRanges.removeAll { $0.id == range.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove range \(index + 1)")
                                .accessibilityLabel("Remove range \(index + 1)")
                        }
                        .padding(10)
                        .background(selected == range.id ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                if let selected, options.bleepRanges.contains(where: { $0.id == selected }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Selected Range").font(.system(size: 12, weight: .semibold))
                        timeField("In", value: $options.start)
                        Button("Set In at Playhead") { options.start = min(max(0, playhead), max(0, options.end - 0.05)) }.controlSize(.small)
                        timeField("Out", value: $options.end)
                        Button("Set Out at Playhead") { options.end = min(duration, max(options.start + 0.05, playhead)) }.controlSize(.small)
                        Text("Drag the waveform handles to refine this range.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Add a range, then drag its handles on the waveform.").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(22)
        }
        .onChange(of: options.bleepRanges.map(\.id), initial: true) { _, ids in
            if selected == nil || !ids.contains(selected!) {
                if let first = options.bleepRanges.first { select(first) }
                else { selected = nil }
            }
        }
        .onChange(of: options.start) { _, _ in updateSelection() }
        .onChange(of: options.end) { _, _ in updateSelection() }
    }

    private func select(_ range: AudioRedactionRange) {
        selected = range.id
        options.start = range.start
        options.end = range.end
    }

    private func addRange() {
        guard duration > 0, options.bleepRanges.count < BleepEngine.maximumRanges else { return }
        let start = min(max(0, playhead), max(0, duration - 0.05))
        let range = AudioRedactionRange(start: start, end: min(duration, start + 1))
        options.usesBleepRanges = true
        options.bleepRanges.append(range)
        select(range)
    }

    private func updateSelection() {
        guard let selected, let index = options.bleepRanges.firstIndex(where: { $0.id == selected }) else { return }
        options.bleepRanges[index].start = options.start
        options.bleepRanges[index].end = options.end
    }

    private func timeField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 95)
            Text("s").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
