import Foundation
import XCTest

@testable import mlx_workbench

final class HFRepoIDTests: XCTestCase {
    func testSnapshotPathMapsToRepoID() {
        let path = "/Users/x/.cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots/abc123"
        XCTAssertEqual(HFRepoID.forPath(path), "mlx-community/Qwen3-0.6B-4bit")
        XCTAssertEqual(HFRepoID.serveIdentity(for: path), "mlx-community/Qwen3-0.6B-4bit")
    }

    func testBlobPathMapsToRepoID() {
        let path = "/Users/x/.cache/huggingface/hub/models--beshkenadze--moondream3-preview-mlx-4bit/blobs/sha"
        XCTAssertEqual(HFRepoID.forPath(path), "beshkenadze/moondream3-preview-mlx-4bit")
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
}
