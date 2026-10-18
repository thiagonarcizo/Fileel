import XCTest
@testable import FileelCore

// cover the gesture's key transitions without synthesizing events on the user's mac
final class DragActivationTests: XCTestCase {
    func testModifierCanBeHeldBeforeDragging() {
        XCTAssertEqual(DragActivation.mode(current: ["shift"], previous: ["shift"], hasMenu: false, mappings: [:]), .convert)
        XCTAssertEqual(DragActivation.mode(current: ["command"], previous: ["command"], hasMenu: false, mappings: [:]), .tools)
        XCTAssertEqual(DragActivation.mode(current: ["control"], previous: ["control"], hasMenu: false, mappings: [:]), .actions)
    }

    func testReleasingModifierKeepsTheExistingMenu() {
        XCTAssertNil(DragActivation.mode(current: [], previous: ["shift"], hasMenu: true, mappings: [:]))
        XCTAssertNil(DragActivation.mode(current: ["shift"], previous: ["shift"], hasMenu: true, mappings: [:]))
    }

    func testNewModifierSwitchesTheOpenMenu() {
        XCTAssertEqual(DragActivation.mode(current: ["shift", "control"], previous: ["shift"], hasMenu: true, mappings: [:]), .actions)
        XCTAssertEqual(DragActivation.mode(current: ["command"], previous: [], hasMenu: true, mappings: [:]), .tools)
    }

    func testCustomizedModifiersAreRespected() {
        let mappings: [MenuMode: String] = [.convert: "option", .tools: "shift", .actions: "command"]
        XCTAssertEqual(DragActivation.mode(current: ["option"], previous: [], hasMenu: false, mappings: mappings), .convert)
        XCTAssertEqual(DragActivation.mode(current: ["shift"], previous: [], hasMenu: false, mappings: mappings), .tools)
        XCTAssertNil(DragActivation.mode(current: ["control"], previous: [], hasMenu: false, mappings: mappings))
    }
}
