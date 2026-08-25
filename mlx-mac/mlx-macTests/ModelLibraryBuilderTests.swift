import Foundation
import XCTest

@testable import mlx_workbench

final class ModelLibraryBuilderTests: XCTestCase {
    func testBuildGroupsByModelKeyAndNormalizedFallbackWithoutMergingByDisplayName() throws {
        let snapshot = ModelLibraryBuilder.build(
            scan: makeFixtureScan(),
            hardware: fixtureHardware,
            now: fixtureDate
        )

        XCTAssertEqual(snapshot.generatedAt, fixtureDate)
        XCTAssertEqual(snapshot.hardware, fixtureHardware)
        XCTAssertEqual(snapshot.models.count, 8)
        XCTAssertEqual(snapshot.groups.count, 6)

        let assistantGroups = snapshot.groups.filter { $0.primaryDisplayName == "Assistant" }
        XCTAssertEqual(assistantGroups.count, 4)
        XCTAssertEqual(
            assistantGroups.compactMap(\.variants.first?.item.path),
            [
                "/downloads/Phi-4-mini-instruct-Q4_K_M.gguf",
                "/mlx/OpenHermes-2.5-7B",
                "/models/Mistral-7B-Instruct-v0.3-00001-of-00002.gguf",
                "/vault/Gemma-3-4B-it-Q4_K_M.gguf",
            ]
        )

        let llamaGroup = try XCTUnwrap(snapshot.groups.first { $0.modelKey == "mlxcommunityllama323binstruct" })
        XCTAssertEqual(
            Set(llamaGroup.variants.map(\.item.path)),
            Set([
                "/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                "/archive/Llama-3.2-3B-Instruct-Q4_K_M-copy.gguf",
                "/mlx/Llama-3.2-3B-Instruct-4bit",
            ])
        )

        let shardModel = try XCTUnwrap(snapshot.models.first { $0.item.path == "/models/Mistral-7B-Instruct-v0.3-00001-of-00002.gguf" })
        XCTAssertEqual(
            shardModel.sourcePaths,
            [
                "/models/Mistral-7B-Instruct-v0.3-00001-of-00002.gguf",
                "/models/Mistral-7B-Instruct-v0.3-00002-of-00002.gguf",
            ]
        )

        let mlxOutput = try XCTUnwrap(snapshot.models.first { $0.item.path == "/mlx/Llama-3.2-3B-Instruct-4bit" })
        XCTAssertEqual(mlxOutput.outputPaths, ["/mlx/Llama-3.2-3B-Instruct-4bit"])
    }

    func testBuildMapsReadinessAndComputesByteTotalsWithoutDoubleCountingDuplicateSources() {
        let snapshot = ModelLibraryBuilder.build(
            scan: makeFixtureScan(),
            hardware: fixtureHardware,
            now: fixtureDate
        )

        XCTAssertEqual(readiness(in: snapshot, path: "/quarantine/Unsafe-Model-Q4_K_M.gguf"), .quarantined)
        XCTAssertEqual(readiness(in: snapshot, path: "/vault/Gemma-3-4B-it-Q4_K_M.gguf"), .unsupported)
        XCTAssertEqual(readiness(in: snapshot, path: "/models/Mistral-7B-Instruct-v0.3-00001-of-00002.gguf"), .incompleteCache)
        XCTAssertEqual(readiness(in: snapshot, path: "/mlx/OpenHermes-2.5-7B"), .needsRuntime)
        XCTAssertEqual(readiness(in: snapshot, path: "/archive/Llama-3.2-3B-Instruct-Q4_K_M-copy.gguf"), .duplicate)
        XCTAssertEqual(readiness(in: snapshot, path: "/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf"), .ready)
        XCTAssertEqual(readiness(in: snapshot, path: "/downloads/Phi-4-mini-instruct-Q4_K_M.gguf"), .needsConversion)
        XCTAssertEqual(readiness(in: snapshot, path: "/mlx/Llama-3.2-3B-Instruct-4bit"), .ready)

        XCTAssertEqual(snapshot.totalBytes, 5_000)
        XCTAssertEqual(snapshot.reclaimableBytes, 1_500)
    }

    func testBuildUsesStableOrderingByDisplayNameThenPath() {
        let snapshot = ModelLibraryBuilder.build(
            scan: makeFixtureScan(),
            hardware: fixtureHardware,
            now: fixtureDate
        )

        XCTAssertEqual(
            snapshot.groups.map(\.primaryDisplayName),
            [
                "Assistant",
                "Assistant",
                "Assistant",
                "Assistant",
                "Llama 3.2 3B Instruct",
                "Unsafe Model",
            ]
        )
        XCTAssertEqual(
            snapshot.groups.compactMap(\.variants.first?.item.path),
            [
                "/downloads/Phi-4-mini-instruct-Q4_K_M.gguf",
                "/mlx/OpenHermes-2.5-7B",
                "/models/Mistral-7B-Instruct-v0.3-00001-of-00002.gguf",
                "/vault/Gemma-3-4B-it-Q4_K_M.gguf",
                "/archive/Llama-3.2-3B-Instruct-Q4_K_M-copy.gguf",
                "/quarantine/Unsafe-Model-Q4_K_M.gguf",
            ]
        )
    }

