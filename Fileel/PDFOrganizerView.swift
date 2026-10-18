import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// serialize pdfkit access and render thumbnails only for cards that enter the visible grid
actor PDFThumbnailRenderer {
    private var url: URL?
    private var document: PDFDocument?
    func load(_ url: URL) throws -> Int {
        if self.url != url { document = try PDFEngine.load(url); self.url = url }
        return document?.pageCount ?? 0
    }
    func thumbnail(_ url: URL, edit: PDFPageEdit) throws -> PDFThumbnail {
        try Task.checkCancellation()
        _ = try load(url)
        guard let page = document?.page(at: edit.sourceIndex)?.copy() as? PDFPage else { throw FileelError.message("This page is unavailable.") }
        page.rotation = ((page.rotation + edit.rotation) % 360 + 360) % 360
        let image = page.thumbnail(of: CGSize(width: 340, height: 420), for: .cropBox)
        try Task.checkCancellation()
        return PDFThumbnail(image: image)
    }
}

struct PDFThumbnail: @unchecked Sendable { let image: NSImage }

// the page array is the export contract; thumbnails, selection, and reordering all edit that array
struct PDFOrganizerView: View {
    let url: URL
    @Binding var options: OperationOptions
    @State private var selected: Set<UUID> = []
    @State private var anchor: UUID?
    @State private var dragging: Set<UUID> = []
    @State private var error: String?
    @State private var ready = false
    @State private var undoStack: [[PDFPageEdit]] = []
    @State private var redoStack: [[PDFPageEdit]] = []
    @State private var restoring = false
    @State private var initializing = false
    @State private var renderer = PDFThumbnailRenderer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let dragType = UTType(exportedAs: "xyz.narcizo.fileel.pdf-page")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("\(options.pdfPages.count) pages").font(.system(size: 12, weight: .medium))
                if !selected.isEmpty { Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { rotate(-90) } label: { Image(systemName: "rotate.left") }.help("Rotate selected pages left").disabled(selected.isEmpty)
                Button { rotate(90) } label: { Image(systemName: "rotate.right") }.help("Rotate selected pages right").disabled(selected.isEmpty)
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate selected pages (⌘D)").keyboardShortcut("d").disabled(selected.isEmpty)
                Button { remove() } label: { Image(systemName: "trash") }.help("Remove selected pages (Delete)").keyboardShortcut(.delete, modifiers: []).disabled(selected.isEmpty)
                Divider().frame(height: 18)
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo (⌘Z)").keyboardShortcut("z").disabled(undoStack.isEmpty)
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("Redo (⇧⌘Z)").keyboardShortcut("z", modifiers: [.command, .shift]).disabled(redoStack.isEmpty)
                Menu {
                    Button("Select All") { selected = Set(options.pdfPages.map(\.id)) }.keyboardShortcut("a")
                    Button("Reverse Order") { options.pdfPages.reverse() }
                    Button("Sort by Original Page") { options.pdfPages.sort { $0.sourceIndex < $1.sourceIndex } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
            }.buttonStyle(.borderless).padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if let error { ContentUnavailableView("Pages Unavailable", systemImage: "doc", description: Text(error)) }
            else if !ready { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 220), spacing: 24)], spacing: 26) {
                        ForEach(Array(options.pdfPages.enumerated()), id: \.element.id) { index, edit in
                            PDFPageCard(url: url, edit: edit, position: index + 1, selected: selected.contains(edit.id), renderer: renderer)
                                .onTapGesture { select(edit.id) }
                                .onDrag {
                                    if !selected.contains(edit.id) { selected = [edit.id] }
                                    dragging = selected
                                    let provider = NSItemProvider()
                                    provider.registerDataRepresentation(forTypeIdentifier: Self.dragType.identifier, visibility: .ownProcess) { completion in
                                        completion(Data(edit.id.uuidString.utf8), nil); return nil
                                    }
                                    return provider
                                }
                                .onDrop(of: [Self.dragType], delegate: PDFPageDropDelegate(target: edit.id, pages: $options.pdfPages, dragging: $dragging, reduceMotion: reduceMotion))
                                .contextMenu {
                                    Button("Rotate Left") { selected = [edit.id]; rotate(-90) }
                                    Button("Rotate Right") { selected = [edit.id]; rotate(90) }
                                    Button("Duplicate") { selected = [edit.id]; duplicate() }
                                    Button("Remove") { selected = [edit.id]; remove() }
                                }
                        }
                        Color.clear.frame(height: 60).onDrop(of: [Self.dragType], delegate: PDFPageDropDelegate(target: nil, pages: $options.pdfPages, dragging: $dragging, reduceMotion: reduceMotion))
                    }.padding(28)
                }.background(Color(nsColor: .underPageBackgroundColor))
            }
            Divider()
            Text("Drag pages to reorder · ⌘-click to select more · Shift-click to select a range")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .task(id: url) {
            do {
                let count = try await renderer.load(url)
                try Task.checkCancellation()
                if options.pdfPages.isEmpty { initializing = true; options.pdfPages = (0..<count).map { PDFPageEdit(sourceIndex: $0) } }
                ready = true; undoStack = []; redoStack = []
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onChange(of: options.pdfPages) { old, pages in
            if initializing { initializing = false }
            else if restoring { restoring = false }
            else if ready { undoStack.append(old); redoStack = [] }
            selected.formIntersection(Set(pages.map(\.id)))
        }
    }

    private func select(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.shift), let anchor, let first = options.pdfPages.firstIndex(where: { $0.id == anchor }), let last = options.pdfPages.firstIndex(where: { $0.id == id }) {
            selected = Set(options.pdfPages[min(first, last)...max(first, last)].map(\.id))
        } else if NSEvent.modifierFlags.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        } else { selected = [id]; anchor = id }
    }
    private func rotate(_ degrees: Int) {
        options.pdfPages = options.pdfPages.map { page in
            var page = page
            if selected.contains(page.id) { page.rotation = ((page.rotation + degrees) % 360 + 360) % 360 }
            return page
        }
    }
    private func duplicate() {
        var result: [PDFPageEdit] = []
        var copies: Set<UUID> = []
        for page in options.pdfPages {
            result.append(page)
            if selected.contains(page.id) { var copy = page; copy.id = UUID(); result.append(copy); copies.insert(copy.id) }
        }
        options.pdfPages = result; selected = copies
    }
    private func remove() { options.pdfPages.removeAll { selected.contains($0.id) }; selected = [] }
    private func undo() {
        guard let pages = undoStack.popLast() else { return }
        redoStack.append(options.pdfPages); restoring = true; options.pdfPages = pages
    }
    private func redo() {
        guard let pages = redoStack.popLast() else { return }
        undoStack.append(options.pdfPages); restoring = true; options.pdfPages = pages
    }
}

