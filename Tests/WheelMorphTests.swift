import XCTest
@testable import FileelCore

// cover every directed mode change, including empty menus and grouped file selections
final class WheelMorphTests: XCTestCase {
    func testEveryCatalogTransitionKeepsSlotsInTheirOwnRing() {
        let capacity = max(FileAction.radialOrder.count, FileFamily.allCases.map { max($0.outputs.count, $0.tools.count) }.max() ?? 0)
        var selections = ["png", "jpg", "mp4", "gif", "wav", "pdf", "docx", "pptx", "xlsx", "srt", "zip", "bin"].map {
            [URL(fileURLWithPath: "/sample.\($0)")]
        }
        selections += [[URL(fileURLWithPath: "/one.png"), URL(fileURLWithPath: "/two.jpg")],
                       [URL(fileURLWithPath: "/one.png"), URL(fileURLWithPath: "/two.pdf")]]
        for files in selections {
            let layouts = MenuMode.allCases.map { mode in
                let count = Catalog.operations(for: files, mode: mode).count
                let slots = WheelGeometry.morphSlots(count: count, capacity: capacity)
                XCTAssertEqual(slots.compactMap(\.operationIndex).sorted(), Array(0..<count))
                XCTAssertEqual(Set(slots.map(\.id)).count, slots.count)
                return slots
            }
            for from in layouts.indices {
                for to in layouts.indices where from != to {
                    XCTAssertEqual(layouts[from].map(\.id), layouts[to].map(\.id))
                    for (a, b) in zip(layouts[from], layouts[to]) {
                        XCTAssertEqual(a.item.ring, b.item.ring)
                        for frame in 0...30 {
                            let t = Double(frame) / 30
                            let inner = a.item.inner + (b.item.inner - a.item.inner) * t
                            let outer = a.item.outer + (b.item.outer - a.item.outer) * t
                            XCTAssertGreaterThan(inner, WheelGeometry.hubRadius)
                            XCTAssertGreaterThanOrEqual(outer, inner)
                            XCTAssertLessThanOrEqual(outer, 224)
                        }
                    }
                }
            }
        }
    }

    func testCollapsedSlotsHaveFiniteGeometryAndCannotFlipTheirRoundedCorners() {
        for count in 0...24 {
            let slots = WheelGeometry.morphSlots(count: count, capacity: 24)
            for slot in slots {
                XCTAssertTrue(slot.item.angle.isFinite)
                XCTAssertTrue(slot.item.sweep.isFinite)
                XCTAssertEqual(slot.item.slotID, slot.id)
                XCTAssertLessThanOrEqual(slot.item.cornerRadius * 2, slot.item.outer - slot.item.inner)
            }
            XCTAssertEqual(slots.filter { $0.operationIndex != nil }.count, count)
        }
        for count in 0...8 {
            XCTAssertEqual(WheelGeometry.morphSlots(count: count, capacity: count).compactMap(\.operationIndex).sorted(), Array(0..<count))
        }
    }
}
