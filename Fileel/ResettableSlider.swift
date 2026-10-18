import AppKit
import SwiftUI

// keep native slider tracking while making a double-click restore the option's own default
struct ResettableSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var step = 0.0

    var body: some View {
        ResettableSliderControl(title: title, value: $value, range: range, defaultValue: defaultValue, step: step)
            .frame(height: 20)
            .help("Double-click to reset to default")
            .contextMenu { Button("Reset to Default") { value = defaultValue } }
            .accessibilityAction(named: Text("Reset to Default")) { value = defaultValue }
    }
}

private struct ResettableSliderControl: NSViewRepresentable {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let step: Double

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> DoubleClickSlider {
        let slider = DoubleClickSlider()
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.onReset = { context.coordinator.reset() }
        return slider
    }

    func updateNSView(_ slider: DoubleClickSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.setAccessibilityLabel(title)
        slider.setAccessibilityHelp("Double-click to reset to default")
    }

    final class Coordinator: NSObject {
        var parent: ResettableSliderControl
        init(_ parent: ResettableSliderControl) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            let value = parent.step > 0 ? (slider.doubleValue / parent.step).rounded() * parent.step : slider.doubleValue
            parent.value = min(parent.range.upperBound, max(parent.range.lowerBound, value))
        }
        func reset() { parent.value = parent.defaultValue }
    }
}

private final class DoubleClickSlider: NSSlider {
    var onReset: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?() }
        else { super.mouseDown(with: event) }
    }
}
