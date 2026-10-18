import Foundation
import CoreGraphics

// keep pointer mapping independent from appkit so crop coordinates can be verified directly
enum CanvasGeometry {
    static func imageRect(size: CGSize, in bounds: CGRect, inset: CGFloat = 24) -> CGRect {
        let available = bounds.insetBy(dx: inset, dy: inset)
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / size.width, available.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    static func normalized(_ point: CGPoint, imageRect: CGRect) -> CGPoint {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        return CGPoint(x: min(1, max(0, (point.x - imageRect.minX) / imageRect.width)),
                       y: min(1, max(0, (point.y - imageRect.minY) / imageRect.height)))
    }

    static func crop(from start: CGPoint, to end: CGPoint, imageSize: CGSize) -> CGRect {
        let x = floor(min(start.x, end.x) * imageSize.width)
        let y = floor(min(start.y, end.y) * imageSize.height)
        let right = min(imageSize.width, ceil(max(start.x, end.x) * imageSize.width))
        let bottom = min(imageSize.height, ceil(max(start.y, end.y) * imageSize.height))
        return CGRect(x: x, y: y, width: max(0, right - x), height: max(0, bottom - y))
    }
}
