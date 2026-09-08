import Foundation
import XCTest

@testable import mlx_workbench

/// HomeNextAction.derive is the app's central guidance ladder: exactly one
/// next safe action from workflow state, library evidence, runtime readiness,
/// and disk pressure. Pure derivation — tested directly.
final class HomeNextActionTests: XCTestCase {
    private let stamp = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    // MARK: - Workflow states short-circuit to Activity

    func testActiveConversionStatesRouteToActivity() {
        for state in [ConversionWorkflowState.queued, .running, .verifying, .verificationFailed, .failed] {
            let action = derive(workflow: workflow(state: state))
            XCTAssertEqual(action.kind, .activity, state.rawValue)
            XCTAssertEqual(action.route, AppRoute.activity.rawValue)
        }
    }

    func testFailedWorkflowSurfacesTheErrorAsReason() {
        let action = derive(workflow: workflow(state: .failed, errorMessage: "converter exited 9"))
        XCTAssertEqual(action.reason, "converter exited 9")
    }

    // MARK: - Completed output

    func testCompletedReadyOutputOffersRun() {
        let model = makeModel(path: "/models/atlas-mlx", readiness: .ready)
        let action = derive(
            workflow: workflow(state: .completed, completedModelPath: model.item.path),
            snapshot: snapshot(with: [model])
        )
        XCTAssertEqual(action.kind, .run(model.item.path))
        XCTAssertEqual(action.route, AppRoute.run.rawValue)
    }

    func testCompletedOutputMissingFromSnapshotReconciles() {
        let action = derive(
            workflow: workflow(state: .completed, completedModelPath: "/models/gone"),
            snapshot: snapshot(with: [])
        )
        XCTAssertEqual(action.kind, .activity)
        XCTAssertEqual(action.title, "Reconcile completed output")
    }

    func testCompletedReadyOutputWithoutServeRuntimeRepairsFirst() {
        let model = makeModel(path: "/models/atlas-mlx", readiness: .ready)
        let action = derive(
            workflow: workflow(state: .completed, completedModelPath: model.item.path),
            snapshot: snapshot(with: [model]),
            serveRuntimeReady: false
        )
        XCTAssertEqual(action.kind, .configure)
        XCTAssertEqual(action.route, AppRoute.settings.rawValue)
    }

    // MARK: - Configuration ladder

    func testNoRootsConfiguredComesBeforeAgentCheck() {
        let action = derive(rootsConfigured: false, agentReady: false)
        XCTAssertEqual(action.kind, .configure)
        XCTAssertEqual(action.title, "Configure model roots")
    }

    func testUnusableAgentBlocksScanning() {
        let action = derive(agentReady: false)
        XCTAssertEqual(action.kind, .configure)
        XCTAssertEqual(action.title, "Configure mlx-agent")
    }

    func testScanErrorRoutesToLibrary() {
        let action = derive(lastError: "scan contract failed")
        XCTAssertEqual(action.kind, .scan)
        XCTAssertEqual(action.reason, "scan contract failed")
        XCTAssertEqual(action.route, AppRoute.library.rawValue)
    }

    func testMissingSnapshotOffersScan() {
        let action = derive()
        XCTAssertEqual(action.kind, .scan)
        XCTAssertEqual(action.title, "Scan the model library")
    }

    // MARK: - Prepare ladder

    func testGGUFSourceOffersPrepareWhenConvertRuntimeIsReady() {
        let source = makeModel(path: "/models/source.gguf", readiness: .needsConversion)
        let action = derive(snapshot: snapshot(with: [source]))
        XCTAssertEqual(action.kind, .prepare(source.item.path))
        XCTAssertEqual(action.route, AppRoute.prepare.rawValue)
    }

    func testGGUFSourceWithoutConvertRuntimeRepairsFirst() {
        let source = makeModel(path: "/models/source.gguf", readiness: .needsConversion)
        let action = derive(snapshot: snapshot(with: [source]), convertRuntimeReady: false)
        XCTAssertEqual(action.kind, .configure)
        XCTAssertEqual(action.title, "Repair the Prepare runtime")
    }

