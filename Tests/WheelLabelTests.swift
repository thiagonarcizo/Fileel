import AppKit
import XCTest
@testable import FileelCore

// measure the actual radial captions at their smallest allowed font, including diagonal slices
final class WheelLabelTests: XCTestCase {
    func testEveryCatalogWordFitsWithoutBreakingLetters() {
        var groups = FileFamily.allCases.flatMap { family in
            [family.outputs.map(FileOperation.convert), family.tools.map(FileOperation.tool),
             family.tools.filter { !$0.grouped }.map(FileOperation.tool)]
        }
        groups.append(FileAction.radialOrder.map(FileOperation.action))
        for operations in groups {
            for item in WheelGeometry(count: operations.count).items {
                let operation = operations[item.index]
                let font = NSFont.systemFont(ofSize: item.labelSize * 0.82, weight: .medium)
                for word in operation.wheelTitle.split(whereSeparator: { $0.isWhitespace }) {
                    let size = (String(word) as NSString).size(withAttributes: [.font: font])
                    XCTAssertLessThanOrEqual(size.width, item.labelWidth, "\(operation.title): \(word) at \(item.index) of \(operations.count)")
                }
            }
        }
    }
}
