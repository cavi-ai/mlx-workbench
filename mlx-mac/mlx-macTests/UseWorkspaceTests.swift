import AppKit
import Foundation
import XCTest
@testable import mlx_workbench

final class UseWorkspaceTests: XCTestCase {
    func testRecoveryKeepsPartialAnswerWithoutReplayingRequest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("use-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UseSessionStore(url: folder.appendingPathComponent("sessions.json"))
        var session = UseSession(title: "A conversation", modelPath: "/Models/chat", modelName: "Local chat", mode: .chat)
        var turn = UseTurn(prompt: "Explain the change", images: [], endpoint: ServerInfo(path: "/Models/chat", port: 8085), settings: UseRequestDefaults())
        turn.answer = "The partial answer"
        session.turns = [turn]; session.wasSending = true
        try await store.save(session)
        try await store.recoverInterrupted()
        let record = try await store.record(id: session.id)
        let restored = try XCTUnwrap(record)
        XCTAssertEqual(restored.turns.first?.answer, "The partial answer")
        XCTAssertEqual(restored.turns.first?.state, .interrupted)
        XCTAssertFalse(restored.wasSending)
        let list = try await store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].turns.isEmpty, "History navigation must not load every answer")
    }
    @MainActor
    func testConversationPersistsBeforeSendAndRestoresCompleteContext() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let recorder = Recorder(store: fixture.store)
        let coordinator = fixture.coordinator(recorder)
        try await coordinator.create(modelPath: "/Models/chat", modelName: "Local chat", mode: .chat, endpoint: Self.server())
        coordinator.updateDraft("First question")
        coordinator.isPresentingPanel = true
        XCTAssertFalse(coordinator.canSend)
        coordinator.isPresentingPanel = false
        let first = try XCTUnwrap(coordinator.send()); await first.value
        XCTAssertEqual(coordinator.selected?.turns.last?.state, .complete)
        coordinator.updateDraft("Follow up")
        let second = try XCTUnwrap(coordinator.send()); await second.value
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].map { $0["role"]?.stringValue }, ["user", "assistant", "user"])
        XCTAssertEqual(requests[1][0]["content"], .string("First question"))
        XCTAssertEqual(requests[1][1]["content"], .string("A saved answer"))
        let restored = fixture.coordinator(recorder)
        await restored.load()
        XCTAssertEqual(restored.selected?.id, coordinator.selected?.id)
        XCTAssertEqual(restored.selected?.turns.count, 2)
        XCTAssertEqual(restored.selected?.turns.last?.answer, "A saved answer")
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2, "Opening history must not replay inference")
    }

    @MainActor
    func testDefaultsAndDraftsPersistWithoutSending() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let recorder = Recorder(store: fixture.store)
        let coordinator = fixture.coordinator(recorder)
        try await coordinator.create(modelPath: "/Models/chat", modelName: "Local chat", mode: .chat)
        let settings = UseRequestDefaults(maximumTokens: 512, temperature: 0, systemPrompt: "Keep answers brief.")
        try await coordinator.setSettings(settings, saveDefaults: true)
        coordinator.updateDraft("An unsent draft")
        try await coordinator.flushDraft()
        let restored = fixture.coordinator(recorder); await restored.load()
        XCTAssertEqual(restored.selected?.draft, "An unsent draft")
        try await restored.create(modelPath: "/Models/other", modelName: "Other", mode: .chat)
        XCTAssertEqual(restored.selected?.settings, settings)
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testMissingCredentialAndDriftNeverSubmitOrLoseDraft() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let recorder = Recorder(store: fixture.store)
        let coordinator = fixture.coordinator(recorder)
        try await coordinator.create(modelPath: "/Models/chat", modelName: "Local chat", mode: .chat, endpoint: Self.server())
        await recorder.setPrepareError(true)
        coordinator.updateDraft("Keep this input")
        let first = try XCTUnwrap(coordinator.send()); await first.value
        XCTAssertEqual(coordinator.selected?.draft, "Keep this input")
        await recorder.setPrepareError(false)
        await recorder.setDrift(true)
        let second = try XCTUnwrap(coordinator.send()); await second.value
        XCTAssertEqual(coordinator.selected?.draft, "Keep this input")
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(coordinator.selected?.turns.last?.state, .failed)
    }

    @MainActor
    func testStopRetainsPartialAnswerAndOnlyExplicitRetrySendsAgain() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let started = expectation(description: "Owned request started")
        let recorder = Recorder(store: fixture.store, started: started)
        await recorder.setHold(true)
        let coordinator = fixture.coordinator(recorder)
        try await coordinator.create(modelPath: "/Models/chat", modelName: "Local chat", mode: .chat, endpoint: Self.server())
        coordinator.updateDraft("A long answer")
        let task = try XCTUnwrap(coordinator.send())
        await fulfillment(of: [started], timeout: 5)
        coordinator.stop(); await task.value
        XCTAssertEqual(coordinator.selected?.turns.last?.state, .stoppedWaiting)
        XCTAssertEqual(coordinator.selected?.turns.last?.answer, "A saved answer")
        XCTAssertTrue(coordinator.selected?.turns.last?.notice?.contains("server may still") == true)
        let restored = fixture.coordinator(recorder); await restored.load()
        var count = await recorder.requests.count
        XCTAssertEqual(count, 1)
        await recorder.setHold(false)
        restored.updateDraft("A new unsent question")
        let retry = try XCTUnwrap(restored.retryLastTurn()); await retry.value
        count = await recorder.requests.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(restored.selected?.draft, "A new unsent question")
        XCTAssertEqual(restored.selected?.turns.last?.retryOf, restored.selected?.turns.first?.id)
        let request = await recorder.requests.last
        XCTAssertEqual(request?.count, 1, "Unconfirmed replies must not become conversation context")
    }

    @MainActor
    func testEarlyEOFIsInterruptedAndSaveFailureBlocksInference() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let recorder = Recorder(store: fixture.store)
        await recorder.setFinish(nil)
        let coordinator = fixture.coordinator(recorder)
        try await coordinator.create(modelPath: "/Models/chat", modelName: "Local chat", mode: .chat, endpoint: Self.server())
        coordinator.updateDraft("Explain")
        let task = try XCTUnwrap(coordinator.send()); await task.value
        XCTAssertEqual(coordinator.selected?.turns.last?.state, .interrupted)
        let database = fixture.url.appendingPathExtension("sqlite")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: database.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path) }
        coordinator.updateDraft("Must remain unsent")
        let blocked = try XCTUnwrap(coordinator.send()); await blocked.value
        XCTAssertTrue(coordinator.hasUnsavedChanges)
        XCTAssertEqual(coordinator.selected?.draft, "Must remain unsent")
        let count = await recorder.requests.count
        XCTAssertEqual(count, 1)
    }

    func testImageReuseAndContextRequireAnEligibleServerAndUnchangedBytes() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = fixture.folder.appendingPathComponent("input.png"); try png.write(to: source)
        let first = try await fixture.images.importImage(source)
        let second = try await fixture.images.importImage(source)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.inputRoot.path).count, 1)
        let session = UseSession(title: "Vision", modelPath: "/Models/chat", modelName: "Vision", mode: .chat)
        do {
            _ = try await UseChatRequest.messages(session: session, prompt: "Describe", images: [first], inputs: fixture.images, server: Self.server())
            XCTFail("A text server accepted image input")
        } catch {}
        let messages = try await UseChatRequest.messages(session: session, prompt: "Describe", images: [first], inputs: fixture.images, server: Self.server(runtime: "mlx-vlm"))
        let parts = try XCTUnwrap(messages.first?["content"]?.arrayValue)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[1].objectValue?["image_url"]?.objectValue?["url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        try Data("changed".utf8).write(to: fixture.inputRoot.appendingPathComponent(first.filename))
        do { _ = try await fixture.images.bytes(first); XCTFail("Changed input reused") } catch {}
        XCTAssertEqual(try Data(contentsOf: source), png)
    }

    @MainActor
    func testExportsKeepAnswerAndOriginWithoutCredentials() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let recorder = Recorder(store: fixture.store)
        let coordinator = fixture.coordinator(recorder)
        try await coordinator.create(modelPath: "/Models/chat", modelName: "Local chat", mode: .chat, endpoint: Self.server())
        coordinator.updateDraft("Export this")
        let task = try XCTUnwrap(coordinator.send()); await task.value
        let markdown = fixture.folder.appendingPathComponent("chat.md")
        let json = fixture.folder.appendingPathComponent("chat.json")
        try await coordinator.export(to: markdown, json: false)
        try await coordinator.export(to: json, json: true)
        XCTAssertTrue(try String(contentsOf: markdown, encoding: .utf8).contains("A saved answer"))
        let bytes = try Data(contentsOf: json)
        let exported = try JSONDecoder().decode(UseSession.self, from: bytes)
        XCTAssertEqual(exported.turns.first?.endpoint.pid, 51)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("fixture-key"))
        let linked = fixture.folder.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: markdown)
        do { try await coordinator.export(to: linked, json: false); XCTFail("Export followed a symbolic link") } catch {}
    }

    func testRequestBoundsAndActiveWorkClaims() throws {
        for settings in [UseRequestDefaults(maximumTokens: 0), UseRequestDefaults(temperature: .nan), UseRequestDefaults(temperature: 3),
                         UseRequestDefaults(systemPrompt: String(repeating: "x", count: 8193))] { XCTAssertThrowsError(try settings.validate()) }
        var occupancy = ModelOccupancy()
        occupancy.add(["/Models/chat"], for: .workSession)
        occupancy.add(["/Models/task"], for: .servedTask)
        XCTAssertTrue(occupancy.blocksStop(modelIdentity: "/Models/chat"))
        XCTAssertTrue(occupancy.blocksStop(modelIdentity: "/Models/task"))
    }

    @MainActor
    func testQuitFlushesTheLatestDraftBeforeDebounce() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let recorder = Recorder(store: fixture.store)
        let coordinator = fixture.coordinator(recorder)
        try await coordinator.create(modelPath: "/Models/chat", modelName: "Local chat", mode: .chat)
        coordinator.updateDraft("Last keystroke")
        let saved = await coordinator.prepareForQuit()
        XCTAssertTrue(saved)
        let restored = fixture.coordinator(recorder); await restored.load()
        XCTAssertEqual(restored.selected?.draft, "Last keystroke")
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    func testConversationTransportSendsHistoryAndStreamsUpdates() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UseChatHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let messages: [[String: JSONValue]] = [["role": .string("user"), "content": .string("First")],
            ["role": .string("assistant"), "content": .string("Saved")], ["role": .string("user"), "content": .string("Follow up")]]
        let updates = Updates()
        let answer = try await OpenAIEndpointProber(session: session, bearerToken: "fixture-inference-key")
            .conversation(baseURL: URL(string: "http://127.0.0.1:8085")!, model: "/Models/chat", messages: messages,
                          settings: UseRequestDefaults(maximumTokens: 512, temperature: 0.2)) { text, _ in await updates.append(text) }
        XCTAssertEqual(answer.text, "Hello there")
        XCTAssertEqual(answer.finishReason, "stop")
        let chunks = await updates.values
        XCTAssertEqual(chunks, ["Hello", "Hello there"])
    }

    actor Updates {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    @MainActor
    func testFullHistoryRefusesAnotherTurnWithoutPoisoningSavedWork() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let recorder = Recorder(store: fixture.store)
        var session = UseSession(title: "Full conversation", modelPath: "/Models/chat", modelName: "Local", mode: .chat, endpoint: Self.server())
        session.turns = (0..<100).map { index in
            var turn = UseTurn(prompt: "Question \(index)", images: [], endpoint: Self.server(), settings: UseRequestDefaults())
            turn.answer = "Answer"; turn.state = .complete
            return turn
        }
        try await fixture.store.save(session); try await fixture.store.select(session.id)
        let coordinator = fixture.coordinator(recorder); await coordinator.load()
        coordinator.updateDraft("Keep this draft")
        let task = try XCTUnwrap(coordinator.send()); await task.value
        XCTAssertEqual(coordinator.selected?.turns.count, 100)
        XCTAssertEqual(coordinator.selected?.draft, "Keep this draft")
        XCTAssertFalse(coordinator.hasUnsavedChanges)
        XCTAssertTrue(coordinator.canChange)
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testUnsaveableDraftCanStillBeExportedAndEdited() async throws {
        let fixture = Fixture(); defer { fixture.remove() }
        let recorder = Recorder(store: fixture.store)
        let coordinator = fixture.coordinator(recorder)
        try await coordinator.create(modelPath: "/Models/chat", modelName: "Local", mode: .chat)
        let draft = String(repeating: "x", count: 32769)
        coordinator.updateDraft(draft)
        do { try await coordinator.flushDraft(); XCTFail("Expected draft limit") } catch {}
        let export = fixture.folder.appendingPathComponent("draft.md")
        try await coordinator.export(to: export, json: false)
        XCTAssertTrue(try String(contentsOf: export, encoding: .utf8).contains(draft))
        coordinator.updateDraft("A corrected draft")
        try await coordinator.flushDraft()
        XCTAssertFalse(coordinator.hasUnsavedChanges)
        XCTAssertNil(coordinator.error)
    }

    static func server(runtime: String = "mlx_lm") -> ServerInfo {
        ServerInfo(path: "/Models/chat", runtime: runtime, port: 8085, pid: 51, state: "running",
                   startedAt: "2026-11-10T12:00:00Z", receipt: "/state/.mlx-agent-receipts/serve/8085.json",
                   receiptsDirectory: "/state", processStartedAt: "Tue Nov 10 07:00:00 2026")
    }
    struct Fixture {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/use-workspace-\(UUID())")
        var url: URL { folder.appendingPathComponent("sessions.json") }
        var inputRoot: URL { folder.appendingPathComponent("inputs") }
        var store: UseSessionStore { UseSessionStore(url: url) }
        var images: UseImageStore { UseImageStore(root: inputRoot) }
        func remove() { try? FileManager.default.removeItem(at: folder) }
        @MainActor func coordinator(_ recorder: Recorder) -> UseWorkspaceCoordinator {
            UseWorkspaceCoordinator(store: store, images: images, client: UseChatClient(
                prepare: { try await recorder.prepare($0) }, assertCurrent: { try await recorder.check($0) },
                stream: { server, messages, settings, _, update in try await recorder.stream(server, messages, settings, update) }))
        }
    }
    actor Recorder {
        let store: UseSessionStore
        let started: XCTestExpectation?
        var requests: [[[String: JSONValue]]] = []
        var hold = false
        var prepareError = false
        var drift = false
        var finish: String? = "stop"
        init(store: UseSessionStore, started: XCTestExpectation? = nil) { self.store = store; self.started = started }
        func setPrepareError(_ value: Bool) { prepareError = value }
        func setDrift(_ value: Bool) { drift = value }
        func setHold(_ value: Bool) { hold = value }
        func setFinish(_ value: String?) { finish = value }
        func prepare(_ server: ServerInfo) throws -> String? {
            if prepareError { throw ProbeHTTPError.httpStatus(401) }
            return "fixture-key"
        }
        func check(_ server: ServerInfo) throws { if drift { throw UseSessionError.changed } }
        func stream(_ server: ServerInfo, _ messages: [[String: JSONValue]], _ settings: UseRequestDefaults,
                    _ update: UseStreamUpdate) async throws -> ProbeSample {
            let selectedID = try await store.selectedID()
            let id = try XCTUnwrap(selectedID)
            let pending = try await store.record(id: id)
            XCTAssertEqual(pending?.turns.last?.state, .sending)
            XCTAssertEqual(pending?.wasSending, true)
            requests.append(messages)
            try await update("A saved answer", "")
            if requests.count == 1 { started?.fulfill() }
            if hold { try await Task.sleep(for: .seconds(30)) }
            return ProbeSample(text: "A saved answer", completionTokens: 3, timeToFirstTokenSeconds: 0.1,
                               durationSeconds: 0.2, metricsEstimated: false, finishReason: finish)
        }
    }

}

private final class UseChatHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-inference-key")
            var bytes = request.httpBody
            if bytes == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
                bytes = body
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(bytes)) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
            XCTAssertEqual(messages[1]["content"] as? String, "Saved")
            XCTAssertEqual(object["max_tokens"] as? Int, 512)
            XCTAssertEqual(object["temperature"] as? Double, 0.2)
            XCTAssertNil(object["previous_response_id"])
            XCTAssertNil(object["tools"])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"# + "\n\n"
                + #"data: {"choices":[{"delta":{"content":" there"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
