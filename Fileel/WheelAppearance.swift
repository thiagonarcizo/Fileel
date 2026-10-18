import AppKit
import Combine
import SwiftUI

// appkit owns the drag session while swiftui renders the native glass surfaces
@MainActor
final class WheelPresentation: ObservableObject {
    @Published var operations: [FileOperation] = []
    @Published var mode: MenuMode = .convert
    @Published var filename = ""
    @Published var highlighted: Int?
    @Published var expanded = false
    @Published var showHubLabels = true
}

struct WheelAppearance: View {
    @ObservedObject var state: WheelPresentation
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let slotCapacity = max(FileAction.radialOrder.count, FileFamily.allCases.map { max($0.outputs.count, $0.tools.count) }.max() ?? 0)

    var body: some View {
        Group {
            if #available(macOS 26, *), !reduceTransparency {
                GlassEffectContainer(spacing: 2) { surfaces }
            } else { surfaces }
        }
        .frame(width: WheelGeometry.canvasSize, height: WheelGeometry.canvasSize)
        .scaleEffect(reduceMotion || state.expanded ? 1 : 0.12, anchor: .center)
        .opacity(state.expanded ? 1 : 0)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: reduceMotion ? 0.08 : 0.16), value: state.expanded)
        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: state.mode)
        .accessibilityHidden(true)
    }

    private var surfaces: some View {
        ZStack {
            ForEach(WheelGeometry.morphSlots(count: state.operations.count, capacity: Self.slotCapacity)) { slot in
                WheelSlice(item: slot.item, operation: slot.operationIndex.map { state.operations[$0] }, selected: slot.operationIndex != nil && state.highlighted == slot.operationIndex,
                           reduceTransparency: reduceTransparency, namespace: glassNamespace,
                           captionWidth: slot.item.labelWidth, captionHeight: slot.item.labelHeight)
                    .opacity(slot.operationIndex == nil ? 0 : 1)
            }
            VStack(spacing: 5) {
                Text(state.mode.rawValue).font(.system(size: 12, weight: .semibold)).id(state.mode).transition(.opacity)
                Text(selectedTitle ?? state.filename).font(.system(size: 10)).multilineTextAlignment(.center).lineLimit(2)
                if selectedTitle == nil {
                    Text(state.operations.isEmpty ? "No tools" : "Cancel").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .opacity(state.showHubLabels ? 1 : 0)
            .padding(10).frame(width: WheelGeometry.hubRadius * 2, height: WheelGeometry.hubRadius * 2)
            .modifier(WheelMaterial(shape: Circle(), selected: false, reduceTransparency: reduceTransparency,
                                    glassID: "hub", namespace: glassNamespace))
        }.frame(width: WheelGeometry.canvasSize, height: WheelGeometry.canvasSize)
    }

    private var selectedTitle: String? {
        guard let index = state.highlighted, state.operations.indices.contains(index) else { return nil }
        return state.operations[index].title.replacingOccurrences(of: "…", with: "")
    }
}

// each glass effect is bounded to its own slice and contains its own foreground content
// full-canvas glass layers can occlude neighboring labels even when their paths are disjoint
private struct WheelSlice: View, Animatable {
    var item: WheelGeometry.Item
    let operation: FileOperation?
    let selected: Bool
    let reduceTransparency: Bool
    let namespace: Namespace.ID
    let captionWidth: Double
    let captionHeight: Double

    // interpolate the actual polar shape so changing ring counts never snaps the slice outline
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(item.angle, item.sweep), AnimatablePair(item.inner, item.outer)) }
        set {
            item = WheelGeometry.Item(index: item.index, angle: newValue.first.first, sweep: newValue.first.second,
                                      inner: newValue.second.first, outer: newValue.second.second, ring: item.ring)
        }
    }
    private var bounds: CGRect {
        let rect = WheelSector(item: item).path(in: CGRect(x: 0, y: 0, width: WheelGeometry.canvasSize, height: WheelGeometry.canvasSize)).boundingRect
        // an invisible collapsed slot still needs finite layout bounds for the next morph
        return rect.isNull || rect.isEmpty ? CGRect(x: WheelGeometry.canvasSize / 2, y: WheelGeometry.canvasSize / 2, width: 0.1, height: 0.1) : rect
    }
    var body: some View {
        let bounds = bounds
        let shape = WheelSector(item: item, origin: bounds.origin)
        ZStack {
            Color.clear
            if let operation { VStack(spacing: 4) {
                Image(systemName: operation.symbol).font(.system(size: item.iconSize, weight: .medium))
                Text(operation.wheelTitle).font(.system(size: item.labelSize, weight: .medium))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.82).allowsTightening(true)
            }
            .foregroundStyle(selected ? Color.accentColor : .primary)
            // use the destination's text box throughout the morph so words never reflow mid-flight
            .frame(width: captionWidth, height: captionHeight)
            .position(x: WheelGeometry.canvasSize / 2 + item.radius * cos(item.angle * .pi / 180) - bounds.minX,
                      y: WheelGeometry.canvasSize / 2 - item.radius * sin(item.angle * .pi / 180) - bounds.minY)
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        // fading captions stay inside their changing slice while a ring opens or closes
        .clipShape(shape)
        .modifier(WheelMaterial(shape: shape, selected: selected, reduceTransparency: reduceTransparency,
                                glassID: "slice-\(item.slotID)", namespace: namespace))
        .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06), .black.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
        .position(x: bounds.midX, y: bounds.midY)
        // these positions already come from the interpolated path, so a second layout animation would lag behind it
        .transaction { $0.animation = nil }
    }
}

