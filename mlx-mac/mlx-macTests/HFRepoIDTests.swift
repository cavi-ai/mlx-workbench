import Foundation
import XCTest

@testable import mlx_workbench

final class HFRepoIDTests: XCTestCase {
    func testSnapshotPathMapsToRepoID() {
        let path = "/Users/x/.cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots/abc123"
        XCTAssertEqual(HFRepoID.forPath(path), "mlx-community/Qwen3-0.6B-4bit")
        XCTAssertEqual(HFRepoID.serveIdentity(for: path), path)
    }

    func testBlobPathMapsToRepoID() {
        let path = "/Users/x/.cache/huggingface/hub/models--beshkenadze--moondream3-preview-mlx-4bit/blobs/sha"
        XCTAssertEqual(HFRepoID.forPath(path), "beshkenadze/moondream3-preview-mlx-4bit")
    }

    func testServingIdentityDistinguishesLocalCacheRevisionsAndAcceptsLegacyRepoReceipts() {
        let a = "/cache/models--org--model/snapshots/first"
        let b = "/cache/models--org--model/snapshots/second"
        XCTAssertFalse(HFRepoID.matches(a, b))
        XCTAssertTrue(HFRepoID.matches(a, a))
        XCTAssertTrue(HFRepoID.matches("org/model", a))
        XCTAssertFalse(HFRepoID.matches("other/model", a))
    }

    func testResolvedPathsAreReusedUntilTheLibraryIsRescanned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hfrepoid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        let link = root.appendingPathComponent("model")
        for directory in [first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let resolvedFirst = first.resolvingSymlinksInPath().path
        XCTAssertEqual(HFRepoID.serveIdentity(for: link.path), resolvedFirst)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        XCTAssertEqual(HFRepoID.serveIdentity(for: link.path), resolvedFirst)
        HFRepoID.forgetResolvedPaths()
        XCTAssertEqual(HFRepoID.serveIdentity(for: link.path), second.resolvingSymlinksInPath().path)
    }

    func testOccupancyProtectsTheSameLibraryPathsAsPairwiseMatching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("occupancy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); HFRepoID.forgetResolvedPaths() }
        let snapshots = root.appendingPathComponent("hub/models--org--model/snapshots", isDirectory: true)
        let first = snapshots.appendingPathComponent("first", isDirectory: true)
        let second = snapshots.appendingPathComponent("second", isDirectory: true)
        let plain = root.appendingPathComponent("plain/model", isDirectory: true)
        let alias = root.appendingPathComponent("alias")
        for directory in [first, second, plain] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: plain)
        let library = [first.path, second.path, plain.path, alias.path, "org/model", "other/model"]
        let claimSets: [[String]] = [["org/model"], [first.path], [alias.path], ["other/model", second.path], [], ["missing/repo"]]
        for claimed in claimSets {
            var occupancy = ModelOccupancy(libraryPaths: library)
            occupancy.add(claimed, for: .preference)
            let pairwise = Set(claimed).union(library.filter { path in claimed.contains { HFRepoID.matches($0, path) } })
            XCTAssertEqual(occupancy.protectedPaths, pairwise, "\(claimed)")
        }
    }

    func testPathOnAnAbsentVolumeStillMapsToRepoID() {
        let path = "/Volumes/NoSuchVolume-\(UUID().uuidString)/hub/models--org--model/snapshots/rev"
        XCTAssertEqual(HFRepoID.forPath(path), "org/model")
    }

    func testForPathNeverStatsTheDisk() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/Models/HFRepoID.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let forPath = try XCTUnwrap(text.range(of: "static func forPath"))
        let body = text[forPath.lowerBound...].prefix(400)
        XCTAssertFalse(body.contains("URL(fileURLWithPath:"))
    }

    func testPathOutsideCachePassesThrough() {
        let path = "/models/mlx/qwen3-8b-mlx"
        XCTAssertNil(HFRepoID.forPath(path))
        XCTAssertEqual(HFRepoID.serveIdentity(for: path), path)
    }

    func testRepoIDIsItsOwnIdentity() {
        XCTAssertEqual(HFRepoID.serveIdentity(for: "mlx-community/Qwen3-0.6B-4bit"), "mlx-community/Qwen3-0.6B-4bit")
    }

    func testMalformedMarkerRejected() {
        XCTAssertNil(HFRepoID.forPath("/tmp/models--/snapshots/x"))
        XCTAssertNil(HFRepoID.forPath("/tmp/models----org/snapshots/x"))
    }

    // MARK: - Serve argv selection (WorkbenchAPI boundary)

    func testHFCachePathServesExactLocalSnapshot() {
        let path = "/Users/x/.cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots/abc123"
        XCTAssertEqual(
            WorkbenchAPI.serveModelArguments(for: path),
            ["--path", path]
        )
    }

    func testLocalPathServesByPath() {
        XCTAssertEqual(
            WorkbenchAPI.serveModelArguments(for: "/models/mlx/qwen3-8b-mlx"),
            ["--path", "/models/mlx/qwen3-8b-mlx"]
        )
        XCTAssertEqual(
            WorkbenchAPI.serveModelArguments(for: "~/models/mlx/qwen3-8b-mlx"),
            ["--path", "~/models/mlx/qwen3-8b-mlx"]
        )
    }

    func testBareRepoIDServesByRepo() {
        XCTAssertEqual(
            WorkbenchAPI.serveModelArguments(for: "mlx-community/Qwen3-0.6B-4bit"),
            ["--repo", "mlx-community/Qwen3-0.6B-4bit"]
        )
    }

    // MARK: - ServerInfo identity

    func testServerInfoModelIdentityPrefersRepoThenPath() {
        XCTAssertEqual(ServerInfo(repo: "org/model", path: "/models/x").modelIdentity, "org/model")
        XCTAssertEqual(ServerInfo(path: "/models/x").modelIdentity, "/models/x")
        XCTAssertEqual(ServerInfo().modelIdentity, "")
    }

    func testServersDecodesPathServes() {
        let data: [String: Any] = [
            "servers": [[
                "path": "/models/mlx/qwen3-8b-mlx",
                "runtime": "mlx_lm",
                "port": 8080,
                "state": "running",
            ]]
        ]
        let servers = WorkbenchAPI.servers(from: data)
        XCTAssertEqual(servers?.first?.path, "/models/mlx/qwen3-8b-mlx")
        XCTAssertEqual(servers?.first?.modelIdentity, "/models/mlx/qwen3-8b-mlx")
    }
}
