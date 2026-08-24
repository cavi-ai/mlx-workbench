import Foundation
import XCTest

@testable import mlx_workbench

final class RecommendationEngineTests: XCTestCase {
    func testMemoryFitHardGatesOversizedCurrentCatalogModel() {
        let supported = readyModel(
            path: "/mlx/fit",
            name: "Code Fit",
            modelKey: "org/code-fit",
            bytes: 2_000
        )
        let oversized = readyModel(
            path: "/mlx/oversized",
            name: "Code Oversized",
            modelKey: "org/code-oversized",
            bytes: 3_000
        )
        let snapshot = makeSnapshot(
            models: [supported, oversized],
            memoryBytes: 8_000
        )
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/code-fit", roles: [.coding], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/code-oversized", roles: [.coding], estimatedMemoryBytes: 16_000, updatedAt: fixtureNow)
                ]
            )
        )

        let result = RecommendationEngine.recommend(
            useCase: .coding,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertEqual(result.map(\.modelID), [supported.item.path])
    }

    func testMissingModelMemoryEvidenceDoesNotFallBackToReadyOutput() {
        let ready = readyModel(path: "/mlx/no-memory", name: "Code Local", modelKey: "org/code-local", bytes: 2_000)
        let snapshot = makeSnapshot(models: [ready], memoryBytes: 16_000)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/code-local", roles: [.coding], estimatedMemoryBytes: nil, updatedAt: fixtureNow)
                ]
            )
        )

        let result = RecommendationEngine.recommend(
            useCase: .coding,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testMissingHostMemoryEvidenceDoesNotFallBackToReadyOutput() {
        let ready = readyModel(path: "/mlx/no-host-memory", name: "Code Local", modelKey: "org/code-local", bytes: 2_000)
        let snapshot = makeSnapshot(models: [ready], memoryBytes: nil)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/code-local", roles: [.coding], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )

        let result = RecommendationEngine.recommend(
            useCase: .coding,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testReadinessExclusionDropsNonReadyLocalModels() {
        let ready = readyModel(path: "/mlx/ready", name: "Vision Ready", modelKey: "org/vision-ready", bytes: 2_000)
        let pending = model(path: "/downloads/pending.gguf", name: "Vision Pending", modelKey: "org/vision-pending", bytes: 1_500, readiness: .needsConversion)
        let runtimeMissing = model(path: "/mlx/runtime-missing", name: "Vision Runtime", modelKey: "org/vision-runtime", bytes: 1_500, readiness: .needsRuntime)
        let snapshot = makeSnapshot(models: [ready, pending, runtimeMissing], memoryBytes: 16_000)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/vision-ready", roles: [.vision], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/vision-pending", roles: [.vision], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/vision-runtime", roles: [.vision], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )

        let result = RecommendationEngine.recommend(
            useCase: .vision,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertEqual(result.map(\.modelID), [ready.item.path])
    }

    func testCapabilityFitPrefersStructuredMetadataForUseCase() {
        let coding = readyModel(path: "/mlx/coder", name: "Code Pro", modelKey: "org/code-pro", bytes: 3_000)
        let chat = readyModel(path: "/mlx/chat", name: "Chat Base", modelKey: "org/chat-base", bytes: 2_000)
        let snapshot = makeSnapshot(models: [coding, chat], memoryBytes: 16_000)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/code-pro", roles: [.coding], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/chat-base", roles: [.generalChat], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )

        let result = RecommendationEngine.recommend(
            useCase: .coding,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertEqual(result.map(\.modelID), [coding.item.path])
        XCTAssertEqual(result.first?.confidence, .medium)
    }

    func testCurrentNewerButUnsupportedCatalogEntryBlocksOlderSupportClaim() {
        let local = readyModel(path: "/mlx/reasoner", name: "Reasoner 2", modelKey: "org/reasoner", bytes: 3_000)
        let snapshot = makeSnapshot(models: [local], memoryBytes: 16_000)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/reasoner", roles: [.reasoning], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow.addingTimeInterval(-60)),
                    catalogRecord(repoIdentity: "org/reasoner", roles: [.generalChat], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )

        let result = RecommendationEngine.recommend(
            useCase: .reasoning,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testEqualCatalogFamilyDuplicatesHaveStableFieldTieBreakers() {
        let local = readyModel(path: "/mlx/coder", name: "Code Local", modelKey: "org/coder", bytes: 2_000)
        let snapshot = makeSnapshot(models: [local], memoryBytes: 16_000)
        let codingRecord = catalogRecord(
            repoIdentity: "org/coder",
            roles: [.coding],
            estimatedMemoryBytes: 4_000,
            updatedAt: fixtureNow
        )
        let chatRecord = catalogRecord(
            repoIdentity: "org/coder",
            roles: [.generalChat],
            estimatedMemoryBytes: 8_000,
            updatedAt: fixtureNow
        )
        let first = RecommendationEngine.recommend(
            useCase: .coding,
            snapshot: snapshot,
            catalog: .current(makeCatalogSnapshot(records: [codingRecord, chatRecord])),
            benchmarkResults: [],
            preferences: .defaults
        )
        let reversed = RecommendationEngine.recommend(
            useCase: .coding,
            snapshot: snapshot,
            catalog: .current(makeCatalogSnapshot(records: [chatRecord, codingRecord])),
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertEqual(first, reversed)
        XCTAssertEqual(first.first?.modelID, local.item.path)
        XCTAssertTrue(first.first?.reasons.contains(where: { $0.name == "catalog_role" }) == true)
    }

    func testLocalBenchmarkEvidenceBreaksTieConservatively() {
        let faster = readyModel(path: "/mlx/faster", name: "Coder Fast", modelKey: "org/coder-fast", bytes: 2_000)
        let slower = readyModel(path: "/mlx/slower", name: "Coder Slow", modelKey: "org/coder-slow", bytes: 2_000)
        let snapshot = makeSnapshot(models: [slower, faster], memoryBytes: 16_000)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/coder-fast", roles: [.coding], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/coder-slow", roles: [.coding], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )
        let benchmarks = [
            RecommendationBenchmarkResult(
                modelID: faster.item.path,
                useCase: .coding,
                tokensPerSecond: 31,
                timeToFirstTokenSeconds: 0.8,
                measuredAt: fixtureNow,
                sampleCount: 2
            ),
            RecommendationBenchmarkResult(
                modelID: slower.item.path,
                useCase: .coding,
                tokensPerSecond: 11,
                timeToFirstTokenSeconds: 2.2,
                measuredAt: fixtureNow,
                sampleCount: 1
            )
        ]

        let result = RecommendationEngine.recommend(
            useCase: .coding,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: benchmarks,
            preferences: .defaults
        )

        XCTAssertEqual(result.map(\.modelID), [faster.item.path, slower.item.path])
        XCTAssertEqual(result.first?.confidence, .high)
    }

    func testEqualBenchmarkDuplicatesHaveStableMetricTieBreakers() {
        let local = readyModel(path: "/mlx/coder", name: "Code Local", modelKey: "org/coder", bytes: 2_000)
        let snapshot = makeSnapshot(models: [local], memoryBytes: 16_000)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/coder", roles: [.coding], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )
        let slower = RecommendationBenchmarkResult(
            modelID: local.item.path,
            useCase: .coding,
            tokensPerSecond: 10,
            timeToFirstTokenSeconds: 2.0,
            measuredAt: fixtureNow,
            sampleCount: 1
        )
        let faster = RecommendationBenchmarkResult(
            modelID: local.item.path,
            useCase: .coding,
            tokensPerSecond: 30,
            timeToFirstTokenSeconds: 0.5,
            measuredAt: fixtureNow,
            sampleCount: 1
        )

        let first = RecommendationEngine.recommend(
            useCase: .coding,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [slower, faster],
            preferences: .defaults
        )
        let reversed = RecommendationEngine.recommend(
            useCase: .coding,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [faster, slower],
            preferences: .defaults
        )

        XCTAssertEqual(first, reversed)
        XCTAssertTrue(first.first?.evidence.contains(where: { $0.name == "local_benchmark" && $0.value.contains("30") }) == true)
    }

    func testStaleCatalogLabelDoesNotMasqueradeAsCurrent() {
        let vision = readyModel(path: "/mlx/vision", name: "Vision Local", modelKey: "org/vision-local", bytes: 2_000)
        let snapshot = makeSnapshot(models: [vision], memoryBytes: 16_000)
        let catalog = CatalogState.stale(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/vision-local", roles: [.vision], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow.addingTimeInterval(-86_400))
                ]
            )
        )

        let result = RecommendationEngine.recommend(
            useCase: .vision,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertEqual(result.first?.freshness, .catalogStale)
        XCTAssertTrue(result.first?.reasons.contains(where: { $0.name == "stale_catalog_role" }) == true)
    }

    func testDeterministicTieBreakUsesStableModelIDOrder() {
        let alpha = readyModel(path: "/mlx/a", name: "Same", modelKey: "org/same-a", bytes: 2_000)
        let beta = readyModel(path: "/mlx/b", name: "Same", modelKey: "org/same-b", bytes: 2_000)
        let snapshot = makeSnapshot(models: [beta, alpha], memoryBytes: 16_000)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/same-a", roles: [.generalChat], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/same-b", roles: [.generalChat], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )

        let result = RecommendationEngine.recommend(
            useCase: .generalChat,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertEqual(result.map(\.modelID), [alpha.item.path, beta.item.path])
    }

    func testHideAndPreferOverridesApplyAfterHardGates() {
        let hidden = readyModel(path: "/mlx/hidden", name: "Chat Hidden", modelKey: "org/chat-hidden", bytes: 1_000)
        let preferred = readyModel(path: "/mlx/preferred", name: "Chat Preferred", modelKey: "org/chat-preferred", bytes: 3_000)
        let other = readyModel(path: "/mlx/other", name: "Chat Other", modelKey: "org/chat-other", bytes: 2_000)
        let snapshot = makeSnapshot(models: [hidden, preferred, other], memoryBytes: 16_000)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/chat-hidden", roles: [.generalChat], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/chat-preferred", roles: [.generalChat], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/chat-other", roles: [.generalChat], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )
        let preferences = RecommendationPreferences(
            speedWeight: 1,
            qualityWeight: 1,
            hiddenModelIDs: [hidden.item.path],
            preferredModelIDs: [.generalChat: preferred.item.path]
        )

        let result = RecommendationEngine.recommend(
            useCase: .generalChat,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: preferences
        )

        XCTAssertEqual(result.map(\.modelID), [preferred.item.path, other.item.path])
        XCTAssertFalse(result.contains(where: { $0.modelID == hidden.item.path }))
    }

    func testUnreadableIncompatibleAndMissingRuntimeInventoryProducesNoRecommendation() {
        let unreadable = model(path: "/vault/unreadable.gguf", name: "Vision Local", modelKey: "org/unreadable", bytes: 1_000, readiness: .unsupported, readable: false)
        let incompatible = model(path: "/vault/incompatible.gguf", name: "Vision Local 2", modelKey: "org/incompatible", bytes: 1_000, readiness: .unsupported)
        let runtimeMissing = model(path: "/mlx/runtime-missing", name: "Vision Runtime", modelKey: "org/runtime-missing", bytes: 1_000, readiness: .needsRuntime)
        let snapshot = makeSnapshot(models: [unreadable, incompatible, runtimeMissing], memoryBytes: 16_000)
        let catalog = CatalogState.current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/unreadable", roles: [.vision], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/incompatible", roles: [.vision], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/runtime-missing", roles: [.vision], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )

        let result = RecommendationEngine.recommend(
            useCase: .vision,
            snapshot: snapshot,
            catalog: catalog,
            benchmarkResults: [],
            preferences: .defaults
        )

        XCTAssertTrue(result.isEmpty)
    }

    @MainActor
    func testAppHostRecommendationsFollowSnapshotCatalogBenchmarkAndPreferenceChanges() {
        let first = readyModel(path: "/mlx/first", name: "Coder First", modelKey: "org/coder-first", bytes: 2_000)
        let second = readyModel(path: "/mlx/second", name: "Coder Second", modelKey: "org/coder-second", bytes: 2_000)
        let host = AppHost(
            config: Config.defaults(),
            discoveredRoots: [],
            vendorAgentPath: "/tmp/vendor/mlx-agent",
            configPath: "/tmp/mlx-workbench/config.json",
            agentHealth: .ready(path: "/tmp/vendor/mlx-agent", cli: "/tmp/vendor/mlx-agent/scripts/mlx-agent"),
            runtimeReport: makeRuntimeReport(),
            hardwareProfile: HardwareProfile(chip: "Apple", model: "Mac", memoryBytes: 16_000, macOSVersion: "15.0"),
            now: { self.fixtureNow }
        )
        host.librarySnapshot = makeSnapshot(models: [first, second], memoryBytes: 16_000)
        host.catalog = .current(
            makeCatalogSnapshot(
                records: [
                    catalogRecord(repoIdentity: "org/coder-first", roles: [.coding], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow),
                    catalogRecord(repoIdentity: "org/coder-second", roles: [.coding], estimatedMemoryBytes: 4_000, updatedAt: fixtureNow)
                ]
            )
        )

        XCTAssertEqual(host.recommendations(for: .coding).map(\.modelID), [first.item.path, second.item.path])

        host.benchmarkResults = [
            RecommendationBenchmarkResult(
                modelID: second.item.path,
                useCase: .coding,
                tokensPerSecond: 28,
                timeToFirstTokenSeconds: 0.9,
                measuredAt: fixtureNow,
                sampleCount: 2
            )
        ]

        XCTAssertEqual(host.recommendations(for: .coding).map(\.modelID), [second.item.path, first.item.path])

        host.recommendationPreferences = RecommendationPreferences(
            speedWeight: 1,
            qualityWeight: 1,
            hiddenModelIDs: [],
            preferredModelIDs: [.coding: first.item.path]
        )

        XCTAssertEqual(host.recommendations(for: .coding).map(\.modelID), [first.item.path, second.item.path])

        host.agentHealth = .notUsable(
            path: "/tmp/vendor/mlx-agent",
            cli: "/tmp/vendor/mlx-agent/scripts/mlx-agent",
            reason: "Agent unavailable."
        )
        XCTAssertTrue(host.recommendations(for: .coding).isEmpty)

        host.agentHealth = .ready(path: "/tmp/vendor/mlx-agent", cli: "/tmp/vendor/mlx-agent/scripts/mlx-agent")
        host.runtimeReport = makeRuntimeReport(ok: false)
        XCTAssertTrue(host.recommendations(for: .coding).isEmpty)

        host.runtimeReport = makeRuntimeReport()
        XCTAssertEqual(host.recommendations(for: .coding).map(\.modelID), [first.item.path, second.item.path])
    }
}

private extension RecommendationEngineTests {
    var fixtureNow: Date {
        Date(timeIntervalSince1970: 1_725_000_000)
    }

    func makeSnapshot(models: [LibraryModel], memoryBytes: Int64?) -> LibrarySnapshot {
        LibrarySnapshot(
            models: models,
            groups: models.map { ModelGroup(variants: [$0]) },
            hardware: HardwareProfile(
                chip: "Apple M4",
                model: "Mac16,7",
                memoryBytes: memoryBytes,
                macOSVersion: "15.0"
            ),
            generatedAt: fixtureNow
        )
    }

    func makeCatalogSnapshot(records: [CatalogRecord]) -> CatalogSnapshot {
        CatalogSnapshot(
            provider: "fixture-provider",
            source: "fixtures/catalog.json",
            revision: "fixture-revision",
            fetchedAt: fixtureNow,
            metadataOnly: true,
            records: records
        )
    }

    func catalogRecord(
        repoIdentity: String,
        roles: [UseCase],
        estimatedMemoryBytes: Int64?,
        updatedAt: Date
    ) -> CatalogRecord {
        CatalogRecord(
            repoIdentity: repoIdentity,
            revision: "rev-\(repoIdentity)",
            updatedAt: updatedAt,
            roles: roles,
            estimatedMemoryBytes: estimatedMemoryBytes,
            formats: ["mlx"],
            sourceURL: URL(string: "https://example.com/\(repoIdentity)")!
        )
    }

    func readyModel(
        path: String,
        name: String,
        modelKey: String,
        bytes: Int64
    ) -> LibraryModel {
        model(path: path, name: name, modelKey: modelKey, bytes: bytes, readiness: .ready)
    }

    func model(
        path: String,
        name: String,
        modelKey: String,
        bytes: Int64,
        readiness: ModelReadiness,
        readable: Bool = true
    ) -> LibraryModel {
        let outputPaths = readiness == .ready ? [path] : []
        return LibraryModel(
            item: ModelItem(
                path: path,
                name: name,
                bytes: bytes,
                modifiedAt: Int(fixtureNow.timeIntervalSince1970),
                shard: nil,
                modelKey: modelKey,
                architecture: "llama",
                quantization: "Q4_K_M",
                parameters: "7B",
                structure: nil,
                signature: nil,
                companion: nil,
                readable: readable,
                status: readiness.rawValue,
                outputs: outputPaths,
                tensorCount: nil,
                error: readable ? nil : "Permission denied"
            ),
            normalizedFamilyKey: modelKey.replacingOccurrences(of: "/", with: ""),
            displayName: name,
            readiness: readiness,
            capabilities: [useCaseHint(from: name)],
            sourcePaths: [path],
            outputPaths: outputPaths,
            evidence: ["path=\(path)"]
        )
    }

    func useCaseHint(from name: String) -> UseCase {
        let lowercased = name.lowercased()
        if lowercased.contains("vision") {
            return .vision
        }
        if lowercased.contains("reason") {
            return .reasoning
        }
        if lowercased.contains("code") || lowercased.contains("coder") {
            return .coding
        }
        return .generalChat
    }

    func makeRuntimeReport(ok: Bool = true) -> RuntimeReport {
        RuntimeReport(
            convert: ConvertStatus(
                ok: ok,
                modules: [:],
                executables: [:],
                missingModules: [],
                missingExecutables: [],
                install: "make install",
                message: "Convert dependencies ready."
            ),
            serve: ServeStatus(
                ok: ok,
                executables: [:],
                missingExecutables: [],
                install: "make install",
                message: "Serve runtime ready."
            ),
            install: "make install",
            ok: ok
        )
    }
}
