import XCTest
@testable import mlx_workbench

final class ServingRolesPresentationTests: XCTestCase {
    private func model(_ path: String, task: ModelTaskType) -> LibraryModel {
        LibraryModel(item: ModelItem(path: path, name: path, bytes: 1_000, modifiedAt: nil, shard: nil, modelKey: path,
            architecture: nil, quantization: "Q4", parameters: "1B", structure: nil, signature: "s",
            companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil,
            task: ModelTask(type: task, useCases: [], source: "test", confidence: "test")), readiness: .ready, capabilities: nil)
    }

    private let slots = [EndpointSlot(enabled: true, port: 8766, modelPath: "/models/coder", role: .coding),
                         EndpointSlot(enabled: true, port: 9100, modelPath: "/models/custom")]

    private var rows: [ServingRow] {
        let servers = (0..<21).map { ServerInfo(path: "/other/\($0)", port: 9200 + $0, pid: 100 + $0, state: "running") }
        return ServingRows.build(slots: slots, servers: servers, snapshot: .empty)
    }

    func testRoleRowsCustomRowsAndCollapsedOthers() {
        let roleRows = ServingRolesPresentation.roleRows(slots: slots, rows: rows)
        XCTAssertEqual(roleRows.count, 12)
        XCTAssertEqual(roleRows.map(\.role), ServingRole.allCases)
        let coding = roleRows.first { $0.role == .coding }
        XCTAssertEqual(coding?.portText, ":8766")
        XCTAssertEqual(coding?.isAssigned, true)
        XCTAssertNotNil(coding?.row)
        let classifier = roleRows.first { $0.role == .classification }
        XCTAssertEqual(classifier?.unassignedText, "Not assigned - :8096")
        XCTAssertEqual(classifier?.isAssigned, false)
        XCTAssertEqual(ServingRolesPresentation.customRows(rows).count, 1)
        let others = ServingRolesPresentation.otherRows(rows)
        XCTAssertEqual(others.count, 21)
        XCTAssertEqual(ServingRolesPresentation.othersTitle(count: others.count), "Other servers on this Mac (21)")
    }

    func testSecondSlotOfARoleListsUnderCustomEndpoints() {
        let fleet = [EndpointSlot(enabled: true, port: 8766, modelPath: "/models/a", role: .coding),
                     EndpointSlot(enabled: true, port: 9101, modelPath: "/models/b", role: .coding)]
        let rows = ServingRows.build(slots: fleet, servers: [], snapshot: .empty)
        let roleRows = ServingRolesPresentation.roleRows(slots: fleet, rows: rows)
        XCTAssertEqual(roleRows.filter(\.isAssigned).map(\.port), [8766])
        let custom = ServingRolesPresentation.customRows(rows)
        XCTAssertEqual(custom.count, 1)
        XCTAssertEqual(custom.first.flatMap(ServingRolesPresentation.roleLabel), "Coding")
        guard case .endpoint(let slot, _, _) = custom[0] else { return XCTFail("Expected an endpoint row") }
        XCTAssertEqual(slot.port, 9101)
    }

    private func workbenchAPIRow(running: Bool = true, settings: FrontDoorSettings? = FrontDoorSettings(port: ServingRole.workbenchAPIDefaultPort, apiKeySHA256: "door")) -> ServingRolesPresentation.WorkbenchAPIRow {
        var shared = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/coder", role: .coding)
        shared.apiKeySHA256 = "door"
        var shared2 = EndpointSlot(enabled: true, port: 9100, modelPath: "/models/custom")
        shared2.apiKeySHA256 = "door"
        var own = EndpointSlot(enabled: true, port: 8091, modelPath: "/models/embed", role: .embedding)
        own.apiKeySHA256 = "own"
        let open = EndpointSlot(enabled: true, port: 8096, modelPath: "/models/clf", role: .classification)
        return ServingRolesPresentation.workbenchAPIRow(settings: settings, isRunning: running, slots: [shared, shared2, own, open])
    }

    func testRoutedCountExcludesSlotWithItsOwnDigest() {
        let row = workbenchAPIRow()
        XCTAssertEqual(row.routedCount, 2)
        XCTAssertEqual(row.address, "http://127.0.0.1:\(ServingRole.workbenchAPIDefaultPort)/v1")
        XCTAssertEqual(workbenchAPIRow(settings: nil).address, "http://127.0.0.1:8090/v1")
        XCTAssertEqual(row.stateText, "Running")
        XCTAssertEqual(workbenchAPIRow(settings: nil).routedCount, 0)
    }

    func testWorkbenchAPIDefaultPortDiffersFromEveryRolePort() {
        XCTAssertFalse(ServingRole.allCases.map(\.defaultPort).contains(ServingRole.workbenchAPIDefaultPort))
    }

    @MainActor
    func testRenderedWorkbenchAPIRowAndSettingsEditorNeverSayFrontDoor() async throws {
        let app = try await ServingWorld.host()
        let row = try await ServingWorld.renderedLines(
            WorkbenchAPIRowView(appHost: app, coordinator: app.frontDoor, endpoint: app.endpoint)
                .padding(16), size: CGSize(width: 900, height: 260))
        let editor = try await ServingWorld.renderedLines(
            FrontDoorEditor(coordinator: app.frontDoor, endpoint: app.endpoint).padding(16),
            size: CGSize(width: 900, height: 260))
        XCTAssertTrue(row.contains { $0.localizedCaseInsensitiveContains("workbench api") }, "\(row)")
        XCTAssertFalse(editor.isEmpty)
        for line in row + editor { XCTAssertFalse(line.localizedCaseInsensitiveContains("front door"), line) }
    }

    func testClassifierCandidatesExcludeTextModels() {
        let models = [model("/m/llm", task: .textLLM), model("/m/clf", task: .classification), model("/m/vlm", task: .visionLanguage)]
        let classifier = ServingRolesPresentation.candidates(for: .classification, models: models, slots: [])
        XCTAssertEqual(classifier.map(\.item.path), ["/m/clf"])
        let coding = ServingRolesPresentation.candidates(for: .coding, models: models, slots: [])
        XCTAssertEqual(Set(coding.map(\.item.path)), ["/m/llm", "/m/vlm"])
    }
}
