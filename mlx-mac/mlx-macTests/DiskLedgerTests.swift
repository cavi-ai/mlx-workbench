import Foundation
import XCTest

@testable import mlx_workbench

final class DiskLedgerTests: XCTestCase {
    // MARK: Decode

    func testStorageAndFamiliesDecodeFromTheScanContract() throws {
        var payload = Self.scanPayload
        let result = try WorkbenchAPI.decodeScan(payload)
        let storage = try XCTUnwrap(result.storage)
        XCTAssertEqual(storage.diskBytes, 4_733_365_399)
        XCTAssertEqual(storage.roots.first?.totalBytes, 5_000_000_000)
        XCTAssertEqual(storage.roots.first?.other, [OtherPlace(path: "/m/lmstudio/unsorted", bytes: 266_634_601)])
        XCTAssertEqual(storage.stores, [StoreUsage(store: "ollama", bytes: 4_733_365_399)])
        XCTAssertEqual(storage.items.first?.store, "ollama")
        XCTAssertEqual(storage.items.first?.files.map(\.id), ["16777232:1295899263", "16777232:728849122"])
        XCTAssertEqual(result.families, [ModelFamily(familyID: "shape:fa0543a6567a6ca2", name: "llava", members: ["/m/ollama/manifests/registry.ollama.ai/library/llava/latest"], bytes: 4_733_365_399)])

        payload["storage"] = nil
        payload["families"] = nil
        let older = try WorkbenchAPI.decodeScan(payload)
        XCTAssertNil(older.storage)
        XCTAssertNil(older.families)
    }

    // MARK: Freed bytes

    func testAFileIsFreedOnlyWhenEveryCopyHoldingItGoes() {
        let items = Self.items
        XCTAssertEqual(DiskLedger.freedBytes(removing: ["/m/ollama/manifests/r/library/tiny/a"], items: items), 115)
        XCTAssertEqual(DiskLedger.freedBytes(removing: ["/m/ollama/manifests/r/library/tiny/a", "/m/ollama/manifests/r/library/tiny/b"], items: items), 182)
        XCTAssertEqual(DiskLedger.freedBytes(removing: ["/m/hub/models--org--x/snapshots/one"], items: items), 230,
                       "a snapshot leaves with its whole cache repository")
        XCTAssertEqual(DiskLedger.freedBytes(removing: ["/m/gguf/x-Q4.gguf"], items: items), 400,
                       "notes beside a GGUF stay on disk")
    }

    func testTheUsedVersionIsKeptAndAPersonCanChooseAnother() throws {
        let keyed: Set<String> = ["/m/gguf/x-Q4.gguf", "/m/ollama/manifests/r/library/tiny/a", "/m/mlx/x-4bit"]
        let items = Self.items.map { item in
            StoredModel(path: item.path, kind: item.kind, format: item.format, name: item.name, modelKey: keyed.contains(item.path) ? "x" : nil,
                        root: item.root, store: item.store, bytes: item.bytes, files: item.files)
        }
        let storage = ScanStorage(diskBytes: 0, roots: [], stores: [], items: items)
        let family = ModelFamily(familyID: "shape:x", name: "X", members: keyed.sorted(), bytes: 0)
        let usedAt = Date()
        let used = ["/m/ollama/manifests/r/library/tiny/a": usedAt]
        let models = DiskLedger.models(storage: storage, families: [family], lastUsedByPath: used, protectedPaths: ["/m/mlx/x-4bit"])
        let x = try XCTUnwrap(models.first { $0.copies.count == 3 })
        XCTAssertEqual(x.keep, "/m/ollama/manifests/r/library/tiny/a")
        XCTAssertEqual(x.keepReason, .used(usedAt))
        XCTAssertEqual(x.removable.map(\.id), ["/m/gguf/x-Q4.gguf"])
        XCTAssertEqual(x.couldFree, 400)
        XCTAssertEqual(x.bytes, 403 + 10 + 5 + 100 + 7 + 300)
        XCTAssertEqual(models.count, 4, "every model outside a family is its own row")

        let chosen = DiskLedger.models(storage: storage, families: [family], lastUsedByPath: used, protectedPaths: [],
                                       keep: [x.id: "/m/mlx/x-4bit"]).first { $0.id == x.id }
        XCTAssertEqual(chosen?.keep, "/m/mlx/x-4bit")
        XCTAssertEqual(chosen?.keepReason, .chosen)
        XCTAssertEqual(chosen?.couldFree, 400 + 115)

        let stale = Date().addingTimeInterval(-86_400)
        XCTAssertEqual(DiskLedger.filter(models, by: .redundant, staleBefore: stale).map(\.id), [x.id])
        XCTAssertFalse(DiskLedger.filter(models, by: .unused, staleBefore: stale).contains { $0.id == x.id })
        XCTAssertTrue(DiskLedger.filter(models, by: .unused, staleBefore: stale).contains { $0.copies.first?.id == "/m/ollama/manifests/r/library/tiny/b" })
    }

