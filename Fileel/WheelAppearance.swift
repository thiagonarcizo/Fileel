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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: state.highlighted)
        .accessibilityHidden(true)
    }

    private var surfaces: some View {
        ZStack {
            ForEach(WheelGeometry(count: state.operations.count).items, id: \.index) { item in
                WheelSlice(item: item, operation: state.operations[item.index], selected: state.highlighted == item.index,
                           reduceTransparency: reduceTransparency)
            }
            VStack(spacing: 5) {
                Text(state.mode.rawValue).font(.system(size: 12, weight: .semibold))
                Text(selectedTitle ?? state.filename).font(.system(size: 10)).multilineTextAlignment(.center).lineLimit(2)
                if selectedTitle == nil {
                    Text(state.operations.isEmpty ? "No tools" : "Cancel").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .opacity(state.showHubLabels ? 1 : 0)
            .padding(10).frame(width: WheelGeometry.hubRadius * 2, height: WheelGeometry.hubRadius * 2)
            .modifier(WheelMaterial(shape: Circle(), selected: false, reduceTransparency: reduceTransparency))
        }.frame(width: WheelGeometry.canvasSize, height: WheelGeometry.canvasSize)
    }

    private var selectedTitle: String? {
        guard let index = state.highlighted, state.operations.indices.contains(index) else { return nil }
        return state.operations[index].title.replacingOccurrences(of: "…", with: "")
    }
}

// each glass effect is bounded to its own slice and contains its own foreground content
// full-canvas glass layers can occlude neighboring labels even when their paths are disjoint
private struct WheelSlice: View {
    let item: WheelGeometry.Item
    let operation: FileOperation
    let selected: Bool
    let reduceTransparency: Bool
    private var bounds: CGRect {
        WheelSector(item: item).path(in: CGRect(x: 0, y: 0, width: WheelGeometry.canvasSize, height: WheelGeometry.canvasSize)).boundingRect
    }
    var body: some View {
        let bounds = bounds
        let shape = WheelSector(item: item, origin: bounds.origin)
        ZStack {
            Color.clear
            VStack(spacing: 5) {
                Image(systemName: operation.symbol).font(.system(size: item.iconSize, weight: .medium))
                Text(operation.wheelTitle).font(.system(size: item.labelSize, weight: .medium))
                    .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .frame(width: item.labelWidth, height: 56)
            .position(x: WheelGeometry.canvasSize / 2 + item.radius * cos(item.angle * .pi / 180) - bounds.minX,
                      y: WheelGeometry.canvasSize / 2 - item.radius * sin(item.angle * .pi / 180) - bounds.minY)
        }
        .frame(width: bounds.width, height: bounds.height)
        .modifier(WheelMaterial(shape: shape, selected: selected, reduceTransparency: reduceTransparency))
        .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06), .black.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
        .position(x: bounds.midX, y: bounds.midY)
    }
}

// use real system glass on macOS 26 and preserve an opaque accessibility presentation
private struct WheelMaterial<S: Shape>: ViewModifier {
    let shape: S
    let selected: Bool
    let reduceTransparency: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(.regular.tint(selected ? .accentColor.opacity(0.26) : .clear).interactive(), in: shape)
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
        let center = origin.map { CGPoint(x: WheelGeometry.canvasSize / 2 - $0.x, y: WheelGeometry.canvasSize / 2 - $0.y) } ?? CGPoint(x: rect.midX, y: rect.midY)
        let start = -item.angle - item.sweep / 2 + WheelGeometry.angularInset
        let end = -item.angle + item.sweep / 2 - WheelGeometry.angularInset
        let corner = 5.0
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
