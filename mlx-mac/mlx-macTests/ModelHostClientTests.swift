import Foundation
import Network
import XCTest
@testable import mlx_workbench

final class ModelHostClientTests: XCTestCase {
    func testComfyUIDeviceMemoryKeepsUnknownEmptyAndPartialReportsDistinct() async throws {
        for (body, count) in [("{}", Optional<Int>.none), (#"{"devices":null}"#, nil), (#"{"devices":[]}"#, 0),
                              (#"{"devices":[{"name":"Repeated","type":"cpu","index":null,"vram_free":0},{"name":"Repeated","type":"cuda","index":1,"vram_total":8000}]}"#, 2)] {
            let (client, _) = client(responses: ["/models": .json("[]"), "/system_stats": .json(body)])
            let inventory = try await client.inventory(host: host(.comfyUI))
            XCTAssertEqual(inventory.deviceMemory?.devices.count, count)
            if count == 2 {
                let devices = try XCTUnwrap(inventory.deviceMemory?.devices)
                XCTAssertTrue(devices[0].reportsSystemMemory)
                XCTAssertNil(devices[0].totalBytes)
                XCTAssertEqual(devices[0].freeBytes, 0)
                XCTAssertFalse(devices[1].reportsSystemMemory)
                XCTAssertEqual(devices[1].index, 1)
                XCTAssertEqual(devices[1].totalBytes, 8000)
                XCTAssertNil(devices[1].freeBytes)
            }
        }
    }

    func testComfyUIDeviceMemoryNeverAcceptsInvalidByteReadings() async throws {
        for value in ["true", "false", "-1", "1.5", "9223372036854775808", "\"4096\"", "null", "{}", "[]"] {
            let (client, _) = client(responses: ["/models": .json("[]"),
                "/system_stats": .json("{\"devices\":[{\"vram_total\":\(value),\"vram_free\":\(value)}]}")])
            let inventory = try await client.inventory(host: host(.comfyUI))
            let device = try XCTUnwrap(inventory.deviceMemory?.devices.first)
            XCTAssertNil(device.totalBytes, value)
            XCTAssertNil(device.freeBytes, value)
        }
        let (client, _) = client(responses: ["/models": .json("[]"),
            "/system_stats": .json(#"{"devices":[{"vram_total":100,"vram_free":101},{"vram_total":0,"vram_free":0},{"vram_total":0,"vram_free":1}]}"#)])
        let inventory = try await client.inventory(host: host(.comfyUI))
        let devices = try XCTUnwrap(inventory.deviceMemory?.devices)
        XCTAssertEqual(devices[0].totalBytes, 100)
        XCTAssertNil(devices[0].freeBytes)
        XCTAssertNil(devices[1].totalBytes)
        XCTAssertEqual(devices[1].freeBytes, 0)
        XCTAssertNil(devices[2].freeBytes)
    }

    func testComfyUIMalformedDeviceListsDoNotPublishPartialSnapshotsOrLoseInventory() async throws {
        let tooMany = "{\"devices\":[" + Array(repeating: "{}", count: 33).joined(separator: ",") + "]}"
        for response in [HostStubResponse.json(#"{"devices":{}}"#), .json(#"{"devices":[{},42]}"#), .json(tooMany),
                         HostStubResponse(status: 503, body: "private-host-error")] {
            let (client, _) = client(responses: ["/models": .json(#"["checkpoints"]"#),
                "/models/checkpoints": .json(#"["alpha"]"#), "/system_stats": response,
                "/queue": .json(#"{"queue_running":[],"queue_pending":[]}"#)])
            let inventory = try await client.inventory(host: host(.comfyUI))
            XCTAssertNil(inventory.deviceMemory)
            XCTAssertEqual(inventory.models.map(\.modelID), ["checkpoints/alpha"])
            XCTAssertEqual(inventory.activity?.state, .idle)
            XCTAssertFalse(inventory.warnings.isEmpty)
            XCTAssertFalse(inventory.warnings.joined().contains("private-host-error"))
        }
    }

    func testComfyUIDeviceMemoryRetainsDatedPerDeviceReadingsWithoutExtraRequests() async throws {
        let (client, requests) = client(responses: [
            "/models": .json(#"["checkpoints"]"#),
            "/models/checkpoints": .json(#"["model.safetensors"]"#),
            "/system_stats": .json(#"{"system":{"comfyui_version":"0.3","argv":["private-argument"]},"devices":[{"name":"Apple M4","type":"mps","index":null,"vram_total":16000,"vram_free":0},{"name":"GPU","type":"cuda","index":0,"vram_total":8000,"vram_free":3000}]}"#),
            "/queue": .json(#"{"queue_running":[],"queue_pending":[]}"#)
        ])
        let inventory = try await client.inventory(host: host(.comfyUI), token: "device-token")
        let encoded = try JSONEncoder().encode(inventory)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let snapshot = try XCTUnwrap(wire["deviceMemory"] as? [String: Any])
        let devices = try XCTUnwrap(snapshot["devices"] as? [[String: Any]])
        XCTAssertNotNil(snapshot["capturedAt"])
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first?["name"] as? String, "Apple M4")
        XCTAssertEqual(devices.first?["totalBytes"] as? Int, 16000)
        XCTAssertEqual(devices.first?["freeBytes"] as? Int, 0)
        XCTAssertEqual(devices.last?["freeBytes"] as? Int, 3000)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-argument"))
        XCTAssertEqual(inventory.models.first?.modelID, "checkpoints/model.safetensors")
        XCTAssertNil(inventory.models.first?.memoryBytes)
        XCTAssertEqual(inventory.deviceMemory?.devices.first?.type, "mps")
        XCTAssertTrue(inventory.deviceMemory?.devices.first?.reportsSystemMemory == true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(inventory.deviceMemory?.capturedAt), inventory.capturedAt)
        XCTAssertEqual(requests.values.map { $0.url!.path }, ["/models", "/models/checkpoints", "/system_stats", "/queue"])
        XCTAssertTrue(requests.values.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer device-token" })
    }

    func testOllamaDetailsReadUsesOnlyMetadataAndPreservesLoadedContext() async throws {
        let selectedHost = host(.ollama)
        let selected = HostedModel(hostID: selectedHost.id, modelID: "alpha", name: "Alpha", digest: "a")
        let (client, requests) = client(responses: [
            "/api/tags": .json(#"{"models":[{"name":"alpha","digest":"a","size":100},{"name":"beta","digest":"b"}]}"#),
            "/api/ps": .json(#"{"models":[{"name":"alpha","digest":"a","context_length":4096,"size_vram":80}]}"#),
            "/api/version": .json(#"{"version":"fixture"}"#),
            "/api/show": .json(#"{"capabilities":["completion","vision","tools"],"model_info":{"general.architecture":"llama","llama.context_length":32768,"other.context_length":999999},"template":"private-template","system":"private-system"}"#)
        ])
        let inventory = try await client.inventoryInspecting(selected, host: selectedHost, token: "details-token")
        let inspected = try XCTUnwrap(inventory.models.first)
        XCTAssertEqual(inspected.maximumContextLength, 32768)
        XCTAssertEqual(inspected.capabilities, ["completion", "vision", "tools"])
        XCTAssertEqual(inspected.contextLength, 4096)
        XCTAssertEqual(inspected.memoryBytes, 80)
        XCTAssertEqual(inspected.sizeBytes, 100)
        XCTAssertNotNil(inspected.detailsCapturedAt)
        XCTAssertNil(inventory.models.last?.maximumContextLength)
        XCTAssertNil(inventory.models.last?.capabilities)
        XCTAssertEqual(requests.values.map { $0.url!.path }, ["/api/tags", "/api/ps", "/api/version", "/api/show", "/api/tags", "/api/ps", "/api/version"])
        let posts = requests.values.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1)
        if let post = posts.first {
            let body = try requestJSON(post)
            XCTAssertEqual(body["model"] as? String, "alpha")
            XCTAssertEqual(body["verbose"] as? Bool, false)
            XCTAssertEqual(body.count, 2)
            XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer details-token")
        }
        let encoded = try JSONEncoder().encode(inventory)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-"))
        XCTAssertEqual(try JSONDecoder().decode(HostInventory.self, from: encoded), inventory)
    }

    func testOllamaDetailsRejectInvalidSelectionsBeforeNetwork() async throws {
        let ollama = host(.ollama), other = host(.lmStudio)
        let (client, requests) = client(responses: [:])
        for (selectedHost, model) in [
            (other, HostedModel(hostID: other.id, modelID: "alpha", name: "Alpha", digest: "a")),
            (ollama, HostedModel(hostID: UUID(), modelID: "alpha", name: "Alpha", digest: "a")),
            (ollama, HostedModel(hostID: ollama.id, modelID: "alpha", name: "Alpha")),
            (ollama, HostedModel(hostID: ollama.id, modelID: "", name: "Alpha", digest: "a"))
        ] {
            do { _ = try await client.inventoryInspecting(model, host: selectedHost); XCTFail("Expected invalid selection") }
            catch {}
        }
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testOllamaDetailsRejectDigestChangesBeforeOrAfterTheRead() async throws {
        let selectedHost = host(.ollama)
        let selected = HostedModel(hostID: selectedHost.id, modelID: "alpha", name: "Alpha", digest: "a")
        let same = HostStubResponse.json(#"{"models":[{"name":"alpha","digest":"a"}]}"#)
        let changed = HostStubResponse.json(#"{"models":[{"name":"alpha","digest":"changed"}]}"#)
        for (tags, expectedPosts) in [([changed], 0), ([same, changed], 1), ([same, .json(#"{"models":[]}"#)], 1)] {
            let (http, requests) = transport(sequences: ["/api/tags": tags,
                "/api/ps": [.json(#"{"models":[]}"#)], "/api/version": [.json(#"{"version":"fixture"}"#)],
                "/api/show": [.json(#"{"capabilities":["completion"]}"#)]])
            do { _ = try await ModelHostClient(http: http).inventoryInspecting(selected, host: selectedHost); XCTFail("Expected identity drift rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
            XCTAssertEqual(requests.values.filter { $0.httpMethod == "POST" }.count, expectedPosts)
        }
    }

    func testOllamaDetailsUseFinalResidencyAndOnlyTheDeclaredContextKey() async throws {
        let selectedHost = host(.ollama)
        let selected = HostedModel(hostID: selectedHost.id, modelID: "alpha", name: "Alpha", digest: "a", isLoaded: true)
        let (http, _) = transport(sequences: [
            "/api/tags": [.json(#"{"models":[{"name":"alpha","digest":"a","size":100}]}"#), .json(#"{"models":[{"name":"alpha","digest":"a","size":200}]}"#)],
            "/api/ps": [.json(#"{"models":[{"name":"alpha","digest":"a","context_length":4096,"size_vram":80}]}"#), .json(#"{"models":[]}"#)],
            "/api/show": [.json(#"{"capabilities":["embedding"],"model_info":{"other.context_length":99999}}"#)]])
        let result = try await ModelHostClient(http: http).inventoryInspecting(selected, host: selectedHost)
        let inspected = try XCTUnwrap(result.models.first)
        XCTAssertEqual(inspected.isLoaded, false)
        XCTAssertEqual(inspected.sizeBytes, 200)
        XCTAssertNil(inspected.memoryBytes)
        XCTAssertNil(inspected.contextLength)
        XCTAssertNil(inspected.maximumContextLength)
        XCTAssertEqual(result.runningModels, [])
        XCTAssertEqual(result.loadedStateSummary, "0 models reported loaded")
        XCTAssertThrowsError(try HostedComparisonTarget(host: selectedHost, model: inspected, capturedAt: result.capturedAt).validate(mode: .chat))
    }

    func testOllamaDetailsKeepMissingAndEmptyCapabilitiesDistinct() async throws {
        let selectedHost = host(.ollama)
        let selected = HostedModel(hostID: selectedHost.id, modelID: "alpha", name: "Alpha", digest: "digest-alpha")
        for (body, expected) in [("{}", Optional<[String]>.none), (#"{"capabilities":null}"#, nil), (#"{"capabilities":[]}"#, [])] {
            var responses = ollamaLoadedResponses()
            responses["/api/show"] = .json(body)
            let (client, _) = client(responses: responses)
            let result = try await client.inventoryInspecting(selected, host: selectedHost)
            XCTAssertEqual(result.models.first?.capabilities, expected)
            XCTAssertNil(result.models.first?.maximumContextLength)
        }
    }

    func testOllamaDetailsNeverGuessInvalidMaximumContext() async throws {
        let selectedHost = host(.ollama)
        let selected = HostedModel(hostID: selectedHost.id, modelID: "alpha", name: "Alpha", digest: "digest-alpha")
        for value in ["true", "-1", "0", "1.5", "\"32768\"", "1e100", "null"] {
            var responses = ollamaLoadedResponses()
            responses["/api/show"] = .json("{\"model_info\":{\"general.architecture\":\"llama\",\"llama.context_length\":\(value),\"other.context_length\":32768}}")
            let (client, _) = client(responses: responses)
            let result = try await client.inventoryInspecting(selected, host: selectedHost)
            XCTAssertNil(result.models.first?.maximumContextLength, value)
        }
    }

    func testOllamaDetailsRejectMalformedMetadataAndPropagateCancellation() async throws {
        let selectedHost = host(.ollama)
        let selected = HostedModel(hostID: selectedHost.id, modelID: "alpha", name: "Alpha", digest: "digest-alpha")
        for response in [HostStubResponse.json(#"{"capabilities":["completion",42]}"#),
                         .json(#"{"capabilities":["completion",""]}"#), .json(#"{"capabilities":["tools","tools"]}"#),
                         .json(#"{"model_info":[]}"#), .json("[]"), .failure(.cancelled),
                         .init(status: 401, body: "private-server-body")] {
            var responses = ollamaLoadedResponses(); responses["/api/show"] = response
            let (client, requests) = client(responses: responses)
            do { _ = try await client.inventoryInspecting(selected, host: selectedHost); XCTFail("Expected rejection") }
            catch {
                if response.failure == .cancelled { XCTAssertTrue(error is CancellationError) }
                XCTAssertFalse(error.localizedDescription.contains("private-server-body"))
            }
            XCTAssertEqual(requests.values.map { $0.url!.path }, ["/api/tags", "/api/ps", "/api/version", "/api/show"])
        }
    }

    func testHostURLAcceptsOnlyExplicitLoopbackAndRemovesV1Suffix() throws {
        for value in ["http://127.0.0.1:11434/v1/", "http://localhost:11434/v1", "https://[::1]:11434/v1"] {
            let url = try host(.ollama, url: value).validatedURL()
            XCTAssertEqual(url.path, "")
            XCTAssertEqual(url.port, 11434)
        }
        for value in ["https://example.com", "http://127.0.0.2", "http://localhost.example.com", "file:///tmp/model", "http://user:secret@localhost", "http://localhost?key=secret", "http://localhost/#secret", "http://localhost:0", "http://localhost:65536", "http://localhost/%2e%2e/api", "http://localhost/a/../api", "http://localhost\n:1234", "http://localhost/%252e%252e/api"] {
            XCTAssertThrowsError(try host(.ollama, url: value).validatedURL(), value)
        }
    }

    func testOllamaReportsDigestMatchedLoadedMetadataWithoutInference() async throws {
        let (client, requests) = client(responses: [
            "/api/tags": .json(#"{"models":[{"name":"alpha:latest","digest":"abc","size":123,"details":{"family":"llama","parameter_size":"8B","quantization_level":"Q4_K_M","format":"gguf"}},{"name":"changed:latest","digest":"new"}]}"#),
            "/api/ps": .json(#"{"models":[{"name":"alpha:latest","digest":"abc","size_vram":99,"context_length":4096},{"name":"changed:latest","digest":"old","size_vram":66}]}"#),
            "/api/version": .json(#"{"version":"0.12.0"}"#)
        ])
        let inventory = try await client.inventory(host: host(.ollama))
        XCTAssertEqual(inventory.models.count, 2)
        XCTAssertEqual(inventory.models[0].isLoaded, true)
        XCTAssertEqual(inventory.models[0].contextLength, 4096)
        XCTAssertEqual(inventory.models[0].memoryBytes, 99)
        XCTAssertEqual(inventory.models[0].quantization, "Q4_K_M")
        XCTAssertEqual(inventory.models[1].isLoaded, false)
        XCTAssertNil(inventory.models[1].memoryBytes)
        XCTAssertEqual(inventory.runtimeVersion, "0.12.0")
        XCTAssertTrue(inventory.warnings.contains(where: { $0.contains("capabilities") }))
        XCTAssertTrue(requests.values.allSatisfy { $0.httpMethod == "GET" })
    }

    func testOllamaOptionalFailurePreservesUnknownLoadedState() async throws {
        let (client, _) = client(responses: ["/api/tags": .json(#"{"models":[{"name":"alpha"}]}"#)])
        let inventory = try await client.inventory(host: host(.ollama))
        XCTAssertNil(inventory.models[0].isLoaded)
        XCTAssertNil(inventory.runtimeVersion)
        XCTAssertGreaterThanOrEqual(inventory.warnings.count, 2)
    }

    func testOllamaMemoryInventoryRetainsRunningWeightsSeparateFromInstalledTags() async throws {
        let (client, requests) = client(responses: [
            "/api/tags": .json(#"{"models":[{"name":"alpha","digest":"new","size":100},{"name":"beta","digest":"beta"}]}"#),
            "/api/ps": .json(#"{"models":[{"name":"alpha","digest":"old","size":90,"size_vram":80,"context_length":4096,"details":{"family":"llama","parameter_size":"8B","quantization_level":"Q4","format":"gguf"}},{"name":"orphan","digest":"orphan","size_vram":50}]}"#),
            "/api/version": .json(#"{"version":"0.12.0"}"#)
        ])
        let inventory = try await client.inventory(host: host(.ollama))
        XCTAssertEqual(inventory.models.map(\.modelID), ["alpha", "beta"])
        XCTAssertEqual(inventory.models.first?.digest, "new")
        XCTAssertEqual(inventory.models.first?.isLoaded, false)
        XCTAssertNil(inventory.models.first?.memoryBytes)
        let loaded = inventory.reportedLoadedModels
        XCTAssertEqual(loaded.map(\.modelID), ["alpha", "orphan"])
        XCTAssertEqual(loaded.first?.digest, "old")
        XCTAssertEqual(loaded.first?.memoryBytes, 80)
        XCTAssertEqual(loaded.first?.contextLength, 4096)
        XCTAssertEqual(loaded.first?.parameters, "8B")
        XCTAssertNil(loaded.first?.sizeBytes, "A running allocation is not installed disk size")
        XCTAssertEqual(inventory.loadedStateSummary, "2 models reported loaded")
        let restored = try JSONDecoder().decode(HostInventory.self, from: JSONEncoder().encode(inventory))
        XCTAssertEqual(restored.reportedLoadedModels, loaded)
        XCTAssertEqual(restored.models, inventory.models)
        XCTAssertTrue(inventory.warnings.contains { $0.contains("differ") })
        XCTAssertTrue(inventory.warnings.contains { $0.contains("absent") })
        XCTAssertEqual(requests.values.map { $0.url!.path }, ["/api/tags", "/api/ps", "/api/version"])
        XCTAssertTrue(requests.values.allSatisfy { $0.httpMethod == "GET" })
    }

    func testOllamaRunningListEstablishesResidencyWithoutInstalledTagsOrDigests() async throws {
        for (running, expectedIDs, summary) in [
            (#"[{"model":"only-running","size_vram":42}]"#, ["only-running"], "1 model reported loaded"),
            ("[]", [], "0 models reported loaded")
        ] {
            let (client, _) = client(responses: [
                "/api/tags": .json(#"{"models":[]}"#),
                "/api/ps": .json("{\"models\":\(running)}"),
                "/api/version": .json(#"{"version":"0.12.0"}"#)
            ])
            let inventory = try await client.inventory(host: host(.ollama))
            XCTAssertTrue(inventory.models.isEmpty)
            XCTAssertEqual(inventory.reportedLoadedModels.map(\.modelID), expectedIDs)
            XCTAssertEqual(inventory.loadedStateSummary, summary)
            if !expectedIDs.isEmpty {
                XCTAssertEqual(inventory.reportedLoadedModels.first?.isLoaded, true)
                XCTAssertNil(inventory.reportedLoadedModels.first?.digest)
            }
        }
    }

    func testMalformedOllamaRunningListsDoNotPublishPartialResidency() async throws {
        for running in [#"[{"name":"alpha","digest":"a"},{"name":"alpha","digest":"b"}]"#,
                        #"[{"name":"alpha","digest":"a"},{"name":""}]"#] {
            let (client, _) = client(responses: [
                "/api/tags": .json(#"{"models":[{"name":"alpha","digest":"a"}]}"#),
                "/api/ps": .json("{\"models\":\(running)}"),
                "/api/version": .json(#"{"version":"0.12.0"}"#)
            ])
            let inventory = try await client.inventory(host: host(.ollama))
            XCTAssertEqual(inventory.models.count, 1)
            XCTAssertNil(inventory.models.first?.isLoaded)
            XCTAssertTrue(inventory.reportedLoadedModels.isEmpty)
            XCTAssertEqual(inventory.loadedStateSummary, "Loaded state unknown")
        }
    }

    func testOllamaRunningOnlyModelsCannotAuthorizeUnloadingByTag() async throws {
        for running in [#"[{"name":"orphan","digest":"o","size_vram":42}]"#,
                        #"[{"name":"alpha","digest":"old","size_vram":42}]"#] {
            let (http, requests) = transport(responses: [
                "/api/tags": .json(#"{"models":[{"name":"alpha","digest":"new"}]}"#),
                "/api/ps": .json("{\"models\":\(running)}"),
                "/api/version": .json(#"{"version":"0.12.0"}"#)
            ])
            let selected = running.contains("orphan") ? "orphan" : "alpha"
            do {
                _ = try await HostResourceClient(http: http).preview(host: host(.ollama), selection: HostResourceSelection(modelID: selected))
                XCTFail("Running observations must not grant unload authority for an unavailable installed identity")
            } catch { XCTAssertTrue(error is HostResourceError) }
            XCTAssertTrue(requests.values.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    func testOllamaPrimaryFailureThrowsWithoutReturningServerBody() async throws {
        let (client, _) = client(responses: ["/api/tags": .init(status: 401, body: "secret-server-body")])
        do { _ = try await client.inventory(host: host(.ollama)); XCTFail("Expected HTTP error") }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret-server-body")) }
    }

    func testLMStudioV1UsesPublishedMetadataAndAmbiguousInstanceContextStaysUnknown() async throws {
        let (client, _) = client(responses: ["/api/v1/models": .json(#"{"models":[{"key":"alpha","display_name":"Alpha","type":"llm","architecture":"llama","size_bytes":100,"params_string":"8B","format":"mlx","quantization":{"name":"4bit"},"loaded_instances":[{"id":"one","config":{"context_length":4096}},{"id":"two","config":{"context_length":8192}}],"max_context_length":32768,"capabilities":{"vision":true,"trained_for_tool_use":false}}]}"#)])
        let inventory = try await client.inventory(host: host(.lmStudio))
        let model = try XCTUnwrap(inventory.models.first)
        XCTAssertEqual(model.name, "Alpha")
        XCTAssertEqual(model.modelID, "alpha")
        XCTAssertEqual(model.isLoaded, true)
        XCTAssertNil(model.contextLength)
        XCTAssertEqual(model.maximumContextLength, 32768)
        XCTAssertEqual(model.capabilities, ["vision"])
        XCTAssertEqual(model.category, "llm")
    }

    func testLMStudioFallsBackOnlyForMissingEndpoint() async throws {
        let (client, requests) = client(responses: [
            "/api/v1/models": .init(status: 404, body: ""),
            "/api/v0/models": .json(#"{"data":[{"id":"alpha","type":"llm","state":"loaded","max_context_length":2048,"loaded_context_length":1024,"quantization":"Q4","arch":"llama","compatibility_type":"gguf"}]}"#)
        ])
        let inventory = try await client.inventory(host: host(.lmStudio))
        XCTAssertEqual(inventory.models.first?.contextLength, 1024)
        XCTAssertEqual(inventory.models.first?.isLoaded, true)
        XCTAssertEqual(requests.values.map { $0.url!.path }, ["/api/v1/models", "/api/v0/models"])
        let (denied, deniedRequests) = self.client(responses: ["/api/v1/models": .init(status: 401, body: "")])
        do { _ = try await denied.inventory(host: host(.lmStudio)); XCTFail("Expected authorization error") } catch {}
        XCTAssertEqual(deniedRequests.values.count, 1)
    }

    func testLMStudioFinalFallbackRetainsUnknownMetadata() async throws {
        let (client, _) = client(responses: [
            "/api/v1/models": .init(status: 404, body: ""),
            "/api/v0/models": .init(status: 404, body: ""),
            "/v1/models": .json(#"{"data":[{"id":"alpha"}]}"#)
        ])
        let inventory = try await client.inventory(host: host(.lmStudio))
        XCTAssertEqual(inventory.models.first?.modelID, "alpha")
        XCTAssertNil(inventory.models.first?.isLoaded)
        XCTAssertFalse(inventory.warnings.isEmpty)
    }

    func testGenericHostsDoNotInferCapabilitiesOrLoadedStateFromModelNames() async throws {
        for provider in [ModelHostProvider.llamaCpp, .openAICompatible] {
            let (client, _) = client(responses: ["/v1/models": .json(#"{"data":[{"id":"vision-tools-8b-q4","size":true,"context_length":-1}]}"#)])
            let inventory = try await client.inventory(host: host(provider))
            let model = try XCTUnwrap(inventory.models.first)
            XCTAssertNil(model.capabilities)
            XCTAssertNil(model.isLoaded)
            XCTAssertNil(model.sizeBytes)
            XCTAssertNil(model.contextLength)
        }
    }

    func testLlamaCppUsesReportedModelMetadataWithoutInferringLoadedState() async throws {
        let (client, _) = client(responses: ["/v1/models": .json(#"{"data":[{"id":"alpha","object":"model","owned_by":"llamacpp","meta":{"n_ctx_train":131072,"n_params":8030261312,"size":4912898304},"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}]}"#)])
        let inventory = try await client.inventory(host: host(.llamaCpp))
        let model = try XCTUnwrap(inventory.models.first)
        XCTAssertEqual(model.maximumContextLength, 131072)
        XCTAssertEqual(model.parameters, "8030261312")
        XCTAssertEqual(model.sizeBytes, 4912898304)
        XCTAssertEqual(model.capabilities, ["image input", "text input"])
        XCTAssertNil(model.isLoaded)
        XCTAssertNil(model.contextLength)
    }

    func testMalformedPrimaryListsAndDuplicateIDsAreRejected() async throws {
        for body in [#"{}"#, #"{"data":[{"id":""}]}"#, #"{"data":[{"id":"same"},{"id":"same"}]}"#, #"{"data":[42]}"#] {
            let (client, _) = client(responses: ["/v1/models": .json(body)])
            do { _ = try await client.inventory(host: host(.openAICompatible)); XCTFail("Expected malformed inventory: \(body)") } catch {}
        }
    }

    func testNumericMetadataDoesNotCoerceBooleansNegativeValuesOrFractions() async throws {
        let (client, _) = client(responses: ["/api/v1/models": .json(#"{"models":[{"key":"alpha","size_bytes":true,"max_context_length":-1,"loaded_instances":[{"config":{"context_length":1.5}}]}]}"#)])
        let inventory = try await client.inventory(host: host(.lmStudio))
        let model = try XCTUnwrap(inventory.models.first)
        XCTAssertNil(model.sizeBytes)
        XCTAssertNil(model.maximumContextLength)
        XCTAssertNil(model.contextLength)
    }

    func testComfyUIListsCategoryScopedModelsAndOptionalDeviceData() async throws {
        let (client, requests) = client(responses: [
            "/models": .json(#"["checkpoints","loras"]"#),
            "/models/checkpoints": .json(#"["folder/model.safetensors"]"#),
            "/models/loras": .json(#"["style.safetensors"]"#),
            "/system_stats": .json(#"{"system":{"comfyui_version":"0.3"},"devices":[{"name":"Apple M4","type":"mps","vram_total":16000}]}"#)
        ])
        let inventory = try await client.inventory(host: host(.comfyUI))
        XCTAssertEqual(inventory.models.map(\.modelID), ["checkpoints/folder/model.safetensors", "loras/style.safetensors"])
        XCTAssertEqual(inventory.models[0].category, "checkpoints")
        XCTAssertNil(inventory.models[0].isLoaded)
        XCTAssertEqual(inventory.runtimeVersion, "0.3")
        XCTAssertEqual(inventory.deviceSummary, "Apple M4 (mps)")
        XCTAssertTrue(requests.values.allSatisfy { $0.httpMethod == "GET" })
    }

    func testComfyUICategoryFailuresKeepOtherModelsAndWarn() async throws {
        let (client, _) = client(responses: [
            "/models": .json(#"["checkpoints","loras"]"#),
            "/models/checkpoints": .json(#"["model.safetensors"]"#)
        ])
        let inventory = try await client.inventory(host: host(.comfyUI))
        XCTAssertEqual(inventory.models.count, 1)
        XCTAssertFalse(inventory.warnings.isEmpty)
    }

    func testTransportNormalizesBaseURLAddsAuthorizationAndBoundsResponse() async throws {
        let (http, requests) = transport(responses: ["/v1/models": .json(#"{"data":[]}"#)])
        _ = try await http.request(host: host(.openAICompatible, url: "http://localhost:9999/v1/"), path: "v1/models", token: "test-token")
        XCTAssertEqual(requests.values.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        do {
            _ = try await http.request(host: host(.openAICompatible), path: "v1/models", maximumBytes: 2)
            XCTFail("Expected response limit")
        } catch { XCTAssertEqual(error as? HostHTTPError, .responseTooLarge) }
        let before = requests.values.count
        for path in ["https://example.com/steal", "//example.com/steal", "../secret", "api/%2e%2e/secret", "api?token=secret"] {
            do { _ = try await http.request(host: host(.openAICompatible), path: path); XCTFail("Expected invalid path") } catch {}
        }
        XCTAssertEqual(requests.values.count, before)
    }

    func testModelLimitRejectsOversizedInventory() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["data": (0..<513).map { ["id": "model-\($0)"] }])
        let (client, _) = client(responses: ["/v1/models": .init(status: 200, data: data)])
        do { _ = try await client.inventory(host: host(.openAICompatible)); XCTFail("Expected inventory limit") } catch {}
    }

    func testTransportRefusesRedirectsBeforeSendingCredentialsAgain() async throws {
        let server = try await HostRedirectServer.start()
        defer { server.stop() }
        do {
            _ = try await HostHTTPClient().request(host: host(.openAICompatible, url: "http://127.0.0.1:\(server.port)"), path: "v1/models", token: "private-token")
            XCTFail("A redirect must not be followed")
        } catch { XCTAssertEqual(error as? HostHTTPError, .httpStatus(302)) }
        XCTAssertEqual(server.requestCount, 1)
    }

    func testComfyUIActivityDistinguishesIdleRunningAndQueuedWork() async throws {
        for (body, state, running, pending) in [
            (#"{"queue_running":[],"queue_pending":[]}"#, HostActivityState.idle, 0, 0),
            (#"{"queue_running":[[0,"running",{}, {}, []]],"queue_pending":[[1,"pending",{}, {}, []]]}"#, .busy, 1, 1),
            (#"{"queue_running":[],"queue_pending":[[1,"pending",{}, {}, []]]}"#, .queued, 0, 1),
            (#"{"queue_running":[],"queue_pending":[[-0.5,"front",{}, {}, []]]}"#, .queued, 0, 1)
        ] {
            let (client, requests) = client(responses: ["/queue": .json(body)])
            let activity = try await client.activity(host: host(.comfyUI), token: "queue-token")
            XCTAssertEqual(activity.state, state)
            XCTAssertEqual(activity.runningCount, running)
            XCTAssertEqual(activity.pendingCount, pending)
            XCTAssertEqual(requests.values.map { $0.httpMethod }, ["GET"])
            XCTAssertEqual(requests.values.first?.value(forHTTPHeaderField: "Authorization"), "Bearer queue-token")
        }
    }

    func testComfyUIActivityNeverCallsMissingOrMalformedQueueIdle() async throws {
        for body in [#"{}"#, #"{"queue_running":[],"queue_pending":null}"#,
                     #"{"queue_running":[42],"queue_pending":[]}"#,
                     #"{"queue_running":[[true,"id",{},{},[]]],"queue_pending":[]}"#,
                     #"{"queue_running":[[0,"",{},{},[]]],"queue_pending":[]}"#,
                     #"{"queue_running":[[0,"same",{},{},[]]],"queue_pending":[[1,"same",{},{},[]]]}"#] {
            let (client, _) = client(responses: ["/queue": .json(body)])
            let activity = try await client.activity(host: host(.comfyUI))
            XCTAssertEqual(activity.state, .unknown)
            XCTAssertNil(activity.runningCount)
            XCTAssertNil(activity.pendingCount)
            XCTAssertFalse(activity.detail.isEmpty)
        }
        let (client, _) = client(responses: ["/queue": .init(status: 500, body: "private-server-body")])
        let activity = try await client.activity(host: host(.comfyUI))
        XCTAssertEqual(activity.state, .unknown)
        XCTAssertFalse(activity.detail.contains("private-server-body"))
    }

    func testActivityCancellationPropagatesAndLLMActivityStaysUnknownWithoutRequests() async throws {
        let (cancelled, _) = client(responses: ["/queue": .failure(.cancelled)])
        do { _ = try await cancelled.activity(host: host(.comfyUI)); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        for provider in [ModelHostProvider.ollama, .lmStudio, .llamaCpp, .openAICompatible] {
            let (client, requests) = client(responses: [:])
            let activity = try await client.activity(host: host(provider))
            XCTAssertEqual(activity.state, .unknown)
            XCTAssertNil(activity.runningCount)
            XCTAssertTrue(requests.values.isEmpty)
        }
    }

    func testInventoryRetainsModelsWhenQueueIsUnavailable() async throws {
        let (client, _) = client(responses: ["/models": .json(#"["checkpoints"]"#), "/models/checkpoints": .json(#"["alpha.safetensors"]"#)])
        let inventory = try await client.inventory(host: host(.comfyUI))
        XCTAssertEqual(inventory.models.count, 1)
        XCTAssertEqual(inventory.activity?.state, .unknown)
    }

    func testLMStudioLoadedInstanceIDsAreAuthoritativeOnlyWhenCompleteAndUnique() async throws {
        for (instances, expected) in [
            (#"[{"id":"one"},{"id":"two"}]"#, Optional(["one", "two"])),
            ("[]", Optional([])),
            (#"[{"id":"same"},{"id":"same"}]"#, nil),
            (#"[{"id":""}]"#, nil),
            (#"[{"config":{}}]"#, nil),
            ("null", nil)
        ] {
            let (client, _) = client(responses: ["/api/v1/models": .json("{\"models\":[{\"key\":\"alpha\",\"loaded_instances\":\(instances)}]}")])
            let inventory = try await client.inventory(host: host(.lmStudio))
            XCTAssertEqual(inventory.models.first?.loadedInstanceIDs, expected)
            if expected == nil { XCTAssertNil(inventory.models.first?.isLoaded) }
        }
        let (client, _) = client(responses: ["/api/v1/models": .json(#"{"models":[{"key":"alpha","loaded_instances":[{"id":"shared"}]},{"key":"beta","loaded_instances":[{"id":"shared"}]}]}"#)])
        let inventory = try await client.inventory(host: host(.lmStudio))
        XCTAssertTrue(inventory.models.allSatisfy { $0.loadedInstanceIDs == nil })
    }

    func testOllamaResourcePreviewRequiresFreshDigestMatchedLoadedModel() async throws {
        let selectedHost = host(.ollama)
        let (http, requests) = transport(responses: ollamaLoadedResponses())
        let client = HostResourceClient(http: http)
        let preview = try await client.preview(host: selectedHost, selection: HostResourceSelection(modelID: "alpha"))
        XCTAssertEqual(preview.model?.digest, "digest-alpha")
        XCTAssertEqual(preview.model?.isLoaded, true)
        XCTAssertEqual(preview.activity.state, .unknown)
        XCTAssertTrue(requests.values.allSatisfy { $0.httpMethod == "GET" })
        for selection in [HostResourceSelection(), HostResourceSelection(modelID: "missing"), HostResourceSelection(modelID: "alpha", instanceID: "unexpected")] {
            do { _ = try await client.preview(host: selectedHost, selection: selection); XCTFail("Expected invalid target") } catch {}
        }
        let (driftHTTP, _) = transport(responses: ollamaLoadedResponses(runningDigest: "different"))
        do { _ = try await HostResourceClient(http: driftHTTP).preview(host: selectedHost, selection: HostResourceSelection(modelID: "alpha")); XCTFail("Expected digest drift refusal") } catch {}
    }

    func testLMStudioResourcePreviewSelectsOnlyExactLoadedInstance() async throws {
        let (http, requests) = transport(responses: ["/api/v1/models": .json(#"{"models":[{"key":"alpha","loaded_instances":[{"id":"first"},{"id":"second"}]}]}"#)])
        let client = HostResourceClient(http: http)
        let selectedHost = host(.lmStudio)
        let preview = try await client.preview(host: selectedHost, selection: HostResourceSelection(modelID: "alpha", instanceID: "second"))
        XCTAssertEqual(preview.model?.loadedInstanceIDs, ["first", "second"])
        XCTAssertEqual(preview.selection.instanceID, "second")
        XCTAssertTrue(requests.values.allSatisfy { $0.httpMethod == "GET" })
        for selection in [HostResourceSelection(modelID: "alpha"), HostResourceSelection(modelID: "alpha", instanceID: "absent")] {
            do { _ = try await client.preview(host: selectedHost, selection: selection); XCTFail("Expected exact instance requirement") } catch {}
        }
    }

    func testComfyUIResourcePreviewReadsQueueOnlyAndUnsupportedHostsSendNoRequests() async throws {
        let (http, requests) = transport(responses: ["/queue": .json(#"{"queue_running":[],"queue_pending":[]}"#)])
        let client = HostResourceClient(http: http)
        let preview = try await client.preview(host: host(.comfyUI), selection: HostResourceSelection())
        XCTAssertNil(preview.model)
        XCTAssertEqual(preview.activity.state, .idle)
        XCTAssertEqual(requests.values.map { $0.url!.path }, ["/queue"])
        let before = requests.values.count
        for provider in [ModelHostProvider.llamaCpp, .openAICompatible] {
            do { _ = try await client.preview(host: host(provider), selection: HostResourceSelection()); XCTFail("Expected unsupported provider") } catch {}
        }
        do { _ = try await client.preview(host: host(.comfyUI), selection: HostResourceSelection(modelID: "checkpoint")); XCTFail("Expected host-wide selection") } catch {}
        XCTAssertEqual(requests.values.count, before)
    }

    func testResourceReleaseUsesOnlyDocumentedMutationForEachProvider() async throws {
        for provider in [ModelHostProvider.ollama, .lmStudio, .comfyUI] {
            let selectedHost = host(provider)
            let selection: HostResourceSelection
            let model: HostedModel?
            let path: String
            let expected: [String: AnyHashable]
            switch provider {
            case .ollama:
                selection = HostResourceSelection(modelID: "alpha")
                model = HostedModel(hostID: selectedHost.id, modelID: "alpha", name: "Alpha", digest: "digest-alpha", isLoaded: true)
                path = "/api/generate"; expected = ["model": "alpha", "keep_alive": 0, "stream": false]
            case .lmStudio:
                selection = HostResourceSelection(modelID: "alpha", instanceID: "exact-instance")
                var loaded = HostedModel(hostID: selectedHost.id, modelID: "alpha", name: "Alpha", isLoaded: true)
                loaded.loadedInstanceIDs = ["exact-instance"]
                model = loaded
                path = "/api/v1/models/unload"; expected = ["instance_id": "exact-instance"]
            default:
                selection = HostResourceSelection(); model = nil
                path = "/free"; expected = ["unload_models": true, "free_memory": true]
            }
            let response = provider == .comfyUI ? HostStubResponse(status: 200, body: "") : .json("{}")
            let (http, requests) = transport(responses: [path: response])
            let preview = HostResourcePreview(host: selectedHost, selection: selection, model: model,
                activity: HostActivity(state: .unknown, detail: "Active requests are not reported."))
            try await HostResourceClient(http: http).release(preview: preview, token: "release-token")
            XCTAssertEqual(requests.values.count, 1)
            let request = try XCTUnwrap(requests.values.first)
            XCTAssertEqual(request.url?.path, path)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer release-token")
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: requestJSON(request), options: [.sortedKeys]),
                try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
        }
    }

    func testResourceReleaseRejectsForgedOrUnsupportedTargetsWithoutNetwork() async throws {
        let selectedHost = host(.ollama)
        let activity = HostActivity(state: .unknown, detail: "Unknown")
        let validModel = HostedModel(hostID: selectedHost.id, modelID: "alpha", name: "Alpha", digest: "digest", isLoaded: true)
        let wrongHostModel = HostedModel(hostID: UUID(), modelID: "alpha", name: "Alpha", digest: "digest", isLoaded: true)
        let previews = [
            HostResourcePreview(host: selectedHost, selection: HostResourceSelection(modelID: "alpha"), model: wrongHostModel, activity: activity),
            HostResourcePreview(host: selectedHost, selection: HostResourceSelection(modelID: "other"), model: validModel, activity: activity),
            HostResourcePreview(host: selectedHost, selection: HostResourceSelection(modelID: "alpha", instanceID: "unexpected"), model: validModel, activity: activity),
            HostResourcePreview(host: host(.comfyUI), selection: HostResourceSelection(modelID: "alpha"), model: nil, activity: activity),
            HostResourcePreview(host: host(.openAICompatible), selection: HostResourceSelection(), model: nil, activity: activity)
        ]
        let (http, requests) = transport(responses: [:])
        for preview in previews {
            do { try await HostResourceClient(http: http).release(preview: preview); XCTFail("Expected invalid target") } catch {}
        }
        XCTAssertTrue(requests.values.isEmpty)
    }

    private func ollamaLoadedResponses(runningDigest: String = "digest-alpha") -> [String: HostStubResponse] {
        ["/api/tags": .json(#"{"models":[{"name":"alpha","digest":"digest-alpha"}]}"#),
         "/api/ps": .json("{\"models\":[{\"name\":\"alpha\",\"digest\":\"\(runningDigest)\"}]}"),
         "/api/version": .json(#"{"version":"0.12"}"#)]
    }

    private func requestJSON(_ request: URLRequest) throws -> [String: AnyHashable] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
    }

    private func host(_ provider: ModelHostProvider, url: String = "http://localhost:1234") -> ModelHost {
        ModelHost(name: "Test host", provider: provider, baseURL: url)
    }

    private func client(responses: [String: HostStubResponse]) -> (ModelHostClient, HostRequestLog) {
        let (http, log) = transport(responses: responses)
        return (ModelHostClient(http: http), log)
    }

    private func transport(responses: [String: HostStubResponse]) -> (HostHTTPClient, HostRequestLog) {
        transport(sequences: responses.mapValues { [$0] })
    }

    private func transport(sequences: [String: [HostStubResponse]]) -> (HostHTTPClient, HostRequestLog) {
        let log = HostRequestLog()
        let key = UUID().uuidString
        HostInventoryStub.register(key: key, responses: sequences, log: log)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostInventoryStub.self]
        configuration.httpAdditionalHeaders = ["X-Inventory-Test": key]
        return (HostHTTPClient(session: URLSession(configuration: configuration)), log)
    }
}

private struct HostStubResponse {
    let status: Int
    let data: Data
    var failure: URLError.Code? = nil
    init(status: Int, body: String) { self.init(status: status, data: Data(body.utf8)) }
    init(status: Int, data: Data) { self.status = status; self.data = data }
    static func json(_ body: String) -> Self { .init(status: 200, body: body) }
    static func failure(_ code: URLError.Code) -> Self {
        var response = Self(status: 200, body: "")
        response.failure = code
        return response
    }
}

private final class HostRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
}

private final class HostInventoryStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: ([String: [HostStubResponse]], HostRequestLog)] = [:]
    static func register(key: String, responses: [String: [HostStubResponse]], log: HostRequestLog) {
        lock.lock(); defer { lock.unlock() }; fixtures[key] = (responses, log)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let key = request.value(forHTTPHeaderField: "X-Inventory-Test") ?? ""
        var fixture = Self.fixtures[key]
        let path = request.url!.path
        let stub = fixture?.0[path]?.first ?? .init(status: 404, body: "")
        if var sequence = fixture?.0[path], sequence.count > 1 {
            sequence.removeFirst(); fixture?.0[path] = sequence; Self.fixtures[key] = fixture
        }
        Self.lock.unlock()
        fixture?.1.append(request)
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HostRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "host-redirect-test")
    private let lock = NSLock()
    private var count = 0
    var port: UInt16 { listener.port!.rawValue }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> HostRedirectServer {
        let server = try HostRedirectServer()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.newConnectionHandler = { connection in
                connection.start(queue: server.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    server.lock.lock()
                    server.count += 1
                    let count = server.count
                    server.lock.unlock()
                    let response = count == 1
                        ? "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(server.port)/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        : "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() { listener.cancel() }
}