    func testFineTunesInOneArchitectureFamilyAreSeparateModelsAndNothingIsKeptWithoutEvidence() throws {
        func item(_ path: String, key: String, _ bytes: Int64, kind: String = "folder") -> StoredModel {
            StoredModel(path: path, kind: kind, format: kind == "gguf" ? "gguf" : "mlx", name: URL(fileURLWithPath: path).lastPathComponent,
                        modelKey: key, root: "/models", store: "folder", bytes: bytes,
                        files: [Self.file(path, kind == "gguf" ? path : path + "/model.safetensors", bytes)])
        }
        let items = [
            item("/models/mlx/Qwen3.5-27B-4bit", key: "qwen3.5-27b", 15),
            item("/models/gguf/Qwen3.5-27B-Q8_0.gguf", key: "qwen3.5-27b", 28, kind: "gguf"),
            item("/models/mlx/Qwen3.8-27B-Coder-4bit", key: "qwen3.8-27b-coder", 15),
        ]
        let storage = ScanStorage(diskBytes: 0, roots: [], stores: [], items: items)
        let family = ModelFamily(familyID: "shape:q27", name: "Qwen3.5-27B", members: items.map(\.path), bytes: 58)
        let models = DiskLedger.models(storage: storage, families: [family])
        XCTAssertEqual(models.map(\.name), ["Qwen3.5-27B", "Qwen3.8-27B-Coder"])
        let base = try XCTUnwrap(models.first)
        XCTAssertEqual(base.copies.map(\.id), ["/models/gguf/Qwen3.5-27B-Q8_0.gguf", "/models/mlx/Qwen3.5-27B-4bit"], "largest first")
        XCTAssertNil(base.keep, "no recorded use and nothing serving: no version is marked to keep")
        XCTAssertEqual(base.couldFree, 15)
        XCTAssertEqual(base.copies.map { DiskLedger.versionLabel($0.item, model: base) }, ["GGUF Q8_0", "MLX 4bit"])
        XCTAssertEqual(models.last?.copies.count, 1)
    }

    func testSuggestionsSayWhatToRemoveWhyAndHowMuchItFrees() {
        let gb: Int64 = 1_000_000_000
        func item(_ path: String, key: String, _ bytes: Int64) -> StoredModel {
            StoredModel(path: path, kind: "folder", format: "mlx", name: URL(fileURLWithPath: path).lastPathComponent, modelKey: key,
                        root: "/models", store: "folder", bytes: bytes, files: [Self.file(path, path + "/model.safetensors", bytes)])
        }
        let items = [
            item("/models/a/Alpha-7B-4bit", key: "alpha-7b", 4 * gb), item("/models/b/Alpha-7B-4bit", key: "alpha-7b", 4 * gb),
            item("/models/Beta-9B-4bit", key: "beta-9b", 5 * gb), item("/models/Beta-9B-8bit", key: "beta-9b", 9 * gb),
            item("/models/Gamma-3B-4bit", key: "gamma-3b", 2 * gb), item("/models/Gamma-3B-bf16", key: "gamma-3b", 6 * gb),
            item("/models/Delta-30B-4bit", key: "delta-30b", 17 * gb),
            item("/models/Tiny-1B-4bit", key: "tiny-1b", gb / 2),
            item("/models/Served-4B-4bit", key: "served-4b", 3 * gb),
        ]
        let families = [
            ModelFamily(familyID: "shape:alpha", name: "Alpha", members: ["/models/a/Alpha-7B-4bit", "/models/b/Alpha-7B-4bit"], bytes: 0),
            ModelFamily(familyID: "shape:beta", name: "Beta", members: ["/models/Beta-9B-4bit", "/models/Beta-9B-8bit"], bytes: 0),
            ModelFamily(familyID: "shape:gamma", name: "Gamma", members: ["/models/Gamma-3B-4bit", "/models/Gamma-3B-bf16"], bytes: 0),
        ]
        let identical = DuplicateGroup(kind: "exact", modelKey: "alpha-7b", quantization: nil, quantizations: nil, reclaimableBytes: 4 * gb,
                                       keep: "/models/a/Alpha-7B-4bit", redundant: ["/models/b/Alpha-7B-4bit"], members: nil, count: 2, groupId: "g1")
        let now = Date()
        let storage = ScanStorage(diskBytes: 0, roots: [], stores: [], items: items)
        let models = DiskLedger.models(storage: storage, families: families, duplicates: [identical],
                                       lastUsedByPath: ["/models/Beta-9B-4bit": now.addingTimeInterval(-86_400)],
                                       protectedPaths: ["/models/Served-4B-4bit"])
        let suggestions = DiskLedger.suggestions(models: models, items: items, duplicates: [identical],
                                                 staleBefore: now.addingTimeInterval(-30 * 86_400),
                                                 modifiedByPath: ["/models/Delta-30B-4bit": now.addingTimeInterval(-90 * 86_400)], now: now)
        XCTAssertEqual(suggestions.map(\.kind), [.identical, .notUsed, .otherVersions, .chooseVersion])
        XCTAssertEqual(suggestions.map(\.remove), [["/models/b/Alpha-7B-4bit"], ["/models/Delta-30B-4bit"], ["/models/Beta-9B-8bit"], []])
        XCTAssertEqual(suggestions.map(\.bytes), [4 * gb, 17 * gb, 9 * gb, 2 * gb])
        XCTAssertEqual(suggestions.map(\.name), ["Alpha-7B", "Delta-30B", "Beta-9B", "Gamma-3B"])
        XCTAssertEqual(suggestions[0].detail, "The same weights are stored 2 times. Keeps the copy in a.")
        XCTAssertTrue(suggestions[1].detail.hasPrefix("No use recorded here; files unchanged since "), suggestions[1].detail)
        XCTAssertTrue(suggestions[2].detail.hasPrefix("MLX 4bit was used "), suggestions[2].detail)
        XCTAssertTrue(suggestions[2].detail.hasSuffix(" The other version was not used recently."), suggestions[2].detail)
        XCTAssertTrue(suggestions[3].detail.hasPrefix("2 versions, none used recently: MLX bf16 "), suggestions[3].detail)
        XCTAssertTrue(suggestions[3].detail.hasSuffix(". Keep the one you run."), suggestions[3].detail)
    }

