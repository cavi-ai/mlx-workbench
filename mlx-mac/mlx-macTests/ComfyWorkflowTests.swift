import CoreGraphics
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import mlx_workbench

final class ComfyWorkflowTests: XCTestCase {
    @MainActor
    func testFreshNonCheckpointMetadataPreventsComfyWorkflowRequests() async throws {
        let fixture = try ComfyHTTPFixture()
        defer { fixture.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONStore<HostedComparisonRecord>(fileURL: root.appendingPathComponent("run.json"))
        let selected = HostedModel(hostID: fixture.host.id, modelID: "first.safetensors", name: "first.safetensors", category: "checkpoints")
        var changed = selected; changed.category = "loras"
        fixture.handler = { _ in XCTFail("An incompatible checkpoint must not reach the workflow API"); throw URLError(.badURL) }
        let inventory = HostInventory(host: fixture.host, models: [changed], capturedAt: Date())
        let coordinator = HostedComparisonCoordinator(store: store, readToken: { _ in nil }, freshInventory: { _, _ in inventory },
            comfy: fixture.runner, memoryProbe: { nil })
        let done = expectation(description: "Incompatible image lane rejected")
        let subscription = coordinator.$activeRunID.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        try await coordinator.start(targets: [HostedComparisonTarget(host: fixture.host, model: selected, capturedAt: Date())],
            promptSet: PromptSet(id: "image", name: "Image", useCase: nil, prompts: [PromptEntry(id: "p", text: "Tree", maxTokens: 32)], origin: .userCreated, mode: .imageGeneration),
            workflow: workflow)
        await fulfillment(of: [done], timeout: 5)
        let record = try XCTUnwrap(store.load().first)
        XCTAssertEqual(record.run.state, .failed)
        XCTAssertNotNil(record.run.results.first?.error)
        XCTAssertTrue(record.submissions.isEmpty)
        XCTAssertEqual(record.conditions, [])
        subscription.cancel()
    }

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
        try await coordinator.start(targets: [HostedComparisonTarget(host: fixture.host, model: model, capturedAt: Date())],
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

    func testBackwardCompatibleFourFieldCodableDecoding() throws {
        let legacyJSON = #"""
        {
          "apiJSON": "{\"4\":{\"class_type\":\"CheckpointLoaderSimple\",\"inputs\":{\"ckpt_name\":\"a.safetensors\"}}}",
          "checkpointNodeID": "4",
          "promptNodeID": "6",
          "outputNodeID": "9"
        }
        """#
        let decoded = try JSONDecoder().decode(ComfyWorkflow.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.checkpointNodeID, "4")
        XCTAssertEqual(decoded.promptNodeID, "6")
        XCTAssertEqual(decoded.outputNodeID, "9")
        XCTAssertNil(decoded.negativePromptNodeID)
        XCTAssertNil(decoded.samplerNodeID)
        XCTAssertNil(decoded.latentNodeID)
    }

    func testKSamplerTypedOverridesAndBoundsChecking() throws {
        let bound = ComfyWorkflow(
            apiJSON: apiGraph,
            checkpointNodeID: "4",
            promptNodeID: "6",
            outputNodeID: "9",
            negativePromptNodeID: "7",
            samplerNodeID: "3",
            latentNodeID: "5"
        )
        let overrides = ComfyWorkflowOverrides(
            negativePrompt: "low quality, artifacts",
            seed: 42,
            steps: 30,
            cfg: 6.5,
            width: 1024,
            height: 768
        )
        let graph = try json(bound.submittedGraph(modelID: "second.safetensors", prompt: "A cedar tree", overrides: overrides))
        XCTAssertEqual(inputs(graph, "7")["text"] as? String, "low quality, artifacts")
        XCTAssertEqual(inputs(graph, "3")["seed"] as? Int, 42)
        XCTAssertEqual(inputs(graph, "3")["steps"] as? Int, 30)
        XCTAssertEqual(inputs(graph, "3")["cfg"] as? Double, 6.5)
        XCTAssertEqual(inputs(graph, "5")["width"] as? Int, 1024)
        XCTAssertEqual(inputs(graph, "5")["height"] as? Int, 768)

        // Out-of-bounds overrides must throw
        let invalidOverrides: [ComfyWorkflowOverrides] = [
            ComfyWorkflowOverrides(seed: -1),
            ComfyWorkflowOverrides(steps: 0),
            ComfyWorkflowOverrides(steps: 1001),
            ComfyWorkflowOverrides(cfg: -0.1),
            ComfyWorkflowOverrides(cfg: 100.1),
            ComfyWorkflowOverrides(cfg: .nan),
            ComfyWorkflowOverrides(cfg: .infinity),
            ComfyWorkflowOverrides(width: 32),
            ComfyWorkflowOverrides(width: 20_000),
            ComfyWorkflowOverrides(height: 32),
            ComfyWorkflowOverrides(height: 20_000),
            ComfyWorkflowOverrides(width: 16_000, height: 16_000)
        ]
        for bad in invalidOverrides {
            XCTAssertThrowsError(try bound.submittedGraph(modelID: "first.safetensors", prompt: "Tree", overrides: bad))
        }

        // Overrides without corresponding optional node bindings must throw
        XCTAssertThrowsError(try workflow.submittedGraph(modelID: "first.safetensors", prompt: "Tree", overrides: ComfyWorkflowOverrides(negativePrompt: "blur")))
        XCTAssertThrowsError(try workflow.submittedGraph(modelID: "first.safetensors", prompt: "Tree", overrides: ComfyWorkflowOverrides(seed: 1)))
        XCTAssertThrowsError(try workflow.submittedGraph(modelID: "first.safetensors", prompt: "Tree", overrides: ComfyWorkflowOverrides(width: 1024)))
    }

    func testFluxAndLoraModelOnlyWorkflowValidatesAndSubmitsWithOverrides() async throws {
        let fluxGraph = #"""
        {
          "1": {"class_type":"UNETLoader","inputs":{"unet_name":"flux-dev.safetensors","weight_dtype":"default"}},
          "2": {"class_type":"DualCLIPLoader","inputs":{"clip_name1":"t5xxl.safetensors","clip_name2":"clip_l.safetensors","type":"flux"}},
          "3": {"class_type":"LoraLoaderModelOnly","inputs":{"lora_name":"style.safetensors","model":["1",0],"strength_model":0.8}},
          "4": {"class_type":"CLIPTextEncode","inputs":{"clip":["2",0],"text":"Original"}},
          "5": {"class_type":"BasicGuider","inputs":{"conditioning":["4",0],"model":["3",0]}},
          "6": {"class_type":"RandomNoise","inputs":{"noise_seed":123}},
          "7": {"class_type":"KSamplerSelect","inputs":{"sampler_name":"euler"}},
          "8": {"class_type":"BasicScheduler","inputs":{"denoise":1.0,"model":["3",0],"scheduler":"simple","steps":20}},
          "9": {"class_type":"EmptySD3LatentImage","inputs":{"batch_size":1,"height":1024,"width":1024}},
          "10": {"class_type":"SamplerCustomAdvanced","inputs":{"guider":["5",0],"latent_image":["9",0],"noise":["6",0],"sampler":["7",0],"sigmas":["8",0]}},
          "11": {"class_type":"VAELoader","inputs":{"vae_name":"ae.safetensors"}},
          "12": {"class_type":"VAEDecode","inputs":{"samples":["10",0],"vae":["11",0]}},
          "13": {"class_type":"SaveImage","inputs":{"filename_prefix":"flux","images":["12",0]}}
        }
        """#
        let fluxWorkflow = ComfyWorkflow(
            apiJSON: fluxGraph,
            checkpointNodeID: "1",
            promptNodeID: "4",
            outputNodeID: "13",
            samplerNodeID: "10",
            latentNodeID: "9"
        )
        let fluxObjectInfo: [String: Any] = [
            "UNETLoader": ["input": ["required": ["unet_name": [["flux-dev.safetensors", "flux-schnell.safetensors"]], "weight_dtype": [["default"]]]], "output": ["MODEL"]],
            "DualCLIPLoader": ["input": ["required": ["clip_name1": [["t5xxl.safetensors"]], "clip_name2": [["clip_l.safetensors"]], "type": [["flux"]]]], "output": ["CLIP"]],
            "LoraLoaderModelOnly": ["input": ["required": ["model": ["MODEL"], "lora_name": [["style.safetensors"]], "strength_model": ["FLOAT"]]], "output": ["MODEL"]],
            "CLIPTextEncode": ["input": ["required": ["text": ["STRING"], "clip": ["CLIP"]]], "output": ["CONDITIONING"]],
            "BasicGuider": ["input": ["required": ["model": ["MODEL"], "conditioning": ["CONDITIONING"]]], "output": ["GUIDER"]],
            "RandomNoise": ["input": ["required": ["noise_seed": ["INT"]]], "output": ["NOISE"]],
            "KSamplerSelect": ["input": ["required": ["sampler_name": [["euler"]]]], "output": ["SAMPLER"]],
            "BasicScheduler": ["input": ["required": ["model": ["MODEL"], "scheduler": [["simple"]], "steps": ["INT"], "denoise": ["FLOAT"]]], "output": ["SIGMAS"]],
            "EmptySD3LatentImage": ["input": ["required": ["width": ["INT"], "height": ["INT"], "batch_size": ["INT"]]], "output": ["LATENT"]],
            "SamplerCustomAdvanced": ["input": ["required": ["noise": ["NOISE"], "guider": ["GUIDER"], "sampler": ["SAMPLER"], "sigmas": ["SIGMAS"], "latent_image": ["LATENT"]]], "output": ["LATENT", "LATENT"]],
            "VAELoader": ["input": ["required": ["vae_name": [["ae.safetensors"]]]], "output": ["VAE"]],
            "VAEDecode": ["input": ["required": ["samples": ["LATENT"], "vae": ["VAE"]]], "output": ["IMAGE"]],
            "SaveImage": ["input": ["required": ["images": ["IMAGE"], "filename_prefix": ["STRING"]]], "output": [], "output_node": true]
        ]

        let fixture = try ComfyHTTPFixture()
        defer { fixture.close() }
        fixture.handler = { request in
            switch request.url!.path {
            case "/object_info": return try self.encoded(fluxObjectInfo)
            case "/prompt":
                let body = try self.json(try XCTUnwrap(request.httpBody))
                let graph = try XCTUnwrap(body["prompt"] as? [String: Any])
                XCTAssertEqual(self.inputs(graph, "1")["unet_name"] as? String, "flux-schnell.safetensors")
                XCTAssertEqual(self.inputs(graph, "4")["text"] as? String, "Neon skyline")
                XCTAssertEqual(self.inputs(graph, "6")["noise_seed"] as? Int, 999)
                XCTAssertEqual(self.inputs(graph, "8")["steps"] as? Int, 8)
                XCTAssertEqual(self.inputs(graph, "9")["width"] as? Int, 1280)
                XCTAssertEqual(self.inputs(graph, "9")["height"] as? Int, 720)
                return Data(#"{"prompt_id":"flux-id","node_errors":{}}"#.utf8)
            case "/history/flux-id":
                return try self.encoded(["flux-id": ["status": ["completed": true, "status_str": "success"], "outputs": ["13": ["images": [["filename": "flux.png", "subfolder": "", "type": "output"]]]]]])
            case "/view":
                return try self.image()
            default:
                throw URLError(.badURL)
            }
        }
        let overrides = ComfyWorkflowOverrides(seed: 999, steps: 8, width: 1280, height: 720)
        let output = try await fixture.runner.run(
            host: fixture.host, token: nil,
            modelID: "flux-schnell.safetensors", prompt: "Neon skyline",
            workflow: fluxWorkflow, overrides: overrides
        ) { _, _ in }
        XCTAssertEqual(output.promptID, "flux-id")
        XCTAssertEqual(output.fileExtension, "png")
    }

    func testVHSOutputFormatsMustBeReadableBeforeSubmission() throws {
        func workflow(_ format: String) -> ComfyWorkflow {
            ComfyWorkflow(apiJSON: """
            {
              "1": {"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"local.safetensors"}},
              "2": {"class_type":"CLIPTextEncode","inputs":{"clip":["1",1],"text":"prompt"}},
              "3": {"class_type":"VHS_VideoCombine","inputs":{"images":["2",0],"format":"\(format)"}}
            }
            """, checkpointNodeID: "1", promptNodeID: "2", outputNodeID: "3")
        }
        XCTAssertThrowsError(try workflow("image/gif").parsedGraph())
        XCTAssertThrowsError(try workflow("video/webm").parsedGraph())
        XCTAssertNoThrow(try workflow("video/h264-mp4").parsedGraph())
    }

    func testLTXVideoWorkflowSupportsWebPAndMP4OutputsWithOverrides() async throws {
        let ltxWebPGraph = #"""
        {
          "1": {"class_type":"UNETLoader","inputs":{"unet_name":"ltxv-2b.safetensors","weight_dtype":"default"}},
          "2": {"class_type":"CLIPLoader","inputs":{"clip_name":"t5xxl.safetensors","type":"ltxv"}},
          "3": {"class_type":"CLIPTextEncode","inputs":{"clip":["2",0],"text":"Original"}},
          "4": {"class_type":"CLIPTextEncode","inputs":{"clip":["2",0],"text":"blurry"}},
          "5": {"class_type":"CFGGuider","inputs":{"cfg":3.5,"model":["1",0],"negative":["4",0],"positive":["3",0]}},
          "6": {"class_type":"RandomNoise","inputs":{"noise_seed":77}},
          "7": {"class_type":"KSamplerSelect","inputs":{"sampler_name":"euler"}},
          "8": {"class_type":"BasicScheduler","inputs":{"denoise":1.0,"model":["1",0],"scheduler":"normal","steps":25}},
          "9": {"class_type":"EmptyLTXVLatentVideo","inputs":{"batch_size":1,"height":512,"length":25,"width":768}},
          "10": {"class_type":"SamplerCustomAdvanced","inputs":{"guider":["5",0],"latent_image":["9",0],"noise":["6",0],"sampler":["7",0],"sigmas":["8",0]}},
          "11": {"class_type":"VAELoader","inputs":{"vae_name":"ltxv_vae.safetensors"}},
          "12": {"class_type":"VAEDecode","inputs":{"samples":["10",0],"vae":["11",0]}},
          "13": {"class_type":"SaveAnimatedWEBP","inputs":{"filename_prefix":"ltx","fps":24.0,"images":["12",0],"lossless":false,"method":"default","quality":85}}
        }
        """#
        let ltxMP4Graph = ltxWebPGraph.replacingOccurrences(
            of: #""13": {"class_type":"SaveAnimatedWEBP","inputs":{"filename_prefix":"ltx","fps":24.0,"images":["12",0],"lossless":false,"method":"default","quality":85}}"#,
            with: #""13": {"class_type":"SaveVideo","inputs":{"filename_prefix":"ltx_vid","images":["12",0]}}"#
        )
        let ltxObjectInfo: [String: Any] = [
            "UNETLoader": ["input": ["required": ["unet_name": [["ltxv-2b.safetensors"]], "weight_dtype": [["default"]]]], "output": ["MODEL"]],
            "CLIPLoader": ["input": ["required": ["clip_name": [["t5xxl.safetensors"]], "type": [["ltxv"]]]], "output": ["CLIP"]],
            "CLIPTextEncode": ["input": ["required": ["text": ["STRING"], "clip": ["CLIP"]]], "output": ["CONDITIONING"]],
            "CFGGuider": ["input": ["required": ["model": ["MODEL"], "positive": ["CONDITIONING"], "negative": ["CONDITIONING"], "cfg": ["FLOAT"]]], "output": ["GUIDER"]],
            "RandomNoise": ["input": ["required": ["noise_seed": ["INT"]]], "output": ["NOISE"]],
            "KSamplerSelect": ["input": ["required": ["sampler_name": [["euler"]]]], "output": ["SAMPLER"]],
            "BasicScheduler": ["input": ["required": ["model": ["MODEL"], "scheduler": [["normal"]], "steps": ["INT"], "denoise": ["FLOAT"]]], "output": ["SIGMAS"]],
            "EmptyLTXVLatentVideo": ["input": ["required": ["width": ["INT"], "height": ["INT"], "length": ["INT"], "batch_size": ["INT"]]], "output": ["LATENT"]],
            "SamplerCustomAdvanced": ["input": ["required": ["noise": ["NOISE"], "guider": ["GUIDER"], "sampler": ["SAMPLER"], "sigmas": ["SIGMAS"], "latent_image": ["LATENT"]]], "output": ["LATENT", "LATENT"]],
            "VAELoader": ["input": ["required": ["vae_name": [["ltxv_vae.safetensors"]]]], "output": ["VAE"]],
            "VAEDecode": ["input": ["required": ["samples": ["LATENT"], "vae": ["VAE"]]], "output": ["IMAGE"]],
            "SaveAnimatedWEBP": ["input": ["required": ["images": ["IMAGE"], "filename_prefix": ["STRING"], "fps": ["FLOAT"], "lossless": ["BOOLEAN"], "quality": ["INT"], "method": [["default"]]]], "output": [], "output_node": true],
            "SaveVideo": ["input": ["required": ["images": ["IMAGE"], "filename_prefix": ["STRING"]]], "output": [], "output_node": true]
        ]

        // 1. Animated WebP run
        do {
            let webpWorkflow = ComfyWorkflow(
                apiJSON: ltxWebPGraph, checkpointNodeID: "1", promptNodeID: "3", outputNodeID: "13",
                negativePromptNodeID: "4", samplerNodeID: "10", latentNodeID: "9"
            )
            let fixture = try ComfyHTTPFixture()
            defer { fixture.close() }
            fixture.handler = { request in
                switch request.url!.path {
                case "/object_info": return try self.encoded(ltxObjectInfo)
                case "/prompt":
                    let body = try self.json(try XCTUnwrap(request.httpBody))
                    let graph = try XCTUnwrap(body["prompt"] as? [String: Any])
                    XCTAssertEqual(self.inputs(graph, "4")["text"] as? String, "jitter")
                    XCTAssertEqual(self.inputs(graph, "5")["cfg"] as? Double, 4.0)
                    XCTAssertEqual(self.inputs(graph, "6")["noise_seed"] as? Int, 555)
                    XCTAssertEqual(self.inputs(graph, "8")["steps"] as? Int, 16)
                    return Data(#"{"prompt_id":"ltx-webp","node_errors":{}}"#.utf8)
                case "/history/ltx-webp":
                    return try self.encoded(["ltx-webp": ["status": ["completed": true, "status_str": "success"], "outputs": ["13": ["images": [["filename": "clip.webp", "subfolder": "videos", "type": "output"]]]]]])
                case "/view":
                    return self.minimalWebPData()
                default:
                    throw URLError(.badURL)
                }
            }
            let output = try await fixture.runner.run(
                host: fixture.host, token: nil, modelID: "ltxv-2b.safetensors", prompt: "Ocean waves",
                workflow: webpWorkflow,
                overrides: ComfyWorkflowOverrides(negativePrompt: "jitter", seed: 555, steps: 16, cfg: 4.0)
            ) { _, _ in }
            XCTAssertEqual(output.fileExtension, "webp")
            XCTAssertEqual(output.imageData, minimalWebPData())
        }

        // 2. MP4 run via SaveVideo ("videos" output array)
        do {
            let mp4Workflow = ComfyWorkflow(
                apiJSON: ltxMP4Graph, checkpointNodeID: "1", promptNodeID: "3", outputNodeID: "13",
                negativePromptNodeID: "4", samplerNodeID: "10", latentNodeID: "9"
            )
            let fixture = try ComfyHTTPFixture()
            defer { fixture.close() }
            fixture.handler = { request in
                switch request.url!.path {
                case "/object_info": return try self.encoded(ltxObjectInfo)
                case "/prompt": return Data(#"{"prompt_id":"ltx-mp4","node_errors":{}}"#.utf8)
                case "/history/ltx-mp4":
                    return try self.encoded(["ltx-mp4": ["status": ["completed": true, "status_str": "success"], "outputs": ["13": ["videos": [["filename": "clip.mp4", "subfolder": "videos", "type": "output"]]]]]])
                case "/view":
                    return self.minimalMP4Data()
                default:
                    throw URLError(.badURL)
                }
            }
            let output = try await fixture.runner.run(
                host: fixture.host, token: nil, modelID: "ltxv-2b.safetensors", prompt: "Ocean waves",
                workflow: mp4Workflow
            ) { _, _ in }
            XCTAssertEqual(output.fileExtension, "mp4")
            XCTAssertEqual(output.imageData, minimalMP4Data())
        }
    }

    func testRejectsInvalidWebPAndMP4BytesAndUnsafeVideoPaths() async throws {
        let runner = ComfyWorkflowRunner()
        XCTAssertNoThrow(try runner.validateMedia(minimalWebPData(), fileExtension: "webp"))
        XCTAssertNoThrow(try runner.validateMedia(minimalMP4Data(), fileExtension: "mp4"))

        // Invalid WebP & MP4 payloads
        XCTAssertThrowsError(try runner.validateMedia(Data("not webp".utf8), fileExtension: "webp"))
        XCTAssertThrowsError(try runner.validateMedia(Data(), fileExtension: "mp4"))
        XCTAssertThrowsError(try runner.validateMedia(Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70]), fileExtension: "mp4")) // too short
        XCTAssertThrowsError(try runner.validateMedia(Data("not an mp4 box header".utf8), fileExtension: "mp4"))
        // Invalid ftyp box size larger than payload
        XCTAssertThrowsError(try runner.validateMedia(Data([0x00, 0x00, 0x01, 0x00, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]), fileExtension: "mp4"))
        // Non-printable brand
        XCTAssertThrowsError(try runner.validateMedia(Data([0x00, 0x00, 0x00, 0x10, 0x66, 0x74, 0x79, 0x70, 0x00, 0x01, 0x02, 0x03, 0, 0, 0, 0]), fileExtension: "mp4"))

        // Path traversal in videos/gifs outputs must be blocked before /view
        let unsafeVideoMeta: [[String: Any]] = [
            ["filename": "../escape.mp4", "subfolder": "", "type": "output"],
            ["filename": "clip.mp4", "subfolder": "../secret", "type": "output"],
            ["filename": "clip.webp", "subfolder": "/etc", "type": "output"],
            ["filename": "clip.mp4", "subfolder": "", "type": "temp"]
        ]
        for meta in unsafeVideoMeta {
            let fixture = try ComfyHTTPFixture()
            defer { fixture.close() }
            fixture.handler = { request in
                if request.url!.path == "/object_info" { return try self.encoded(self.objectInfo) }
                if request.url!.path == "/prompt" { return Data(#"{"prompt_id":"owned-id","node_errors":{}}"#.utf8) }
                return try self.encoded(["owned-id": ["status": ["completed": true, "status_str": "success"], "outputs": ["9": ["videos": [meta]]]]])
            }
            do {
                _ = try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { _, _ in }
                XCTFail("Unsafe video reference must be refused")
            } catch {
                XCTAssertFalse(fixture.paths.contains("/view"))
            }
        }
    }

    func testRejectsAPINodesByCategoryAndPythonModule() async throws {
        var apiCategory = objectInfo
        var ksCat = try XCTUnwrap(apiCategory["KSampler"] as? [String: Any])
        ksCat["category"] = "api/image"
        apiCategory["KSampler"] = ksCat

        var apiModule = objectInfo
        var ksMod = try XCTUnwrap(apiModule["KSampler"] as? [String: Any])
        ksMod["python_module"] = "comfy_api_nodes.remote"
        apiModule["KSampler"] = ksMod

        for info in [apiCategory, apiModule] {
            let fixture = try ComfyHTTPFixture()
            defer { fixture.close() }
            fixture.handler = { _ in try self.encoded(info) }
            do {
                _ = try await fixture.runner.run(host: fixture.host, token: nil, modelID: "first.safetensors", prompt: "Tree", workflow: workflow) { _, _ in XCTFail("API node must not submit") }
                XCTFail("API node metadata must be refused")
            } catch {
                XCTAssertEqual(fixture.paths, ["/object_info"])
            }
        }
    }

    func testMalformedJSONThrowsCleanlyWithoutCrashing() {
        let malformedGraphs = [
            "",
            "[]",
            "null",
            "{\"4\": \"not-an-object\"}",
            "{\"4\": {\"class_type\": 123, \"inputs\": {}}}",
            "{\"4\": {\"class_type\": \"CheckpointLoaderSimple\", \"inputs\": \"not-a-dict\"}}",
            "{\"4\": {\"class_type\": \"CheckpointLoaderSimple\"}}"
        ]
        for bad in malformedGraphs {
            let wf = ComfyWorkflow(apiJSON: bad, checkpointNodeID: "4", promptNodeID: "6", outputNodeID: "9")
            XCTAssertThrowsError(try wf.validated())
            XCTAssertThrowsError(try wf.submittedGraph(modelID: "m.safetensors", prompt: "p"))
        }
    }

    private func minimalWebPData() -> Data {
        // Minimal valid 1x1 lossless WebP (RIFF + WEBP + VP8L)
        Data([
            0x52, 0x49, 0x46, 0x46, 0x1A, 0x00, 0x00, 0x00,
            0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4C,
            0x0D, 0x00, 0x00, 0x00, 0x2F, 0x00, 0x00, 0x00,
            0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xFE,
            0x07, 0x00
        ])
    }

    private func minimalMP4Data() -> Data {
        // Valid 20-byte ISO BMFF ftyp box ("isom", minor version 512, compatible brand "isom")
        Data([
            0x00, 0x00, 0x00, 0x14, // box size = 20
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x69, 0x73, 0x6F, 0x6D, // major brand "isom"
            0x00, 0x00, 0x02, 0x00, // minor version
            0x69, 0x73, 0x6F, 0x6D  // compatible brand "isom"
        ])
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
