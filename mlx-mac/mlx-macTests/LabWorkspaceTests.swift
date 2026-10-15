import XCTest
import AppKit
import SwiftUI
@testable import mlx_workbench

final class LabWorkspaceTests: XCTestCase {
    @MainActor
    func testStudiesViewReadsAnIsolatedRealWorkspaceWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let agent = environment["MLX_LAB_TEST_AGENT"] else {
            throw XCTSkip("Set MLX_LAB_TEST_AGENT to exercise the study page with the shared engine.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studies-view-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "studies-view-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "mlx-workbench.lab-store")
        let lab = LabCoordinator(api: WorkbenchAPI(cli: CLIProcess(), agentPath: agent), defaults: defaults)
        let installer = RuntimeInstaller()
        for width: CGFloat in [1190, 814] {
            let host = NSHostingView(rootView: StudiesView(lab: lab, installer: installer, agentPath: agent)
                .environment(\.isRouteActive, false).frame(width: width, height: 900)
                .background(WorkbenchColor.canvas).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            if width == 1190 {
                XCTAssertNil(lab.snapshot.history)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("experiments.sqlite3").path))
            }
            lab.error = "Refresh pending"
            host.rootView = StudiesView(lab: lab, installer: installer, agentPath: agent)
                .environment(\.isRouteActive, true).frame(width: width, height: 900)
                .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            for _ in 0..<200 where lab.snapshot.history == nil || lab.isRefreshing || lab.error != nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertNil(lab.error)
            XCTAssertEqual(lab.snapshot.history?.items.count, 0)
            XCTAssertEqual(lab.snapshot.queue?.count, 0)
            XCTAssertNil(lab.runningJobID)
            XCTAssertEqual(installer.state, .idle)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("experiments.sqlite3").path))
            host.layoutSubtreeIfNeeded()
            if let folder = environment["MLX_WORKBENCH_COMPARISON_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("studies-\(Int(width)).png"))
            }
        }
    }

    func testRequestPreservesFrozenRecipeAndChangesOneVariable() throws {
        let baseline = try JSONDecoder().decode(LabValue.self, from: Data(#"{"prompt":"A kite","seed":42,"inference_steps":4,"model_revision":"frozen"}"#.utf8))
        let draft = LabDraft(baseline: baseline, variablePath: "inference_steps", alternateValue: .integer(8))
        let request = LabRequest(operation: "preview", draft: draft)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let emitted = try XCTUnwrap(object["draft"] as? [String: Any])
        XCTAssertEqual(emitted["variable_path"] as? String, "inference_steps")
        XCTAssertEqual((emitted["baseline"] as? [String: Any])?["model_revision"] as? String, "frozen")
        XCTAssertEqual(emitted["alternate_value"] as? Int, 8)
    }

    func testSealedSnapshotDecodesWithoutCanonicalMetadata() throws {
        let data = Data(#"{"history":{"items":[{"id":"exp_one","sealed":true,"states":["queued","queued"],"evidence_completeness":"pending"}]},"queue":[{"id":"job_one","experiment_id":"exp_one","state":"queued","error":null}]}"#.utf8)
        let response = try JSONDecoder().decode(LabResponse.self, from: data)
        XCTAssertEqual(response.history?.items.first?.id, "exp_one")
        XCTAssertTrue(try XCTUnwrap(response.history?.items.first?.sealed))
        XCTAssertEqual(response.queue?.first?.state, "queued")
    }

    func testLiveAgentWorkspaceSnapshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let agent = environment["MLX_LAB_TEST_AGENT"] else {
            throw XCTSkip("Set MLX_LAB_TEST_AGENT to exercise the shared engine.")
        }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: store) }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent)
        let response = try await api.labWorkspace(request: LabRequest(operation: "snapshot"),
                                                  store: store, reviewer: "native-contract")
        XCTAssertEqual(response.history?.items.count, 0)
        XCTAssertEqual(response.queue?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent("experiments.sqlite3").path))
    }
}
