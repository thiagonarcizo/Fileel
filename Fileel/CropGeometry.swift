import Foundation
import CoreGraphics

// keep crop handles in source pixels so the same gestures work for photos and video
enum CropGeometry {
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
        var horizontal: Int {
            switch self {
            case .topLeft, .bottomLeft, .left: return -1
            case .topRight, .bottomRight, .right: return 1
            default: return 0
            }
        }
        var vertical: Int {
            switch self {
            case .topLeft, .topRight, .top: return -1
            case .bottomLeft, .bottomRight, .bottom: return 1
            default: return 0
            }
        }
    }

    static func rectangle(options: OperationOptions, size: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        guard options.width > 0, options.height > 0 else { return full }
        let result = full.intersection(CGRect(x: options.x, y: options.y, width: options.width, height: options.height))
        return result.isNull || result.isEmpty ? full : result
    }

    static func ratio(options: OperationOptions, size: CGSize) -> Double? {
        guard options.cropAspectLocked, size.width > 0, size.height > 0 else { return nil }
        let value: Double
        if options.cropAspect == "original" { value = size.width / size.height }
        else if options.cropAspect == "free" { value = options.cropCustomRatio }
        else {
            let parts = options.cropAspect.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0 else { return nil }
            value = parts[0] / parts[1]
        }
        guard value.isFinite, value > 0 else { return nil }
        return options.cropPortrait ? 1 / value : value
    }

    static func fitted(ratio: Double, size: CGSize) -> CGRect {
        guard ratio.isFinite, ratio > 0, size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, size.height * ratio)
        let height = width / ratio
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func change(_ original: CGRect, handle: Handle, delta: CGSize, size: CGSize, ratio: Double?) -> CGRect {
        guard size.width > 0, size.height > 0, delta.width.isFinite, delta.height.isFinite else { return original }
        if handle == .move {
            return CGRect(x: min(size.width - original.width, max(0, original.minX + delta.width)),
                          y: min(size.height - original.height, max(0, original.minY + delta.height)),
                          width: original.width, height: original.height)
        }
        let sx = CGFloat(handle.horizontal), sy = CGFloat(handle.vertical)
        let minimum = min(16, size.width, size.height)
        let requestedWidth = max(minimum, original.width + sx * delta.width)
        let requestedHeight = max(minimum, original.height + sy * delta.height)
        if let ratio, ratio.isFinite, ratio > 0 {
            let anchorX = sx < 0 ? original.maxX : sx > 0 ? original.minX : original.midX
            let anchorY = sy < 0 ? original.maxY : sy > 0 ? original.minY : original.midY
            let maxWidth = sx < 0 ? anchorX : sx > 0 ? size.width - anchorX : 2 * min(anchorX, size.width - anchorX)
            let maxHeight = sy < 0 ? anchorY : sy > 0 ? size.height - anchorY : 2 * min(anchorY, size.height - anchorY)
            // project corner movement onto the locked diagonal instead of letting either axis drift
            let proposed = sx == 0 ? requestedHeight * ratio : sy == 0 ? requestedWidth :
                (requestedWidth + requestedHeight / ratio) / (1 + 1 / (ratio * ratio))
            let width = min(maxWidth, maxHeight * ratio, max(minimum, minimum * ratio, proposed))
            let height = width / ratio
            return CGRect(x: sx < 0 ? anchorX - width : sx > 0 ? anchorX : anchorX - width / 2,
                          y: sy < 0 ? anchorY - height : sy > 0 ? anchorY : anchorY - height / 2,
                          width: width, height: height)
        }
        let left = sx < 0 ? min(original.maxX - minimum, max(0, original.minX + delta.width)) : original.minX
        let top = sy < 0 ? min(original.maxY - minimum, max(0, original.minY + delta.height)) : original.minY
        let right = sx > 0 ? max(original.minX + minimum, min(size.width, original.maxX + delta.width)) : original.maxX
        let bottom = sy > 0 ? max(original.minY + minimum, min(size.height, original.maxY + delta.height)) : original.maxY
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func apply(_ rect: CGRect, to options: inout OperationOptions, alignment: Int = 1) {
        let unit = max(1, alignment)
        options.x = max(0, Int(rect.minX.rounded()))
        options.y = max(0, Int(rect.minY.rounded()))
        options.width = max(unit, Int(rect.width.rounded(.down)) / unit * unit)
        options.height = max(unit, Int(rect.height.rounded(.down)) / unit * unit)
    }
}
