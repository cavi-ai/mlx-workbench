import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class IntakeCoordinatorTests: XCTestCase {
    func testLinkSniffing() {
        for text in ["https://huggingface.co/org/name", "hf.co/org/name", "  org/name  ", "https://www.huggingface.co/org/name/tree/main"] {
            XCTAssertTrue(IntakeCoordinator.looksLikeHFLink(text), text)
        }
        for text in [nil, "", "hello world", "https://github.com/org/name", "a/b/c", String(repeating: "x", count: 3000)] {
            XCTAssertFalse(IntakeCoordinator.looksLikeHFLink(text), text ?? "nil")
        }
    }

    func testOpenResetsStateAndKeepsText() async throws {
        let api = IntakeAPI.stub(resolve: { _ in try Self.resolution(verdict: "convertible", backend: "mlx-lm") })
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        intake.open(with: "  org/name  ")
        XCTAssertEqual(intake.sourceText, "org/name")
        XCTAssertNil(intake.resolution)
        XCTAssertNil(intake.draft)
        XCTAssertEqual(intake.logTail, [])
        for _ in 0..<200 where intake.resolution == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(intake.resolution?.verdict, .convertible)
        XCTAssertEqual(intake.sourceText, "org/name")
        XCTAssertNil(intake.draft)
        XCTAssertEqual(intake.logTail, [])
    }

    func testUnsupportedResolutionRunsAnalysis() async throws {
        var analyzed = 0
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "unsupported", backend: nil) },
            portAnalysis: { _ in analyzed += 1; return try Self.analysis() }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        intake.sourceText = "Edge0/Audio8-ASR-Infinite"
        await intake.resolve()
        XCTAssertEqual(intake.resolution?.verdict, .unsupported)
        XCTAssertEqual(analyzed, 1)
        XCTAssertNotNil(intake.analysis)
        XCTAssertEqual(intake.activity, .idle)
    }

    func testInstallPollsUntilInstalledThenReResolves() async throws {
        var states: [BackendState] = [.installing, .installed]
        var resolves = 0
        let api = IntakeAPI.stub(
            resolve: { _ in resolves += 1; return try Self.resolution(verdict: resolves == 1 ? "convertible_after_install" : "convertible", backend: "mlx-audio") },
            backends: { BackendList(schema: "backends/1", root: "/b", backends: [Self.entry(states.removeFirst())]) },
            installPreview: { _ in ["preview_hash": "h"] },
            installStart: { _, hash in XCTAssertEqual(hash, "h"); return ["status": "started"] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 5)
        intake.sourceText = "openai/whisper-tiny"
        await intake.resolve()
        await intake.installBackend()
        XCTAssertEqual(resolves, 2)
        XCTAssertEqual(intake.resolution?.verdict, .convertible)
        XCTAssertEqual(intake.activity, .idle)
    }

    func testFailedInstallSurfacesTheLog() async throws {
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "convertible_after_install", backend: "mlx-audio") },
            backends: { BackendList(schema: "backends/1", root: "/b", backends: [Self.entry(.failed, log: "/logs/mlx-audio.log")]) },
            installPreview: { _ in ["preview_hash": "h"] },
            installStart: { _, _ in [:] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 5)
        intake.sourceText = "openai/whisper-tiny"
        await intake.resolve()
        await intake.installBackend()
        guard case .failed(let message) = intake.activity else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("/logs/mlx-audio.log"))
    }

    func testDownloadReturnsTheMarkerPath() async throws {
        var polls = 0
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "convertible", backend: "mlx-lm") },
            fetchPreview: { _ in ["preview_hash": "f"] },
            fetchStart: { _, _ in [:] },
            fetchStatus: {
                polls += 1
                return [FetchJob(receipt: "r", repo: "openai/whisper-tiny", revision: "main", file: nil, subfolder: nil, localDir: nil, state: polls < 2 ? "running" : "done", path: "/hf/snap", logPath: nil, startedAt: nil, completedAt: nil)]
            }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 5)
        intake.sourceText = "openai/whisper-tiny"
        await intake.resolve()
        let path = await intake.download(localDir: nil)
        XCTAssertEqual(path, "/hf/snap")
        XCTAssertEqual(intake.downloadedPath, "/hf/snap")
    }

    /// A subfolder checkpoint downloads as org/name/folder and waits for that folder's job, not the root's.
    func testSubfolderDownloadNamesTheFolderAndWaitsForItsJob() async throws {
        var requested: IntakeFetchRequest?
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "convertible", backend: "mlx-embeddings", subfolder: "multilingual") },
            fetchPreview: { request in requested = request; return ["preview_hash": "f"] },
            fetchStart: { _, _ in [:] },
            fetchStatus: {
                [FetchJob(receipt: "root", repo: "openai/whisper-tiny", revision: "main", file: nil, subfolder: nil, localDir: nil, state: "done", path: "/hf/root", logPath: nil, startedAt: nil, completedAt: nil),
                 FetchJob(receipt: "ml", repo: "openai/whisper-tiny", revision: "main", file: nil, subfolder: "multilingual", localDir: nil, state: "done", path: "/hf/snap", logPath: nil, startedAt: nil, completedAt: nil)]
            }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 5)
        intake.sourceText = "openai/whisper-tiny/multilingual"
        await intake.resolve()
        let path = await intake.download(localDir: nil)
        XCTAssertEqual(requested?.source, "openai/whisper-tiny/multilingual")
        XCTAssertEqual(path, "/hf/snap")
    }

    func testDraftNeedsARunningServerAndUsesItsIdentity() async throws {
        var drafted: (String, String, String)?
        let server = ServerInfo(repo: "Qwen/Qwen3-8B-MLX", path: nil, runtime: "mlx-lm", port: 8090, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: nil)
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "unsupported", backend: nil) },
            portAnalysis: { _ in try Self.analysis() },
            portPlan: { source, endpoint, model in
                drafted = (source, endpoint, model)
                return PortPlanResult(schema: "port-plan/1", path: "/plans/x.md", model: model, endpoint: endpoint, analysisSha256: "s", promptChars: 1, truncated: false, bytes: 1)
            },
            serveStatus: { [server] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        intake.sourceText = "Edge0/Audio8-ASR-Infinite"
        await intake.resolve()
        XCTAssertEqual(intake.draftServer?.port, 8090)
        await intake.draftPlan()
        XCTAssertEqual(drafted?.1, "http://127.0.0.1:8090")
        XCTAssertEqual(drafted?.2, "Qwen/Qwen3-8B-MLX")
        XCTAssertEqual(intake.draft?.path, "/plans/x.md")
    }

    func testNoRunningServerMeansNoDraft() async throws {
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "unsupported", backend: nil) },
            portAnalysis: { _ in try Self.analysis() },
            serveStatus: { [] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        intake.sourceText = "Edge0/Audio8-ASR-Infinite"
        await intake.resolve()
        XCTAssertNil(intake.draftServer)
        await intake.draftPlan()
        XCTAssertNil(intake.draft)
    }

    static func resolution(verdict: String, backend: String?, subfolder: String? = nil) throws -> IntakeResolution {
        let json = """
        {"schema":"intake/1","source":{"input":"x","repo":"openai/whisper-tiny","revision":"main","file":null,
         "subfolder":\(subfolder.map { "\"\($0)\"" } ?? "null"),"url":"u"},
         "verdict":"\(verdict)","reasons":[],"backend":\(backend.map { "\"\($0)\"" } ?? "null"),"backend_installed":\(verdict == "convertible"),
         "model_type":"whisper","components":[],"task":null,"custom_code":false,"gated":false,"library_name":null,"pipeline_tag":null,
         "transformers_version":null,"bytes":0,"files":{"safetensors":1,"gguf":[],"python":[]},"warnings":[]}
        """
        return try JSONDecoder().decode(IntakeResolution.self, from: Data(json.utf8))
    }

    static func analysis() throws -> PortAnalysis {
        let json = """
        {"schema":"port-analysis/1","source":{"input":"x","repo":"o/n","revision":"main","file":null,"url":"u"},"model_type":"t",
         "architectures":[],"processor_class":null,"transformers_version":null,"components":[],
         "weights":{"index_available":false,"prefixes":[],"extra_files":[]},"code":{"files":[],"truncated":false},"missing":[],"warnings":[]}
        """
        return try JSONDecoder().decode(PortAnalysis.self, from: Data(json.utf8))
    }

    static func entry(_ state: BackendState, log: String? = nil) -> BackendEntry {
        BackendEntry(id: "mlx-audio", version: "0.5.7", builtin: false, state: state, categories: ["speech_to_text"], modelTypes: 30, registrySource: "snapshot", target: "/b/mlx-audio", logPath: log, startedAt: nil, completedAt: nil)
    }
}