    @MainActor
    func testAppHostPreservesLastSuccessfulLibrarySnapshotOnFailedScan() async throws {
        let scan = makeFixtureScan()
        let script = ScanScript(steps: [.success(scan), .failure(TestScanError.boom)])
        let hardware = fixtureHardware
        let now = fixtureDate
        let host = AppHost(
            config: makeConfig(),
            discoveredRoots: [],
            vendorAgentPath: "/tmp/vendor/mlx-agent",
            configPath: "/tmp/mlx-workbench/config.json",
            agentHealth: .ready(path: "/tmp/vendor/mlx-agent", cli: "/tmp/vendor/mlx-agent/scripts/mlx-agent"),
            runtimeReport: makeRuntimeReport(),
            hardwareProfile: hardware,
            now: { now },
            scanOperation: { _, _, _, _ in
                try await script.next()
            }
        )

        XCTAssertEqual(host.hardwareProfile, hardware)
        XCTAssertNil(host.librarySnapshot)

        await host.rescan()
        let firstSnapshot = try XCTUnwrap(host.librarySnapshot)
        XCTAssertEqual(firstSnapshot, ModelLibraryBuilder.build(scan: scan, hardware: hardware, now: now))

        await host.rescan()
        XCTAssertEqual(host.librarySnapshot, firstSnapshot)
        XCTAssertEqual(host.scanResult, scan)
        XCTAssertEqual(host.hardwareProfile, hardware)
        XCTAssertEqual(host.lastError, TestScanError.boom.localizedDescription)
    }

    private func readiness(in snapshot: LibrarySnapshot, path: String) -> ModelReadiness? {
        snapshot.models.first(where: { $0.item.path == path })?.readiness
    }

