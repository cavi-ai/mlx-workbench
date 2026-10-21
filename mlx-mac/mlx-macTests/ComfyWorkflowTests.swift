import CoreGraphics
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import mlx_workbench

final class ComfyWorkflowTests: XCTestCase {
    @MainActor
    func testCoordinatorPersistsConditionsBeforeComfySubmission() async throws {
        let fixture = try ComfyHTTPFixture()
        defer { fixture.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONStore<HostedComparisonRecord>(fileURL: root.appendingPathComponent("run.json"))
        let model = HostedModel(hostID: fixture.host.id, modelID: "first.safetensors", name: "first.safetensors", category: "checkpoints")
        let deviceMemory = HostDeviceMemorySnapshot(capturedAt: Date(timeIntervalSince1970: 35), devices: [
            HostDeviceMemory(name: "Shared memory", type: "mps", index: nil, totalBytes: 32_000_000_000, freeBytes: 4_000_000_000)])
        fixture.handler = { request in
            let saved = try XCTUnwrap(store.load().first)
            XCTAssertEqual(saved.conditions?.first?.targetID, model.id)
            XCTAssertEqual(saved.observedTargets?.first?.model, model)
            XCTAssertEqual(saved.conditions?.first?.deviceMemory, deviceMemory, "Device readings must be durable before any workflow request")
            switch request.url!.path {
            case "/object_info": return try self.encoded(self.objectInfo)
            case "/prompt": return Data(#"{"prompt_id":"owned-id","node_errors":{}}"#.utf8)
            case "/history/owned-id": return try self.encoded(["owned-id": self.completedHistory])
            case "/view": return try self.image()
            default: throw URLError(.badURL)
            }
        }
        let inventory = HostInventory(host: fixture.host, models: [model], capturedAt: Date(),
            activity: HostActivity(state: .busy, runningCount: 1, pendingCount: 0, detail: "Reported queue"), deviceMemory: deviceMemory)
        let coordinator = HostedComparisonCoordinator(store: store, outputStore: ComparisonOutputStore(root: root.appendingPathComponent("outputs")),
            readToken: { _ in nil }, freshInventory: { _, _ in inventory }, comfy: fixture.runner, memoryProbe: { nil })
        let done = expectation(description: "Comfy comparison completed")
        let subscription = coordinator.$activeRunID.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        try coordinator.start(targets: [HostedComparisonTarget(host: fixture.host, model: model, capturedAt: Date())],
            promptSet: PromptSet(id: "image", name: "Image", useCase: nil, prompts: [PromptEntry(id: "p", text: "Tree", maxTokens: 32)], origin: .userCreated, mode: .imageGeneration),
            workflow: workflow)
        await fulfillment(of: [done], timeout: 5)
        let record = try XCTUnwrap(store.load().first)
        XCTAssertEqual(record.run.state, .completed)
        XCTAssertEqual(record.submissions.count, 1)
        XCTAssertNil(record.conditions?.first?.systemMemory)
        XCTAssertNotNil(record.conditionsNotice)
        XCTAssertEqual(record.conditions?.first?.deviceMemory, deviceMemory)
        let original = try Data(contentsOf: store.url)
        let reopened = HostedComparisonCoordinator(store: store)
        XCTAssertEqual(reopened.records.first?.conditions?.first?.deviceMemory, deviceMemory)
        XCTAssertEqual(try Data(contentsOf: store.url), original, "Opening history must not backfill current readings")
        subscription.cancel()
    }

    func testBindingsPreserveSamplerSettingsAndNegativePrompt() throws {
        let graph = try json(workflow.submittedGraph(modelID: "second.safetensors", prompt: "A cedar tree"))
        let checkpoint = try XCTUnwrap(graph["4"] as? [String: Any])
        XCTAssertEqual((checkpoint["inputs"] as? [String: Any])?["ckpt_name"] as? String, "second.safetensors")
        XCTAssertEqual(inputs(graph, "6")["text"] as? String, "A cedar tree")
        XCTAssertEqual(inputs(graph, "7")["text"] as? String, "blurry")
        XCTAssertEqual(inputs(graph, "3")["seed"] as? Int, 8566257)
        XCTAssertEqual(inputs(graph, "3")["steps"] as? Int, 20)
        XCTAssertEqual(inputs(graph, "3")["cfg"] as? Int, 8)
        XCTAssertEqual(inputs(graph, "9")["filename_prefix"] as? String, "comparison")
    }

    func testRefusesMalformedGraphsAndBindings() throws {
        let badGraphs = [
            "{\"nodes\": [], \"links\": []}",
            apiGraph.replacingOccurrences(of: "\"4\": {", with: "\"4\": {}, \"4\": {"),
            apiGraph.replacingOccurrences(of: "[\"8\", 0]", with: "[\"missing\", 0]"),
            apiGraph.replacingOccurrences(of: "[\"8\", 0]", with: "[\"8\", -1]"),
            apiGraph.replacingOccurrences(of: "[\"8\", 0]", with: "[\"8\", 0.5]"),
            apiGraph.replacingOccurrences(of: "\"CheckpointLoaderSimple\"", with: "\"OpenAIImageNode\""),
            apiGraph.replacingOccurrences(of: "\"SaveImage\"", with: "\"PreviewImage\""),
            apiGraph.replacingOccurrences(of: "\"samples\":[\"3\",0]", with: "\"samples\":[\"9\",0]")
        ]
        for graph in badGraphs {
            XCTAssertThrowsError(try ComfyWorkflow(apiJSON: graph, checkpointNodeID: "4", promptNodeID: "6", outputNodeID: "9").validated())
        }
        XCTAssertThrowsError(try ComfyWorkflow(apiJSON: apiGraph, checkpointNodeID: "3", promptNodeID: "6", outputNodeID: "9").validated())
        XCTAssertThrowsError(try ComfyWorkflow(apiJSON: apiGraph, checkpointNodeID: "4", promptNodeID: "7", outputNodeID: "9").submittedGraph(modelID: "", prompt: "Tree"))
        XCTAssertThrowsError(try workflow.submittedGraph(modelID: "first.safetensors", prompt: "  "))
    }

    func testWaitsForOwnedSuccessfulCompletionAndPersistsSubmissionBeforePolling() async throws {
        let fixture = try ComfyHTTPFixture()
        defer { fixture.close() }
        var histories = 0
        fixture.handler = { request in
            switch request.url!.path {
            case "/object_info": return try self.encoded(self.objectInfo)
            case "/prompt":
                let body = try self.json(try XCTUnwrap(request.httpBody))
                let graph = try XCTUnwrap(body["prompt"] as? [String: Any])
                XCTAssertEqual(self.inputs(graph, "6")["text"] as? String, "Tree")
                XCTAssertEqual(self.inputs(graph, "3")["seed"] as? Int, 8566257)
                return Data(#"{"prompt_id":"owned-id","number":2,"node_errors":{}}"#.utf8)
            case "/history/owned-id":
                XCTAssertTrue(fixture.submitted)
                histories += 1
                if histories == 1 {
                    return try self.encoded(["other-id": self.completedHistory,
                        "owned-id": ["status": ["completed": false, "status_str": "success"], "outputs": self.outputs]])
                }
                return try self.encoded(["owned-id": self.completedHistory])
            case "/view":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "filename" }?.value, "result.png")
                XCTAssertEqual(query.first { $0.name == "subfolder" }?.value, "comparisons")
                XCTAssertEqual(query.first { $0.name == "type" }?.value, "output")
                return try self.image()
            default: throw URLError(.badURL)
            }
        }
        let output = try await fixture.runner.run(host: fixture.host, token: nil,
            modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { id, graph in
                XCTAssertEqual(id, "owned-id")
                XCTAssertEqual(try self.inputs(self.json(graph), "4")["ckpt_name"] as? String, "first.safetensors")
                fixture.markSubmitted()
            }
        XCTAssertEqual(output.promptID, "owned-id")
        XCTAssertEqual(output.fileExtension, "png")
        XCTAssertTrue(output.queueInclusive)
        XCTAssertGreaterThan(output.durationSeconds, 0)
        XCTAssertEqual(try inputs(json(output.submittedGraph), "6")["text"] as? String, "Tree")
        XCTAssertEqual(histories, 2)
        XCTAssertEqual(fixture.paths, ["/object_info", "/prompt", "/history/owned-id", "/history/owned-id", "/view"])
    }

    func testRefusesUnadvertisedNodesCheckpointOrBindingBeforeSubmission() async throws {
        var missingClass = objectInfo
        missingClass.removeValue(forKey: "KSampler")
        var missingCheckpoint = objectInfo
        missingCheckpoint["CheckpointLoaderSimple"] = ["input": ["required": ["ckpt_name": [["another.safetensors"]]]], "output": ["MODEL", "CLIP", "VAE"]]
        var wrongPromptType = objectInfo
        wrongPromptType["CLIPTextEncode"] = ["input": ["required": ["text": ["INT"], "clip": ["CLIP"]]], "output": ["CONDITIONING"]]
        var apiNode = objectInfo
        apiNode["KSampler"] = ["api_node": true, "input": ["required": [:]], "output": ["LATENT"]]
        var wrongLinkType = objectInfo
        wrongLinkType["VAEDecode"] = ["input": ["required": ["samples": ["LATENT"], "vae": ["VAE"]]], "output": ["AUDIO"]]
        var missingPort = objectInfo
        missingPort["CheckpointLoaderSimple"] = ["input": ["required": ["ckpt_name": [["first.safetensors"]]]], "output": ["MODEL"]]
        for info in [missingClass, missingCheckpoint, wrongPromptType, apiNode, wrongLinkType, missingPort] {
            let fixture = try ComfyHTTPFixture()
            defer { fixture.close() }
            fixture.handler = { _ in try self.encoded(info) }
            do {
                _ = try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { _, _ in XCTFail("Submission must not occur") }
                XCTFail("Invalid server definitions must be refused")
            } catch { XCTAssertEqual(fixture.paths, ["/object_info"]) }
        }
    }

    func testSurfacesFailedExecutionWithoutReadingImages() async throws {
        let fixture = try ComfyHTTPFixture()
        defer { fixture.close() }
        fixture.handler = { request in
            switch request.url!.path {
            case "/object_info": return try self.encoded(self.objectInfo)
            case "/prompt": return Data(#"{"prompt_id":"owned-id","number":0,"node_errors":{}}"#.utf8)
            default: return try self.encoded(["owned-id": ["status": ["completed": false, "status_str": "error", "messages": [["execution_error", ["exception_message": "private filesystem details"]]]], "outputs": self.outputs]])
            }
        }
        do {
            _ = try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { _, _ in fixture.markSubmitted() }
            XCTFail("Execution failure must surface")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("owned-id"))
            XCTAssertFalse(error.localizedDescription.contains("private filesystem"))
            XCTAssertFalse(fixture.paths.contains("/view"))
        }
    }

    func testRefusesOutputOutsideSelectedNodeOrUnsafeImageMetadata() async throws {
        let metadata: [[String: Any]] = [
            ["filename": "../secret.png", "subfolder": "", "type": "output"],
            ["filename": "/tmp/secret.png", "subfolder": "", "type": "output"],
            ["filename": "safe.png", "subfolder": "../private", "type": "output"],
            ["filename": "safe.png", "subfolder": "", "type": "input"],
            ["filename": "safe.txt", "subfolder": "", "type": "output"]
        ]
        for imageMetadata in metadata {
            let fixture = try ComfyHTTPFixture()
            defer { fixture.close() }
            fixture.handler = { request in
                if request.url!.path == "/object_info" { return try self.encoded(self.objectInfo) }
                if request.url!.path == "/prompt" { return Data(#"{"prompt_id":"owned-id","node_errors":{}}"#.utf8) }
                return try self.encoded(["owned-id": ["status": ["completed": true, "status_str": "success"], "outputs": ["9": ["images": [imageMetadata]]]]])
            }
            do {
                _ = try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { _, _ in }
                XCTFail("Unsafe image reference must be refused")
            } catch { XCTAssertFalse(fixture.paths.contains("/view")) }
        }
    }

    func testRejectsInvalidImageBytes() async throws {
        let fixture = try ComfyHTTPFixture()
        defer { fixture.close() }
        fixture.handler = { request in
            switch request.url!.path {
            case "/object_info": return try self.encoded(self.objectInfo)
            case "/prompt": return Data(#"{"prompt_id":"owned-id","node_errors":{}}"#.utf8)
            case "/view": return Data("not an image".utf8)
            default: return try self.encoded(["owned-id": self.completedHistory])
            }
        }
        do {
            _ = try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { _, _ in }
            XCTFail("Non-image output must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("image")) }
    }

    func testNeverUsesImagesFromAnotherOutputNode() async throws {
        let fixture = try ComfyHTTPFixture()
        defer { fixture.close() }
        fixture.handler = { request in
            switch request.url!.path {
            case "/object_info": return try self.encoded(self.objectInfo)
            case "/prompt": return Data(#"{"prompt_id":"owned-id","node_errors":{}}"#.utf8)
            default: return try self.encoded(["owned-id": ["status": ["completed": true, "status_str": "success"], "outputs": ["other-node": ["images": [["filename": "other.png", "subfolder": "", "type": "output"]]]]]])
            }
        }
        do {
            _ = try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { _, _ in }
            XCTFail("Only selected output images can be returned")
        } catch { XCTAssertFalse(fixture.paths.contains("/view")) }
    }

    func testSubmissionStorageFailureRetainsOwnedPromptIDInError() async throws {
        let fixture = try ComfyHTTPFixture()
        defer { fixture.close() }
        fixture.handler = { request in
            request.url!.path == "/object_info" ? try self.encoded(self.objectInfo) : Data(#"{"prompt_id":"owned-id","node_errors":{}}"#.utf8)
        }
        do {
            _ = try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { _, _ in throw CocoaError(.fileWriteNoPermission) }
            XCTFail("Storage failure must surface")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("owned-id"))
            XCTAssertEqual(fixture.paths, ["/object_info", "/prompt"])
        }
    }

    func testTimeoutObservesOnlyOwnedPromptAndDoesNotMutateHost() async throws {
        let fixture = try ComfyHTTPFixture(timeout: 0.015)
        defer { fixture.close() }
        fixture.handler = { request in
            if request.url!.path == "/object_info" { return try self.encoded(self.objectInfo) }
            if request.url!.path == "/prompt" { return Data(#"{"prompt_id":"owned-id","node_errors":{}}"#.utf8) }
            return try self.encoded(["other-id": self.completedHistory])
        }
        do {
            _ = try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { _, _ in fixture.markSubmitted() }
            XCTFail("Missing owned history must time out")
        } catch {
            XCTAssertTrue(fixture.submitted)
            XCTAssertTrue(error.localizedDescription.contains("owned-id"))
            XCTAssertTrue(fixture.paths.allSatisfy { ["/object_info", "/prompt", "/history/owned-id"].contains($0) })
        }
    }

    func testCancellationPreservesSubmissionAndDoesNotInterruptOtherJobs() async throws {
        let fixture = try ComfyHTTPFixture()
        defer { fixture.close() }
        let saved = expectation(description: "Submission persisted")
        fixture.handler = { request in
            if request.url!.path == "/object_info" { return try self.encoded(self.objectInfo) }
            if request.url!.path == "/prompt" { return Data(#"{"prompt_id":"owned-id","node_errors":{}}"#.utf8) }
            return Data("{}".utf8)
        }
        let task = Task {
            try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { id, graph in
                XCTAssertEqual(id, "owned-id")
                XCTAssertFalse(graph.isEmpty)
                fixture.markSubmitted()
                saved.fulfill()
            }
        }
        await fulfillment(of: [saved], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertTrue(fixture.submitted)
        XCTAssertTrue(fixture.paths.allSatisfy { ["/object_info", "/prompt", "/history/owned-id"].contains($0) })
    }

    private var workflow: ComfyWorkflow { ComfyWorkflow(apiJSON: apiGraph, checkpointNodeID: "4", promptNodeID: "6", outputNodeID: "9") }
    private var apiGraph: String { #"""
    {
      "3": {"class_type":"KSampler","inputs":{"cfg":8,"denoise":1,"latent_image":["5",0],"model":["4",0],"negative":["7",0],"positive":["6",0],"sampler_name":"euler","scheduler":"normal","seed":8566257,"steps":20}},
      "4": {"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"first.safetensors"}},
      "5": {"class_type":"EmptyLatentImage","inputs":{"batch_size":1,"height":512,"width":512}},
      "6": {"class_type":"CLIPTextEncode","inputs":{"clip":["4",1],"text":"Original"}},
      "7": {"class_type":"CLIPTextEncode","inputs":{"clip":["4",1],"text":"blurry"}},
      "8": {"class_type":"VAEDecode","inputs":{"samples":["3",0],"vae":["4",2]}},
      "9": {"class_type":"SaveImage","inputs":{"filename_prefix":"comparison","images":["8", 0]}}
    }
    """# }

    private var objectInfo: [String: Any] {
        [
            "CheckpointLoaderSimple": ["input": ["required": ["ckpt_name": [["first.safetensors", "second.safetensors"]]]], "output": ["MODEL", "CLIP", "VAE"]],
            "CLIPTextEncode": ["input": ["required": ["text": ["STRING", ["multiline": true]], "clip": ["CLIP"]]], "output": ["CONDITIONING"]],
            "KSampler": ["input": ["required": ["model": ["MODEL"], "positive": ["CONDITIONING"], "negative": ["CONDITIONING"], "latent_image": ["LATENT"], "seed": ["INT"], "steps": ["INT"], "cfg": ["FLOAT"], "denoise": ["FLOAT"], "sampler_name": [["euler"]], "scheduler": [["normal"]]]], "output": ["LATENT"]],
            "EmptyLatentImage": ["input": ["required": ["batch_size": ["INT"], "width": ["INT"], "height": ["INT"]]], "output": ["LATENT"]],
            "VAEDecode": ["input": ["required": ["samples": ["LATENT"], "vae": ["VAE"]]], "output": ["IMAGE"]],
            "SaveImage": ["input": ["required": ["images": ["IMAGE"], "filename_prefix": ["STRING"]]], "output": [], "output_node": true]
        ]
    }
    private var outputs: [String: Any] { ["9": ["images": [["filename": "result.png", "subfolder": "comparisons", "type": "output"]]]] }
    private var completedHistory: [String: Any] { ["status": ["completed": true, "status_str": "success", "messages": []], "outputs": outputs] }
    private func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func json(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func inputs(_ graph: [String: Any], _ id: String) -> [String: Any] { (graph[id] as? [String: Any])?["inputs"] as? [String: Any] ?? [:] }
    private func image() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class ComfyHTTPFixture: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var nextPort = 32000
    private static var registry: [Int: ComfyHTTPFixture] = [:]
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    private var didSubmit = false
    var handler: ((URLRequest) throws -> Data)?
    let host: ModelHost
    let session: URLSession
    let runner: ComfyWorkflowRunner

    init(timeout: TimeInterval = 2) throws {
        Self.registryLock.lock()
        let port = Self.nextPort
        Self.nextPort += 1
        Self.registryLock.unlock()
        host = ModelHost(id: UUID(), name: "ComfyUI test", provider: .comfyUI, baseURL: "http://127.0.0.1:\(port)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ComfyTestURLProtocol.self]
        session = URLSession(configuration: config)
        runner = ComfyWorkflowRunner(http: HostHTTPClient(session: session), pollIntervalNanoseconds: 1_000_000, timeoutSeconds: timeout)
        Self.registryLock.lock()
        Self.registry[port] = self
        Self.registryLock.unlock()
    }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return recordedPaths }
    var submitted: Bool { lock.lock(); defer { lock.unlock() }; return didSubmit }
    func markSubmitted() { lock.lock(); didSubmit = true; lock.unlock() }
    func close() {
        session.invalidateAndCancel()
        Self.registryLock.lock()
        Self.registry = Self.registry.filter { $0.value !== self }
        Self.registryLock.unlock()
    }
    static func response(_ request: URLRequest) throws -> Data {
        registryLock.lock()
        let fixture = registry[request.url?.port ?? -1]
        registryLock.unlock()
        guard let fixture else { throw URLError(.cannotFindHost) }
        fixture.lock.lock()
        fixture.recordedPaths.append(request.url!.path)
        fixture.lock.unlock()
        return try fixture.handler!(request)
    }
}

private final class ComfyTestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var materialized = request
            if materialized.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                materialized.httpBody = data
            }
            let data = try ComfyHTTPFixture.response(materialized)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
