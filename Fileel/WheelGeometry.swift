import Foundation

// balance the ring capacities by circumference instead of squeezing most tools into the hub
struct WheelGeometry {
    static let canvasSize = 488.0
    static let hubRadius = 60.0
    static let angularInset = 1.4
    enum Ring: String { case inner, outer }
    struct Item {
        let index: Int
        let angle: Double
        let sweep: Double
        let inner: Double
        let outer: Double
        let ring: Ring
        init(index: Int, angle: Double, sweep: Double, inner: Double, outer: Double, ring: Ring? = nil) {
            self.index = index
            self.angle = angle
            self.sweep = sweep
            self.inner = inner
            self.outer = outer
            self.ring = ring ?? (outer < 140 ? .inner : .outer)
        }
        // identify a place in a ring, not whichever operation currently occupies it
        var slotID: String { "\(ring.rawValue)-\(Int(((90 - angle) / sweep).rounded()))" }
        var cornerRadius: Double { min(5, max(0, (outer - inner) / 2)) }
        var radius: Double { (inner + outer) / 2 }
        var labelHeight: Double { ring == .inner ? 44 : 48 }
        var labelWidth: Double {
            // fit all four label corners inside the annular sector, including side-facing slices
            let maximum = ring == .inner ? 74.0 : 106.0
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
        var iconSize: Double { ring == .inner ? 18 : 20 + 4 * min(1, max(0, (outer - inner - 78) / 28)) }
        var labelSize: Double { ring == .inner ? 10 : 11 }
    }
    let items: [Item]

    struct MorphSlot: Identifiable {
        let id: String
        let item: Item
        let operationIndex: Int?
    }

    // keep both rings mounted so new slices grow into their own ring instead of scaling through the hub
    static func morphSlots(count: Int, capacity: Int) -> [MorphSlot] {
        let active = WheelGeometry(count: count).items
        let largest = max(capacity, count)
        let outerCapacity = max(8, largest > 8 ? Int(ceil(Double(largest) * 0.6)) : largest)
        let innerCapacity = largest > 8 ? largest - Int(ceil(Double(largest) * 0.6)) : 0
        let places = [(.outer, outerCapacity), (.inner, innerCapacity)].flatMap { (ring: Ring, size: Int) in
            (0..<size).map { index in
                Item(index: index, angle: 90 - Double(index) * 360 / Double(size), sweep: 360 / Double(size),
                     inner: ring == .inner ? 70 : 146, outer: ring == .inner ? 138 : 224, ring: ring)
            }
        }
        return places.map { place in
            if let item = active.first(where: { $0.slotID == place.slotID }) {
                return MorphSlot(id: place.slotID, item: item, operationIndex: item.index)
            }
            let radius = place.ring == .inner ? 70.0 : count > 8 ? 146.0 : 72.0
            let collapsed = Item(index: place.index, angle: place.angle, sweep: place.sweep, inner: radius, outer: radius, ring: place.ring)
            return MorphSlot(id: place.slotID, item: collapsed, operationIndex: nil)
        }
    }

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
