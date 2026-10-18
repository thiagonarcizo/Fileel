import Foundation

// each visible card has its own identity so duplicates can be moved and rotated independently
struct PDFPageEdit: Identifiable, Hashable, Sendable {
    var id = UUID()
    let sourceIndex: Int
    var rotation = 0
}

enum PDFPageLayout {
    static func moving(_ pages: [PDFPageEdit], ids: Set<UUID>, over target: UUID?) -> [PDFPageEdit] {
        guard !ids.isEmpty, let first = pages.firstIndex(where: { ids.contains($0.id) }) else { return pages }
        if let target, ids.contains(target) { return pages }
        let moving = pages.filter { ids.contains($0.id) }
        var result = pages.filter { !ids.contains($0.id) }
        let insertion: Int
        if let target, let originalTarget = pages.firstIndex(where: { $0.id == target }), let remainingTarget = result.firstIndex(where: { $0.id == target }) {
            insertion = remainingTarget + (first < originalTarget ? 1 : 0)
        } else { insertion = result.count }
        result.insert(contentsOf: moving, at: insertion)
        return result
    }
}
