import Foundation

// balance the ring capacities by circumference instead of squeezing most tools into the hub
struct WheelGeometry {
    static let canvasSize = 488.0
    static let hubRadius = 60.0
    static let angularInset = 1.4
    struct Item {
        let index: Int
        let angle: Double
        let sweep: Double
        let inner: Double
        let outer: Double
        var radius: Double { (inner + outer) / 2 }
        var labelHeight: Double { outer < 140 ? 44 : 48 }
        var labelWidth: Double {
            // fit all four label corners inside the annular sector, including side-facing slices
            let maximum = outer < 140 ? 74.0 : 106.0
            var low = 0.0, high = maximum
            for _ in 0..<14 {
                let width = (low + high) / 2
                let fits = [-1.0, 1.0].allSatisfy { x in
                    [-1.0, 1.0].allSatisfy { y in
                        let px = radius * cos(angle * .pi / 180) + x * width / 2
                        let py = radius * sin(angle * .pi / 180) + y * labelHeight / 2
                        let r = hypot(px, py)
                        let delta = abs((atan2(py, px) * 180 / .pi - angle + 540).truncatingRemainder(dividingBy: 360) - 180)
                        return r >= inner + 6 && r <= outer - 6 && delta <= sweep / 2 - WheelGeometry.angularInset - 2
                    }
                }
                if fits { low = width } else { high = width }
            }
            return max(24, low)
        }
        var iconSize: Double { outer - inner > 90 ? 24 : outer < 140 ? 18 : 20 }
        var labelSize: Double { outer < 140 ? 10 : 11 }
    }
    let items: [Item]

    init(count: Int) {
        guard count > 0 else { items = []; return }
        if count <= 8 {
            items = (0..<count).map { Item(index: $0, angle: 90 - Double($0) * 360 / Double(count), sweep: 360 / Double(count), inner: 72, outer: 178) }
        } else {
            let outerCount = Int(ceil(Double(count) * 0.6))
            let innerCount = count - outerCount
            items = (0..<count).map { index in
                let isOuter = index < outerCount
                let ringIndex = isOuter ? index : index - outerCount
                let ringCount = isOuter ? outerCount : innerCount
                return Item(index: index, angle: 90 - Double(ringIndex) * 360 / Double(ringCount),
                            sweep: 360 / Double(ringCount), inner: isOuter ? 146 : 70, outer: isOuter ? 224 : 138)
            }
        }
    }

    static func isHub(_ point: CGPoint, center: CGPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= hubRadius
    }

    func index(at point: CGPoint, center: CGPoint) -> Int? {
        let dx = point.x - center.x, dy = point.y - center.y
        let radius = hypot(dx, dy)
        let angle = atan2(dy, dx) * 180 / .pi
        return items.first { item in
            let delta = abs((angle - item.angle + 540).truncatingRemainder(dividingBy: 360) - 180)
            return radius >= item.inner && radius <= item.outer && delta < item.sweep / 2 - Self.angularInset
        }?.index
    }
}
