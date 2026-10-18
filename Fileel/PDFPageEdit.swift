import Foundation

// each visible card has its own identity so duplicates can be moved and rotated independently
struct PDFPageEdit: Identifiable, Hashable, Sendable {
    var id = UUID()
    let sourceIndex: Int
    var rotation = 0
}

enum PDFPageLayout {
    // appkit reports a gap before an item, so remove the dragged pages before adjusting that gap
    static func inserting(_ pages: [PDFPageEdit], ids: Set<UUID>, before index: Int) -> [PDFPageEdit] {
        guard (0...pages.count).contains(index), !ids.isEmpty else { return pages }
        let moving = pages.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return pages }
        var result = pages.filter { !ids.contains($0.id) }
        let removedBefore = pages.prefix(index).filter { ids.contains($0.id) }.count
        result.insert(contentsOf: moving, at: index - removedBefore)
        return result
    }

}