    // MARK: - Disk pressure escalation

    func testReclaimOnlyEscalatesAboveThresholdAndBelowFreeFloor() {
        let ready = makeModel(path: "/models/ready", readiness: .ready)
        let snap = snapshot(with: [ready])

        let belowThreshold = derive(
            snapshot: snap,
            reclaimableBytes: ReclaimAdvisor.badgeThresholdBytes - 1,
            diskFreeFraction: 0.05
        )
        XCTAssertEqual(belowThreshold.kind, .library)
        XCTAssertEqual(belowThreshold.title, "Review the model library")

        let roomyDisk = derive(
            snapshot: snap,
            reclaimableBytes: ReclaimAdvisor.badgeThresholdBytes,
            diskFreeFraction: 0.50
        )
        XCTAssertEqual(roomyDisk.title, "Review the model library")

        let pressured = derive(
            snapshot: snap,
            reclaimableBytes: ReclaimAdvisor.badgeThresholdBytes,
            diskFreeFraction: 0.10
        )
        XCTAssertEqual(pressured.kind, .library)
        XCTAssertTrue(pressured.title.hasPrefix("Reclaim "))
        XCTAssertEqual(pressured.route, AppRoute.reclaim.rawValue)
    }

    // MARK: - Default

    func testDefaultReviewsTheLibrary() {
        let action = derive(snapshot: snapshot(with: []))
        XCTAssertEqual(action.kind, .library)
        XCTAssertEqual(action.route, AppRoute.library.rawValue)
    }

    // MARK: - Helpers

    private func derive(
        workflow: ConversionWorkflow? = nil,
        snapshot: LibrarySnapshot? = nil,
        rootsConfigured: Bool = true,
        isScanning: Bool = false,
        lastError: String? = nil,
        agentReady: Bool = true,
        convertRuntimeReady: Bool = true,
        serveRuntimeReady: Bool = true,
        reclaimableBytes: Int64 = 0,
        diskFreeFraction: Double? = nil
    ) -> HomeNextAction {
        HomeNextAction.derive(
            workflow: workflow ?? self.workflow(state: .idle),
            snapshot: snapshot,
            rootsConfigured: rootsConfigured,
            isScanning: isScanning,
            lastError: lastError,
            agentReady: agentReady,
            convertRuntimeReady: convertRuntimeReady,
            serveRuntimeReady: serveRuntimeReady,
            reclaimableBytes: reclaimableBytes,
            diskFreeFraction: diskFreeFraction
        )
    }

    private func workflow(
        state: ConversionWorkflowState,
        completedModelPath: String? = nil,
        errorMessage: String? = nil
    ) -> ConversionWorkflow {
        ConversionWorkflow(
            id: UUID(),
            sourcePath: "/models/source.gguf",
            sourceModelKey: nil,
            sourceSignature: nil,
            outputPath: "/models/out",
            previewHash: nil,
            jobReceipt: nil,
            completedModelPath: completedModelPath,
            state: state,
            serveState: .idle,
            message: nil,
            errorMessage: errorMessage,
            createdAt: stamp,
            updatedAt: stamp,
            lastKnownAgentState: nil
        )
    }

    private func makeModel(path: String, readiness: ModelReadiness) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 1000,
            modifiedAt: nil, shard: nil,
            modelKey: "model", architecture: nil, quantization: "Q4_K_M", parameters: nil,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: readiness == .ready ? "ready" : "needs_conversion",
            outputs: [], tensorCount: nil, error: nil
        )
        return LibraryModel(item: item, readiness: readiness)
    }

    private func snapshot(with models: [LibraryModel]) -> LibrarySnapshot {
        LibrarySnapshot(
            models: models,
            groups: [],
            hardware: HardwareProfile.current(),
            generatedAt: stamp
        )
    }
}
