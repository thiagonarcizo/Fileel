import Foundation

// accept a modifier held before the drag starts and keep the open menu latched after release
enum DragActivation {
    static func mode(current: Set<String>, previous: Set<String>, hasMenu: Bool, mappings: [MenuMode: String]) -> MenuMode? {
        let pressed = current.subtracting(previous)
        if let mode = MenuMode.allCases.first(where: { pressed.contains(mappings[$0] ?? $0.defaultKey) }) { return mode }
        if !hasMenu { return MenuMode.allCases.first { current.contains(mappings[$0] ?? $0.defaultKey) } }
        return nil
    }
}
