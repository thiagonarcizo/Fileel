import CoreGraphics
import XCTest
@testable import FileelCore

// exercise resize anchors and bounds independently from the pointer event implementation
final class CropGeometryTests: XCTestCase {
    func testLockedCornersAndEdgesKeepAspectInsideSource() {
        let size = CGSize(width: 4000, height: 3000)
        let original = CropGeometry.fitted(ratio: 16.0 / 9, size: size)
        for handle in CropGeometry.Handle.allCases where handle != .move {
            for delta in [CGSize(width: -6000, height: -5000), CGSize(width: 6000, height: 5000), CGSize(width: -240, height: 120)] {
                let rect = CropGeometry.change(original, handle: handle, delta: delta, size: size, ratio: 16.0 / 9)
                XCTAssertEqual(rect.width / rect.height, 16.0 / 9, accuracy: 0.00001)
                XCTAssertGreaterThan(rect.width, 0)
                XCTAssertGreaterThan(rect.height, 0)
                XCTAssertGreaterThanOrEqual(rect.minX, -0.00001)
                XCTAssertGreaterThanOrEqual(rect.minY, -0.00001)
                XCTAssertLessThanOrEqual(rect.maxX, size.width + 0.00001)
                XCTAssertLessThanOrEqual(rect.maxY, size.height + 0.00001)
            }
        }
    }

    func testFreeResizeKeepsOppositeCornerAndMoveKeepsSize() {
        let rect = CGRect(x: 100, y: 80, width: 600, height: 400)
        let size = CGSize(width: 1000, height: 800)
        let resized = CropGeometry.change(rect, handle: .topLeft, delta: CGSize(width: 60, height: 50), size: size, ratio: nil)
        XCTAssertEqual(resized, CGRect(x: 160, y: 130, width: 540, height: 350))
        let moved = CropGeometry.change(rect, handle: .move, delta: CGSize(width: 10000, height: -10000), size: size, ratio: nil)
        XCTAssertEqual(moved, CGRect(x: 400, y: 0, width: 600, height: 400))
    }

    func testPresetOrientationAndVideoPixelAlignment() {
        var options = OperationOptions()
        options.cropAspect = "16:9"; options.cropAspectLocked = true; options.cropPortrait = true
        let size = CGSize(width: 1920, height: 1080)
        let ratio = CropGeometry.ratio(options: options, size: size)!
        XCTAssertEqual(ratio, 9.0 / 16)
        CropGeometry.apply(CropGeometry.fitted(ratio: ratio, size: size), to: &options, alignment: 2)
        XCTAssertEqual(options.width % 2, 0)
        XCTAssertEqual(options.height % 2, 0)
        XCTAssertLessThanOrEqual(options.x + options.width, 1920)
        XCTAssertLessThanOrEqual(options.y + options.height, 1080)
        options.cropAspectLocked = false
        XCTAssertNil(CropGeometry.ratio(options: options, size: size))
    }
}
