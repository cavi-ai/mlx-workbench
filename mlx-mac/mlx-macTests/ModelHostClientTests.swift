import Foundation
import Network
import XCTest
@testable import mlx_workbench

final class ModelHostClientTests: XCTestCase {
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

    private func host(_ provider: ModelHostProvider, url: String = "http://localhost:1234") -> ModelHost {
        ModelHost(name: "Test host", provider: provider, baseURL: url)
    }

    private func client(responses: [String: HostStubResponse]) -> (ModelHostClient, HostRequestLog) {
        let (http, log) = transport(responses: responses)
        return (ModelHostClient(http: http), log)
    }

    private func transport(responses: [String: HostStubResponse]) -> (HostHTTPClient, HostRequestLog) {
        let log = HostRequestLog()
        let key = UUID().uuidString
        HostInventoryStub.register(key: key, responses: responses, log: log)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostInventoryStub.self]
        configuration.httpAdditionalHeaders = ["X-Inventory-Test": key]
        return (HostHTTPClient(session: URLSession(configuration: configuration)), log)
    }
}

private struct HostStubResponse {
    let status: Int
    let data: Data
    init(status: Int, body: String) { self.init(status: status, data: Data(body.utf8)) }
    init(status: Int, data: Data) { self.status = status; self.data = data }
    static func json(_ body: String) -> Self { .init(status: 200, body: body) }
}

private final class HostRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
}

private final class HostInventoryStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: ([String: HostStubResponse], HostRequestLog)] = [:]
    static func register(key: String, responses: [String: HostStubResponse], log: HostRequestLog) {
        lock.lock(); defer { lock.unlock() }; fixtures[key] = (responses, log)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.fixtures[request.value(forHTTPHeaderField: "X-Inventory-Test") ?? ""]
        Self.lock.unlock()
        fixture?.1.append(request)
        let stub = fixture?.0[request.url!.path] ?? .init(status: 404, body: "")
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
