import Foundation

// timeline math stays independent from the player and the input device
enum TimelineGeometry {
    static func time(at position: Double, width: Double, duration: Double) -> Double {
        guard position.isFinite, width.isFinite, width > 0, duration.isFinite, duration > 0 else { return 0 }
        return min(duration, max(0, position / width * duration))
    }

    static func position(at time: Double, width: Double, duration: Double) -> Double {
        guard time.isFinite, width.isFinite, width > 0, duration.isFinite, duration > 0 else { return 0 }
        return min(width, max(0, time / duration * width))
    }

    static func label(_ time: Double) -> String {
        guard time.isFinite, time < Double(Int.max) / 100 else { return "0:00.00" }
        let centiseconds = max(0, Int((time * 100).rounded()))
        let hours = centiseconds / 360_000
        let minutes = centiseconds / 6_000 % 60
        let seconds = centiseconds / 100 % 60
        let fraction = centiseconds % 100
        return hours > 0 ? String(format: "%d:%02d:%02d.%02d", hours, minutes, seconds, fraction) : String(format: "%d:%02d.%02d", minutes, seconds, fraction)
    }
}
