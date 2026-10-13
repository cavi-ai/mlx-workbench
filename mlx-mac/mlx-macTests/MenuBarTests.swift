import Foundation
import XCTest

@testable import mlx_workbench

final class MenuBarTests: XCTestCase {
    private func slot(_ path: String, port: Int = 8080, enabled: Bool = true) -> EndpointSlot {
        EndpointSlot(enabled: enabled, port: port, modelPath: path)
    }

    func testModelNameIsTheLastComponentOfANonexistentPath() {
        XCTAssertEqual(MenuBarPresentation.modelName("/nonexistent/models/Qwen3-8B-4bit"), "Qwen3-8B-4bit")
        XCTAssertEqual(MenuBarPresentation.modelName("/nonexistent/models/Qwen3-8B-4bit/"), "Qwen3-8B-4bit")
        XCTAssertEqual(MenuBarPresentation.modelName("org-model"), "org-model")
        XCTAssertEqual(MenuBarPresentation.modelName(""), "No model")
        XCTAssertEqual(MenuBarPresentation.slotTitle(slot("", port: 8080, enabled: false)), "Start No model · :8080")
    }

    func testFleetIconIgnoresDisabledSlotsLeftInAStaleState() {
        let off = slot("/m/a", port: 1, enabled: false)
        let on = slot("/m/b", port: 2)
        let states: [UUID: EndpointState] = [off.id: .degraded(reason: "x"), on.id: .running(modelPath: "/m/b", port: 2)]
        XCTAssertEqual(MenuBarPresentation.fleetIcon(slots: [off, on], states: states), "bolt.fill")
        XCTAssertEqual(MenuBarPresentation.fleetIcon(slots: [off], states: states), "bolt.slash")
        XCTAssertEqual(MenuBarPresentation.fleetIcon(slots: [on], states: [:]), "bolt.slash")
    }

    func testSlotTitleNamesTheActionTheItemPerforms() {
        XCTAssertEqual(MenuBarPresentation.slotTitle(slot("/nonexistent/qwen", port: 8081, enabled: true)), "Stop qwen · :8081")
        XCTAssertEqual(MenuBarPresentation.slotTitle(slot("/nonexistent/qwen", port: 8081, enabled: false)), "Start qwen · :8081")
    }

    func testFleetSummaryCountsRunningAmongEnabledSlots() {
        let running = slot("/m/a", port: 1)
        let starting = slot("/m/b", port: 2)
        let off = slot("/m/c", port: 3, enabled: false)
        let states: [UUID: EndpointState] = [
            running.id: .running(modelPath: "/m/a", port: 1),
            starting.id: .starting,
            off.id: .disabled,
        ]
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [running, starting, off], states: states), "1 of 2 endpoints running")
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [running], states: states), "1 of 1 endpoint running")
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [off], states: states), "No always-on endpoints")
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [], states: [:]), "No always-on endpoints")
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [slot("", port: 4)], states: [:]), "No always-on endpoints")
    }

    func testIconsFollowTheSlotState() {
        XCTAssertEqual(EndpointIcon.name(for: .running(modelPath: "/m", port: 1)), "bolt.fill")
        XCTAssertEqual(EndpointIcon.name(for: .disabled), "bolt.slash")
        XCTAssertEqual(EndpointIcon.name(forStates: [.disabled, .starting]), "bolt.horizontal")
        XCTAssertEqual(EndpointIcon.name(forStates: [.running(modelPath: "/m", port: 1), .degraded(reason: "x")]), "exclamationmark.triangle")
    }

    func testMenuBodyBuildsNoFileURLsAndKeepsQuitShortcut() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/MenuBarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("URL(fileURLWithPath:"))
        XCTAssertFalse(source.contains("HStack"))
        XCTAssertFalse(source.contains("(spec 09"))
        XCTAssertTrue(source.contains("Button(\"Open MLX Workbench\")"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"q\")"))
    }
}
