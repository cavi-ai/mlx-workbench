import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum AdoptFixtures {
    static let totalBytes: Int64 = 137_438_953_472
    static let hardware = HardwareProfile(chip: "Apple M4 Max", model: nil, memoryBytes: totalBytes, macOSVersion: nil)
    static let repo = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
    static let cachePath = "/render/.cache/huggingface/hub/models--mlx-community--Qwen3-Coder-30B-A3B-Instruct-4bit/snapshots/abc123"

    static func model(_ path: String, task: ModelTask? = nil, readiness: ModelReadiness = .ready) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 17_200_000_000,
            modifiedAt: nil, shard: nil,
            modelKey: "model", architecture: nil, quantization: "4bit", parameters: nil,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil, task: task
        )
        return LibraryModel(item: item, readiness: readiness)
    }

    static func snapshot(_ models: [LibraryModel]) -> LibrarySnapshot {
        LibrarySnapshot(models: models, groups: [], hardware: hardware, generatedAt: Date(timeIntervalSinceReferenceDate: 1_000_000_000))
    }

    static func response(model: String? = repo, status: String? = "complete", phase: String? = "recommended",
                         evidence: String? = "strong", message: String? = nil) -> AdoptResult {
        AdoptResult(
            state: "state.json", role: "coding", model: model, status: status, message: message, manager: nil,
            workflowID: nil, phase: phase, evidenceStrength: evidence
        )
    }
}

// MARK: - Presentation

final class AdoptPresentationTests: XCTestCase {
    private typealias F = AdoptFixtures

    func testAdoptStartAcceptsTheDiscoveryRoles() throws {
        let cli = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/mlx-agent/providers/codex/src/mlx_agent/cli.py")
        let source = try String(contentsOf: cli, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: #"start = actions.add_parser\("start""#, options: .regularExpression))
        let role = try XCTUnwrap(source[start.upperBound...].prefix(400).range(of: #"start.add_argument\("--role"[^\n]*choices=DISCOVERY_ROLES"#, options: .regularExpression))
        XCTAssertFalse(role.isEmpty)
    }

    func testIdleSentenceNamesTheDraftRole() {
        XCTAssertEqual(AdoptRecommendationState.idleSentence(role: "general"), "Verify and recommend to find a General model for this Mac.")
        XCTAssertEqual(AdoptRecommendationState.idleSentence(role: "tool-use"), "Verify and recommend to find a Tool use model for this Mac.")
    }

    func testLibraryMatchIsSharedWithDiscover() {
        let owned = F.model(F.cachePath), local = F.model("/models/local")
        let snapshot = F.snapshot([local, owned])
        let index = DiscoverPresentation.libraryModels(in: snapshot)
        XCTAssertEqual(Set(index.keys), [F.repo])
        XCTAssertEqual(DiscoverPresentation.libraryRepos(in: snapshot), [F.repo])
        XCTAssertEqual(DiscoverPresentation.libraryModel(for: F.repo, in: index)?.item.path, F.cachePath)
        XCTAssertNil(DiscoverPresentation.libraryModel(for: "other/repo", in: index))
        XCTAssertEqual(
            AdoptRecommendationState.make(response: F.response(), libraryModels: index, intakeIsBusy: false),
            AdoptRecommendationState.make(response: F.response(), library: snapshot, intakeIsBusy: false)
        )
    }

    func testRoleListExcludesAnyAndTitlesComeFromDiscover() {
        XCTAssertFalse(AdoptRole.choices.contains(""))
        XCTAssertTrue(AdoptRole.choices.contains(AdoptRole.initial))
        for role in AdoptRole.choices {
            XCTAssertEqual(AdoptRole.title(role), DiscoverRole.title(role))
        }
        XCTAssertEqual(AdoptRole.title("coding"), "Coding")
        XCTAssertEqual(AdoptRole.title("tool-use"), "Tool use")
    }

    func testOutcomeItemsAreVerbatimAndOmitAbsentFields() {
        XCTAssertEqual(AdoptOutcome.items(F.response()), [
            AdoptOutcomeItem(figure: "complete", label: "Status"),
            AdoptOutcomeItem(figure: "recommended", label: "Phase"),
            AdoptOutcomeItem(figure: "strong", label: "Evidence strength"),
        ])
        XCTAssertEqual(AdoptOutcome.items(F.response(status: "running", phase: nil, evidence: "")), [
            AdoptOutcomeItem(figure: "running", label: "Status"),
        ])
        XCTAssertEqual(AdoptOutcome.items(F.response(status: nil, phase: nil, evidence: nil)), [])
        XCTAssertEqual(AdoptOutcome.items(nil), [])
    }

    func testNoResponseIsIdle() {
        XCTAssertEqual(AdoptRecommendationState.make(response: nil, library: nil, intakeIsBusy: false), .idle)
    }

    func testResponseWithoutModelIsNoRecommendation() {
        for model in [nil, ""] as [String?] {
            XCTAssertEqual(
                AdoptRecommendationState.make(response: F.response(model: model), library: nil, intakeIsBusy: false),
                .noRecommendation
            )
        }
    }

    func testReadyServableLibraryModelOffersRun() {
        let model = F.model(F.cachePath)
        let state = AdoptRecommendationState.make(response: F.response(), library: F.snapshot([model]), intakeIsBusy: false)
        XCTAssertEqual(state, .recommended(repo: F.repo, step: .inLibrary(model: model, canRun: true)))
    }

    func testUnsupportedLibraryModelOffersNoRun() {
        let task = ModelTask(type: .other, useCases: [], source: "registry", confidence: "confirmed")
        let model = F.model(F.cachePath, task: task)
        let state = AdoptRecommendationState.make(response: F.response(), library: F.snapshot([model]), intakeIsBusy: false)
        XCTAssertEqual(state, .recommended(repo: F.repo, step: .inLibrary(model: model, canRun: false)))
    }

    func testModelThatIsNotReadyOffersNoRun() {
        let model = F.model(F.cachePath, readiness: .needsConversion)
        let state = AdoptRecommendationState.make(response: F.response(), library: F.snapshot([model]), intakeIsBusy: false)
        XCTAssertEqual(state, .recommended(repo: F.repo, step: .inLibrary(model: model, canRun: false)))
    }

    func testRepoMissingFromLibraryOffersAddFromHuggingFace() {
        let other = F.model("/render/.cache/huggingface/hub/models--mlx-community--Other-4bit/snapshots/abc")
        for library in [nil, F.snapshot([other])] as [LibrarySnapshot?] {
            XCTAssertEqual(
                AdoptRecommendationState.make(response: F.response(), library: library, intakeIsBusy: false),
                .recommended(repo: F.repo, step: .addFromHuggingFace(
                    enabled: true, help: DiscoverIntakeAction.readyHelp
                ))
            )
        }
    }

    func testBusyIntakeDisablesAdd() {
        XCTAssertEqual(
            AdoptRecommendationState.make(response: F.response(), library: nil, intakeIsBusy: true),
            .recommended(repo: F.repo, step: .addFromHuggingFace(enabled: false, help: DiscoverIntakeAction.busyHelp))
        )
    }
}
