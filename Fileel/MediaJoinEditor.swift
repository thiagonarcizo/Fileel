import AppKit
import SwiftUI

// a dedicated sequence sidebar lets the user choose the actual playback order before joining
struct MediaJoinEditor: View {
    private struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
    }

    @Binding private var files: [URL]
    @Binding private var options: OperationOptions
    let operation: FileOperation
    @State private var items: [Item]
    @State private var selection: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(files: Binding<[URL]>, operation: FileOperation, options: Binding<OperationOptions>) {
        _files = files
        _options = options
        self.operation = operation
        _items = State(initialValue: files.wrappedValue.map { Item(url: $0) })
    }

    private var selectedIndex: Int? { items.firstIndex { $0.id == selection } }
    private var selected: Item? { items.first { $0.id == selection } ?? items.first }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sequence").font(.headline)
                    Text("Clips play in this order.").font(.caption).foregroundStyle(.secondary)
                }.padding(18)
                List(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text(item.url.pathExtension.uppercased()).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).tag(item.id)
                    }.onMove { indices, destination in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                            items.move(fromOffsets: indices, toOffset: destination)
                        }
                    }
                }.listStyle(.sidebar)
                Divider()
                HStack(spacing: 12) {
                    Button { moveSelection(-1) } label: { Image(systemName: "arrow.up") }
                        .disabled((selectedIndex ?? 0) == 0).help("Move earlier")
                    Button { moveSelection(1) } label: { Image(systemName: "arrow.down") }
                        .disabled(selectedIndex == nil || selectedIndex == items.count - 1).help("Move later")
                    Spacer()
                    Text("\(items.count) clips").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.borderless).padding(16)
                if operation == .tool(.joinVideos) {
                    Text("The first clip sets the frame.").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.bottom, 16)
                }
            }.frame(minWidth: 250, idealWidth: 280, maxWidth: 330)
            if let selected {
                MediaPreviewView(url: selected.url, operation: operation, options: $options)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = items.first?.id } }
        .onChange(of: items) { _, items in files = items.map(\.url) }
    }

    private func moveSelection(_ direction: Int) {
        guard let index = selectedIndex, items.indices.contains(index + direction) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            items.swapAt(index, index + direction)
        }
    }
}
