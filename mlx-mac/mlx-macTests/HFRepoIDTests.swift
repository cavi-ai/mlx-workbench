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