private struct PDFPageCard: View {
    let url: URL
    let edit: PDFPageEdit
    let position: Int
    let selected: Bool
    let renderer: PDFThumbnailRenderer
    @State private var thumbnail: NSImage?
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.2), radius: 7, y: 4)
                } else { ProgressView().controlSize(.small) }
            }.frame(height: 206).padding(12)
                .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: selected ? 2 : 1))
            HStack(spacing: 6) {
                Text("\(position)").font(.system(size: 12, weight: .medium).monospacedDigit())
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).font(.system(size: 12)) }
            }
            Text("Original page \(edit.sourceIndex + 1)").font(.system(size: 10)).foregroundStyle(.secondary)
        }.contentShape(Rectangle())
            .task(id: edit) { thumbnail = try? await renderer.thumbnail(url, edit: edit).image }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(position), original page \(edit.sourceIndex + 1)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PDFPageDropDelegate: DropDelegate {
    let target: UUID?
    @Binding var pages: [PDFPageEdit]
    @Binding var dragging: Set<UUID>
    let reduceMotion: Bool
    func validateDrop(info: DropInfo) -> Bool { !dragging.isEmpty }
    func dropEntered(info: DropInfo) {
        guard !dragging.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { pages = PDFPageLayout.moving(pages, ids: dragging, over: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = []; return true }
}