    // MARK: Ollama quarantine

    func testAnOllamaTagLeavesWithItsUnsharedBlobsAndComesBackWhole() throws {
        let root = try makeRoot(), quarantine = try makeRoot()
        let ollama = try Self.ollama(in: root)
        let plan = try Quarantine.ollamaSnapshot(manifest: ollama.a.path, roots: [root.path], protected: [])
        XCTAssertEqual(plan.blobs, ["sha256-a1", "sha256-b2"])
        XCTAssertEqual(plan.bytes, Int64(try Data(contentsOf: ollama.a).count) + 4 + 100)

        let record = try Quarantine.moveOllamaModel(expected: plan, roots: [root.path], protected: [], quarantineDir: quarantine.path)
        XCTAssertEqual(record.kind, .ollamaModel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ollama.a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ollama.blobs.appendingPathComponent("sha256-b2").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ollama.blobs.appendingPathComponent("sha256-c3").path), "tag b still needs it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ollama.b.path))
        XCTAssertEqual(Quarantine.ledger(quarantineDir: quarantine.path).first, record)
        XCTAssertEqual(try Quarantine.trashSnapshot(record, quarantineDir: quarantine.path).bytes, plan.bytes)

        try Quarantine.restore(record)
        XCTAssertEqual(try Data(contentsOf: ollama.a), Self.manifest(["a1", "b2", "c3"]))
        XCTAssertEqual(try Data(contentsOf: ollama.blobs.appendingPathComponent("sha256-b2")).count, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.to))
    }

    func testAnOllamaTagThatChangedAfterPreviewStays() throws {
        let root = try makeRoot(), quarantine = try makeRoot()
        let ollama = try Self.ollama(in: root)
        let plan = try Quarantine.ollamaSnapshot(manifest: ollama.a.path, roots: [root.path], protected: [])
        try Self.manifest(["c3", "b2"]).write(to: ollama.b)
        XCTAssertThrowsError(try Quarantine.moveOllamaModel(expected: plan, roots: [root.path], protected: [], quarantineDir: quarantine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ollama.a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ollama.blobs.appendingPathComponent("sha256-b2").path))
    }

    // MARK: Coordinator

    @MainActor
    func testRemovingCopiesMovesEachFormatAndSkipsWhatAGuardRefuses() async throws {
        let root = try makeRoot(), quarantine = try makeRoot()
        let fm = FileManager.default
        let gguf = root.appendingPathComponent("gguf/x-Q4.gguf"), notes = root.appendingPathComponent("gguf/README.md")
        try fm.createDirectory(at: gguf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 40).write(to: gguf)
        try Data("notes".utf8).write(to: notes)
        let folder = root.appendingPathComponent("mlx/x-4bit"), plain = root.appendingPathComponent("mlx/x-bf16")
        for directory in [folder, plain] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 2, count: 30).write(to: directory.appendingPathComponent("model.safetensors"))
        }
        try Data("{\"quantization\":{\"bits\":4}}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: plain.appendingPathComponent("config.json"))
        let ollama = try Self.ollama(in: root)
        func item(_ url: URL, _ kind: String, _ store: String, _ files: [URL]) -> StoredModel {
            StoredModel(path: url.path, kind: kind, format: nil, name: url.lastPathComponent, modelKey: nil, root: root.path, store: store, bytes: 0,
                        files: files.map { StoredFile(id: $0.path, path: $0.path, bytes: 1) })
        }
        let items = [
            item(gguf, "gguf", "folder", [gguf, notes]),
            item(folder, "folder", "folder", [folder.appendingPathComponent("model.safetensors")]),
            item(plain, "folder", "folder", [plain.appendingPathComponent("model.safetensors")]),
            item(ollama.a, "ollama", "ollama", [ollama.a]),
        ]
        let coordinator = ReclaimCoordinator()
        coordinator.ggufRoots = { [root.path] }
        coordinator.mlxRoots = { [root.path] }
        coordinator.quarantineDir = { quarantine.path }
        coordinator.servingModelPaths = { [] }

        await coordinator.previewCopies(Set(items.map(\.path)), items: items)
        let plan = try XCTUnwrap(coordinator.copyPlan)
        XCTAssertEqual(plan.actionable.map(\.path).sorted(), [gguf.path, folder.path, ollama.a.path].sorted())
        XCTAssertNotNil(plan.removals.first { $0.path == plain.path }?.refusal)

        await coordinator.confirmCopies()
        XCTAssertNil(coordinator.lastError)
        XCTAssertNil(coordinator.copyPlan)
        XCTAssertFalse(fm.fileExists(atPath: gguf.path))
        XCTAssertTrue(fm.fileExists(atPath: notes.path))
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
        XCTAssertTrue(fm.fileExists(atPath: plain.path))
        XCTAssertFalse(fm.fileExists(atPath: ollama.a.path))
        XCTAssertEqual(Set(coordinator.quarantined.map(\.kind)), [nil, .mlxDirectory, .ollamaModel])
    }

    // MARK: Model sources

    func testModelSourceColumnsSortByWhatTheyShow() {
        let servers = [
            ServerInfo(path: "/models/zeta", port: 1, pid: 10, state: "running", modelState: "loaded", receiptsDirectory: "/receipts"),
            ServerInfo(path: "/models/alpha", port: 2, pid: 20, state: "running", modelState: "loaded", receiptsDirectory: "/receipts"),
        ]
        let snapshot = ServingInventorySnapshot.make(engine: servers, hosts: [], managedReceipts: "/receipts", capturedAt: Date())
        let rows = ServingRows.build(slots: [], servers: servers, snapshot: snapshot)
        let byModel = ModelSourceRow.rows(rows, models: [], sortOrder: [KeyPathComparator(\ModelSourceRow.model)])
        let byAddress = ModelSourceRow.rows(rows, models: [], sortOrder: [KeyPathComparator(\ModelSourceRow.address)])
        XCTAssertEqual(byModel.map(\.model), byModel.map(\.model).sorted())
        XCTAssertEqual(byAddress.map(\.address), byAddress.map(\.address).sorted())
        XCTAssertNotEqual(byModel.map(\.id), byAddress.map(\.id), "zeta serves on the lower port")
    }

    // MARK: Fixtures

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-workbench-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static func manifest(_ digests: [String]) -> Data {
        let layers = digests.dropFirst().map { "{\"digest\":\"sha256:\($0)\"}" }.joined(separator: ",")
        return Data("{\"config\":{\"digest\":\"sha256:\(digests[0])\"},\"layers\":[\(layers)]}".utf8)
    }

    /// Tags a and b share blob c3; a1 and b2 belong to a alone.
    static func ollama(in root: URL) throws -> (a: URL, b: URL, blobs: URL) {
        let fm = FileManager.default
        let tags = root.appendingPathComponent("ollama/manifests/registry.ollama.ai/library/tiny")
        let blobs = root.appendingPathComponent("ollama/blobs")
        try fm.createDirectory(at: tags, withIntermediateDirectories: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        for (name, size) in [("a1", 4), ("b2", 100), ("c3", 7), ("d4", 50)] {
            try Data(repeating: 3, count: size).write(to: blobs.appendingPathComponent("sha256-" + name))
        }
        try manifest(["a1", "b2", "c3"]).write(to: tags.appendingPathComponent("a"))
        try manifest(["d4", "c3"]).write(to: tags.appendingPathComponent("b"))
        return (tags.appendingPathComponent("a"), tags.appendingPathComponent("b"), blobs)
    }

    static func file(_ id: String, _ path: String, _ bytes: Int64) -> StoredFile { StoredFile(id: id, path: path, bytes: bytes) }

    static let items: [StoredModel] = [
        StoredModel(path: "/m/ollama/manifests/r/library/tiny/a", kind: "ollama", format: "gguf", name: "tiny:a", modelKey: nil, root: "/m", store: "ollama", bytes: 122,
                    files: [file("m1", "/m/ollama/manifests/r/library/tiny/a", 10), file("a1", "/m/ollama/blobs/sha256-a1", 5),
                            file("b2", "/m/ollama/blobs/sha256-b2", 100), file("c3", "/m/ollama/blobs/sha256-c3", 7)]),
        StoredModel(path: "/m/ollama/manifests/r/library/tiny/b", kind: "ollama", format: "gguf", name: "tiny:b", modelKey: nil, root: "/m", store: "ollama", bytes: 67,
                    files: [file("m2", "/m/ollama/manifests/r/library/tiny/b", 10), file("c3", "/m/ollama/blobs/sha256-c3", 7), file("d4", "/m/ollama/blobs/sha256-d4", 50)]),
        StoredModel(path: "/m/hub/models--org--x/snapshots/one", kind: "folder", format: "mlx", name: "x", modelKey: nil, root: "/m", store: "huggingface", bytes: 200,
                    files: [file("h1", "/m/hub/models--org--x/snapshots/one/model.safetensors", 200)]),
        StoredModel(path: "/m/hub/models--org--x/snapshots/two", kind: "folder", format: "mlx", name: "x", modelKey: nil, root: "/m", store: "huggingface", bytes: 230,
                    files: [file("h1", "/m/hub/models--org--x/snapshots/two/model.safetensors", 200), file("h2", "/m/hub/models--org--x/snapshots/two/extra.safetensors", 30)]),
        StoredModel(path: "/m/gguf/x-Q4.gguf", kind: "gguf", format: "gguf", name: "x-Q4", modelKey: nil, root: "/m", store: "folder", bytes: 403,
                    files: [file("g1", "/m/gguf/x-Q4.gguf", 400), file("n1", "/m/gguf/README.md", 3)]),
        StoredModel(path: "/m/mlx/x-4bit", kind: "folder", format: "mlx", name: "x-4bit", modelKey: nil, root: "/m", store: "folder", bytes: 300,
                    files: [file("f1", "/m/mlx/x-4bit/model.safetensors", 300)]),
    ]

    /// Trimmed from a real `convert scan --json` data object.
    static let scanPayload: [String: Any] = [
        "models": [] as [[String: Any]],
        "outputs": [] as [[String: Any]],
        "totals": ["gguf": 0, "bytes": 0],
        "storage": [
            "disk_bytes": 4_733_365_399,
            "roots": [["root": "/m", "bytes": 4_733_365_399, "total_bytes": 5_000_000_000,
                       "other": [["path": "/m/lmstudio/unsorted", "bytes": 266_634_601]]]],
            "stores": [["store": "ollama", "bytes": 4_733_365_399]],
            "items": [[
                "path": "/m/ollama/manifests/registry.ollama.ai/library/llava/latest", "kind": "ollama", "format": "gguf",
                "name": "llava:latest", "model_key": "liuhaotian", "shape": "fa0543a6567a6ca2", "root": "/m", "store": "ollama", "bytes": 4_733_365_399,
                "files": [
                    ["id": "16777232:1295899263", "path": "/m/ollama/manifests/registry.ollama.ai/library/llava/latest", "bytes": 1011],
                    ["id": "16777232:728849122", "path": "/m/ollama/blobs/sha256-170370233dd5c5415250a2ecd5c71586352850729062ccef1496385647293868", "bytes": 4_733_364_388],
                ],
            ]],
        ] as [String: Any],
        "families": [["family_id": "shape:fa0543a6567a6ca2", "name": "llava", "copies": 1,
                      "members": ["/m/ollama/manifests/registry.ollama.ai/library/llava/latest"], "bytes": 4_733_365_399]],
    ]
}
