import AppKit
import PDFKit
import SwiftUI

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
    @State private var error: String?
    @State private var ready = false
    @State private var undoStack: [[PDFPageEdit]] = []
    @State private var redoStack: [[PDFPageEdit]] = []
    @State private var restoring = false
    @State private var initializing = false
    @State private var renderer = PDFThumbnailRenderer()

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
                PDFPageGrid(url: url, pages: $options.pdfPages, selection: $selected, renderer: renderer,
                            onRotate: rotate, onDuplicate: duplicate, onRemove: remove)
                    .background(Color(nsColor: .underPageBackgroundColor))
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

// appkit owns selection and drag sessions so thumbnail clicks cannot swallow a page drag
private struct PDFPageGrid: NSViewRepresentable {
    let url: URL
    @Binding var pages: [PDFPageEdit]
    @Binding var selection: Set<UUID>
    let renderer: PDFThumbnailRenderer
    let onRotate: (Int) -> Void
    let onDuplicate: () -> Void
    let onRemove: () -> Void
    private static let pasteboardType = NSPasteboard.PasteboardType("xyz.narcizo.fileel.pdf-page")
    private static let itemID = NSUserInterfaceItemIdentifier("PDFPageCard")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let collection = PageCollectionView()
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 24
        layout.minimumLineSpacing = 26
        layout.sectionInset = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(PageCollectionItem.self, forItemWithIdentifier: Self.itemID)
        collection.registerForDraggedTypes([Self.pasteboardType])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setDraggingSourceOperationMask([], forLocal: false)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.menuProvider = { [weak coordinator = context.coordinator] index in coordinator?.menu(at: index) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = collection
        collection.frame = scroll.contentView.bounds
        collection.autoresizingMask = [.width, .height]
        context.coordinator.collection = collection
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let collection = coordinator.collection else { return }
        coordinator.updating = true
        if coordinator.renderedPages != pages {
            coordinator.renderedPages = pages
            collection.reloadData()
        }
        collection.selectionIndexPaths = Set(pages.enumerated().compactMap {
            selection.contains($0.element.id) ? IndexPath(item: $0.offset, section: 0) : nil
        })
        coordinator.updating = false
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: PDFPageGrid
        weak var collection: PageCollectionView?
        var renderedPages: [PDFPageEdit] = []
        var updating = false
        private var dragging: Set<UUID> = []

        init(_ parent: PDFPageGrid) { self.parent = parent }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { parent.pages.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: PDFPageGrid.itemID, for: indexPath) as! PageCollectionItem
            item.configure(url: parent.url, edit: parent.pages[indexPath.item], position: indexPath.item + 1, renderer: parent.renderer)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
        private func syncSelection() {
            guard !updating, let collection else { return }
            parent.selection = Set(collection.selectionIndexPaths.compactMap { index in
                parent.pages.indices.contains(index.item) ? parent.pages[index.item].id : nil
            })
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            let item = NSPasteboardItem()
            item.setString(parent.pages[indexPath.item].id.uuidString, forType: PDFPageGrid.pasteboardType)
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            dragging = Set(indexPaths.map { parent.pages[$0.item].id })
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            // cancelled and outside drops must not leave a selection armed for the next drag
            dragging = []
        }
        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard let source = draggingInfo.draggingSource as? NSCollectionView, source === collectionView, !dragging.isEmpty else { return [] }
            proposedDropOperation.pointee = .before
            return .move
        }
        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let source = draggingInfo.draggingSource as? NSCollectionView, source === collectionView, !dragging.isEmpty,
                  (0...parent.pages.count).contains(indexPath.item) else { return false }
            // commit once on drop so undo restores the whole move in one step
            parent.pages = PDFPageLayout.inserting(parent.pages, ids: dragging, before: indexPath.item)
            return true
        }

        func menu(at index: IndexPath) -> NSMenu {
            if let collection, !collection.selectionIndexPaths.contains(index) {
                collection.selectionIndexPaths = [index]
                syncSelection()
            }
            let menu = NSMenu()
            for (title, action) in [("Rotate Left", #selector(rotateLeft)), ("Rotate Right", #selector(rotateRight)),
                                    ("Duplicate", #selector(duplicate)), ("Remove", #selector(remove))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            return menu
        }
        @objc private func rotateLeft() { parent.onRotate(-90) }
        @objc private func rotateRight() { parent.onRotate(90) }
        @objc private func duplicate() { parent.onDuplicate() }
        @objc private func remove() { parent.onRemove() }
    }
}

private final class PageCollectionView: NSCollectionView {
    var menuProvider: ((IndexPath) -> NSMenu?)?
    override func layout() {
        if let layout = collectionViewLayout as? NSCollectionViewFlowLayout, let width = enclosingScrollView?.contentView.bounds.width, width > 56 {
            let columns = max(1, floor((width - 56 + 24) / (172 + 24)))
            let size = NSSize(width: min(220, floor((width - 56 - (columns - 1) * 24) / columns)), height: 282)
            if layout.itemSize != size { layout.itemSize = size }
        }
        super.layout()
        // the document must fill its viewport before it can receive thumbnail mouse events
        if let viewport = enclosingScrollView?.contentView.bounds, let layout = collectionViewLayout {
            let height = max(viewport.height, layout.collectionViewContentSize.height)
            if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuProvider?(index)
    }
}

// forward thumbnail mouse tracking to appkit instead of letting the hosting view consume it
private final class PageCardHostingView: NSHostingView<AnyView> {
    // appkit supplies this point in the superview's coordinates
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    private var collection: NSCollectionView? {
        var ancestor = superview
        while let view = ancestor {
            if let collection = view as? NSCollectionView { return collection }
            ancestor = view.superview
        }
        return nil
    }
    override func mouseDown(with event: NSEvent) {
        if let collection {
            collection.mouseDown(with: event)
        }
        else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let collection { collection.mouseDragged(with: event) }
        else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if let collection { collection.mouseUp(with: event) }
        else { super.mouseUp(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { collection?.menu(for: event) }
}

private final class PageCollectionItem: NSCollectionViewItem {
    private var card: PDFPageCard?
    // hosted cards have no appkit image outlet, so supply the native drag preview explicitly
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = view.bounds
        return [component]
    }
    override func loadView() {
        let hosting = PageCardHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        view = hosting
    }
    override var isSelected: Bool { didSet { refresh() } }
    func configure(url: URL, edit: PDFPageEdit, position: Int, renderer: PDFThumbnailRenderer) {
        card = PDFPageCard(url: url, edit: edit, position: position, selected: false, renderer: renderer)
        refresh()
    }
    private func refresh() {
        guard let card, let hosting = view as? PageCardHostingView else { return }
        hosting.rootView = AnyView(PDFPageCard(url: card.url, edit: card.edit, position: card.position, selected: isSelected, renderer: card.renderer))
    }
}