// use real system glass on macOS 26 and preserve an opaque accessibility presentation
private struct WheelMaterial<S: Shape>: ViewModifier {
    let shape: S
    let selected: Bool
    let reduceTransparency: Bool
    let glassID: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(.regular.tint(selected ? .accentColor.opacity(0.26) : .clear).interactive(), in: shape)
                .glassEffectID(glassID, in: namespace)
                // the slice already animates its polar path and bounds, so glass must not morph them again
                .glassEffectTransition(.identity)
        } else {
            content.background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial), in: shape)
                .overlay(shape.strokeBorderFallback(selected ? Color.accentColor : Color(nsColor: .separatorColor)))
        }
    }
}

// rounded sector corners leave clean gaps between neighboring glass surfaces
private struct WheelSector: Shape {
    let item: WheelGeometry.Item
    var origin: CGPoint?
    func path(in rect: CGRect) -> Path {
        guard item.outer > item.inner, item.sweep > WheelGeometry.angularInset * 2 else { return Path() }
        let center = origin.map { CGPoint(x: WheelGeometry.canvasSize / 2 - $0.x, y: WheelGeometry.canvasSize / 2 - $0.y) } ?? CGPoint(x: rect.midX, y: rect.midY)
        let start = -item.angle - item.sweep / 2 + WheelGeometry.angularInset
        let end = -item.angle + item.sweep / 2 - WheelGeometry.angularInset
        let corner = item.cornerRadius
        let outerOffset = corner / item.outer * 180 / .pi
        let innerOffset = corner / item.inner * 180 / .pi
        func point(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle * .pi / 180), y: center.y + radius * sin(angle * .pi / 180))
        }
        var path = Path()
        path.move(to: point(item.outer, start + outerOffset))
        path.addArc(center: center, radius: item.outer, startAngle: .degrees(start + outerOffset), endAngle: .degrees(end - outerOffset), clockwise: false)
        path.addQuadCurve(to: point(item.outer - corner, end), control: point(item.outer, end))
        path.addLine(to: point(item.inner + corner, end))
        path.addQuadCurve(to: point(item.inner, end - innerOffset), control: point(item.inner, end))
        path.addArc(center: center, radius: item.inner, startAngle: .degrees(end - innerOffset), endAngle: .degrees(start + innerOffset), clockwise: true)
        path.addQuadCurve(to: point(item.inner + corner, start), control: point(item.inner, start))
        path.addLine(to: point(item.outer - corner, start))
        path.addQuadCurve(to: point(item.outer, start + outerOffset), control: point(item.outer, start))
        path.closeSubpath()
        return path
    }
}

// shape strokes stay available on the older material fallback without requiring insettable shapes
private extension Shape {
    func strokeBorderFallback(_ color: Color) -> some View { stroke(color, lineWidth: 1) }
}