    private func makeFixtureScan() -> ScanResult {
        let converted = ModelItem(
            path: "/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            name: "Llama 3.2 3B Instruct",
            bytes: 1_000,
            modifiedAt: 1_725_000_001,
            shard: nil,
            modelKey: "mlx-community/Llama-3.2-3B-Instruct",
            architecture: "llama",
            quantization: "Q4_K_M",
            parameters: "3B",
            structure: nil,
            signature: nil,
            companion: nil,
            readable: true,
            status: "ready",
            outputs: ["/mlx/Llama-3.2-3B-Instruct-4bit"],
            tensorCount: 32,
            error: nil
        )
        let duplicate = ModelItem(
            path: "/archive/Llama-3.2-3B-Instruct-Q4_K_M-copy.gguf",
            name: "Llama 3.2 3B Instruct",
            bytes: 1_000,
            modifiedAt: 1_725_000_002,
            shard: nil,
            modelKey: "mlx-community/Llama-3.2-3B-Instruct",
            architecture: "llama",
            quantization: "Q4_K_M",
            parameters: "3B",
            structure: nil,
            signature: nil,
            companion: nil,
            readable: true,
            status: "ready",
            outputs: [],
            tensorCount: 32,
            error: nil
        )
        let pending = ModelItem(
            path: "/downloads/Phi-4-mini-instruct-Q4_K_M.gguf",
            name: "Assistant",
            bytes: 500,
            modifiedAt: 1_725_000_003,
            shard: nil,
            modelKey: nil,
            architecture: "phi",
            quantization: "Q4_K_M",
            parameters: "mini",
            structure: nil,
            signature: nil,
            companion: nil,
            readable: true,
            status: "pending",
            outputs: [],
            tensorCount: nil,
            error: nil
        )
        let unreadable = ModelItem(
            path: "/vault/Gemma-3-4B-it-Q4_K_M.gguf",
            name: "Assistant",
            bytes: 600,
            modifiedAt: 1_725_000_004,
            shard: nil,
            modelKey: nil,
            architecture: "gemma",
            quantization: "Q4_K_M",
            parameters: "4B",
            structure: nil,
            signature: nil,
            companion: nil,
            readable: false,
            status: "ready",
            outputs: [],
            tensorCount: nil,
            error: "Permission denied"
        )
        let shard = ModelItem(
            path: "/models/Mistral-7B-Instruct-v0.3-00001-of-00002.gguf",
            name: "Assistant",
            bytes: 700,
            modifiedAt: 1_725_000_005,
            shard: "/models/Mistral-7B-Instruct-v0.3-00002-of-00002.gguf",
            modelKey: nil,
            architecture: "mistral",
            quantization: "Q4_K_M",
            parameters: "7B",
            structure: nil,
            signature: nil,
            companion: nil,
            readable: true,
            status: "ready",
            outputs: [],
            tensorCount: nil,
            error: nil
        )
        let runtimeMissing = ModelItem(
            path: "/mlx/OpenHermes-2.5-7B",
            name: "Assistant",
            bytes: 800,
            modifiedAt: 1_725_000_006,
            shard: nil,
            modelKey: nil,
            architecture: "mistral",
            quantization: nil,
            parameters: "7B",
            structure: nil,
            signature: nil,
            companion: nil,
            readable: true,
            status: "missing_runtime",
            outputs: [],
            tensorCount: nil,
            error: nil
        )
        let quarantined = ModelItem(
            path: "/quarantine/Unsafe-Model-Q4_K_M.gguf",
            name: "Unsafe Model",
            bytes: 400,
            modifiedAt: 1_725_000_007,
            shard: nil,
            modelKey: nil,
            architecture: nil,
            quantization: "Q4_K_M",
            parameters: nil,
            structure: nil,
            signature: nil,
            companion: nil,
            readable: true,
            status: "quarantined",
            outputs: [],
            tensorCount: nil,
            error: nil
        )

        return ScanResult(
            roots: ScanRoots(
                gguf: ["/models", "/downloads", "/vault"],
                mlx: ["/mlx"]
            ),
            models: [converted, duplicate, pending, unreadable, shard, runtimeMissing, quarantined],
            outputs: [
                MLXOutput(
                    path: "/mlx/Llama-3.2-3B-Instruct-4bit",
                    name: "Llama 3.2 3B Instruct",
                    modelKey: "mlx-community/Llama-3.2-3B-Instruct",
                    quantization: QuantInfo(bits: 4, groupSize: 64, modelType: "llm"),
                    provenance: "/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
                )
            ],
            pending: ["/downloads/Phi-4-mini-instruct-Q4_K_M.gguf"],
            duplicates: [
                DuplicateGroup(
                    kind: "exact",
                    modelKey: "mlx-community/Llama-3.2-3B-Instruct",
                    quantization: "Q4_K_M",
                    quantizations: ["Q4_K_M"],
                    reclaimableBytes: 1_500,
                    keep: "/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                    redundant: [
                        "/archive/Llama-3.2-3B-Instruct-Q4_K_M-copy.gguf",
                        "/backup/Llama-3.2-3B-Instruct-Q4_K_M-copy-2.gguf",
                    ],
                    members: [
                        "/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                        "/archive/Llama-3.2-3B-Instruct-Q4_K_M-copy.gguf",
                        "/backup/Llama-3.2-3B-Instruct-Q4_K_M-copy-2.gguf",
                    ],
                    count: 2,
                    groupId: "dup-llama-exact"
                )
            ],
            totals: ScanTotals(
                gguf: 7,
                pending: 1,
                converted: 1,
                unreadable: 1,
                bytes: 5_000,
                reclaimableBytes: 1_500
            )
        )
    }

    private func makeConfig() -> Config {
        Config(
            schemaVersion: Config.SCHEMA_VERSION,
            ggufRoots: ["/models"],
            mlxRoots: ["/mlx"],
            outputDir: "/mlx",
            mlxAgentPath: "/tmp/vendor/mlx-agent",
            quarantineDir: "/quarantine",
            qBits: 4,
            signatures: true,
            host: "127.0.0.1",
            port: 8765
        )
    }

    private func makeRuntimeReport() -> RuntimeReport {
        RuntimeReport(
            convert: ConvertStatus(
                ok: true,
                modules: [:],
                executables: [:],
                missingModules: [],
                missingExecutables: [],
                install: "make install",
                message: "Convert dependencies ready."
            ),
            serve: ServeStatus(
                ok: true,
                executables: [:],
                missingExecutables: [],
                install: "make install",
                message: "Serve runtime ready."
            ),
            install: "make install",
            ok: true
        )
    }

    private var fixtureHardware: HardwareProfile {
        HardwareProfile(
            chip: "Apple M4 Pro",
            model: "Mac16,7",
            memoryBytes: 48 * 1_024 * 1_024 * 1_024,
            macOSVersion: "15.0"
        )
    }

    private var fixtureDate: Date {
        Date(timeIntervalSince1970: 1_725_000_000)
    }
}

private actor ScanScript {
    private var steps: [Result<ScanResult, Error>]

    init(steps: [Result<ScanResult, Error>]) {
        self.steps = steps
    }

    func next() throws -> ScanResult {
        try steps.removeFirst().get()
    }
}

private enum TestScanError: LocalizedError {
    case boom

    var errorDescription: String? {
        switch self {
        case .boom:
            return "boom"
        }
    }
}
