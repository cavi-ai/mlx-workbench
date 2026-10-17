import Foundation
import CryptoKit
import XCTest

@testable import mlx_workbench

final class InferenceTaskTests: XCTestCase {
    func testOptInRealEngineClassifierOrMusicTaskAcceptance() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let kindValue = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_KIND"],
              let modelPath = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_MODEL"] else {
            throw XCTSkip("Set the task acceptance kind and allowlisted model path to run real local inference.")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let allowedClassifier = repository.appendingPathComponent("vendor/mlx-agent/.run/phase1-models/laya-multilingual-MLX-8bit").path
        let allowedMusic = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".models/lmstudio/mlx-community/MiniMax-Music3-8bit").path
        let kind: TaskKind
        let request: TaskRequest
        switch kindValue {
        case "classification":
            guard modelPath == allowedClassifier else { throw XCTSkip("Classifier acceptance only permits the prepared local Laya model.") }
            kind = .classification
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: [
                "state": .string("A customer requests a refund for a duplicate monthly charge."),
                "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Route the support request to the correct team."), "criteria": .array([.string("billing"), .string("other")])])]),
            ])
        case "music_generation":
            guard modelPath == allowedMusic else { throw XCTSkip("Music acceptance only permits the prepared local MiniMax Music 3 model.") }
            kind = .musicGeneration
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: ["caption": .string("A short quiet piano instrumental")])
        default:
            throw XCTSkip("Only classification and music-generation acceptance are supported.")
        }
        let agentPath = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_AGENT"] ?? repository.appendingPathComponent("vendor/mlx-agent").path
        let stateRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/mlx-workbench-tests/real-task-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agentPath, taskStateDirectory: stateRoot)
        let started = try await api.taskStart(request)
        XCTAssertEqual(started.kind, kind)
        let deadline = Date().addingTimeInterval(20 * 60)
        var current = started
        while current.state.isActive && Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            current = try await api.taskStatus(id: started.id)
        }
        XCTAssertFalse(current.state.isActive, "Task \(started.id) did not reach a terminal state")
        XCTAssertEqual(current.state, .succeeded, current.error?.message ?? "Task failed without an engine error detail")
        let verifiedModel = try await api.taskVerifyModel(id: started.id)
        XCTAssertTrue(verifiedModel.matches)
        XCTAssertEqual(verifiedModel.modelPath, modelPath)

        let savedResult = try await api.taskResult(id: started.id)
        let resultRoot = stateRoot
        let verifiedJSON = try await TaskArtifactVerifier.verify(reference: savedResult.artifact, taskID: started.id, root: resultRoot)
        XCTAssertNotNil(verifiedJSON.json)
        if kind == .musicGeneration {
            let output = try XCTUnwrap(savedResult.result?.objectValue?["output_artifact"])
            let reference = try JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(output))
            let verifiedAudio = try await TaskArtifactVerifier.verify(reference: reference, taskID: started.id, root: resultRoot)
            XCTAssertEqual(verifiedAudio.url.pathExtension.lowercased(), "wav")
        }
    }

    func testVersionedTaskContractsDecodeAndPreserveUnsupportedValues() throws {
        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(TaskCapabilities.self, from: Data(#"{"schema":"task-capabilities/1","request_schema":"task-request/1","run_schema":"task-run/1","tasks":[{"kind":"classification","result_schema":"decide/1","cancellation":true,"requires_local_model":true}]}"#.utf8))
        XCTAssertTrue(capabilities.isSupported)
        XCTAssertEqual(capabilities.tasks.first?.kind, .classification)

        let request = try decoder.decode(TaskRequest.self, from: Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"/Models/music","parameters":{"caption":"quiet piano","future_setting":{"x":1}}}"#.utf8))
        XCTAssertTrue(request.isSupported)
        XCTAssertEqual(request.kind, .musicGeneration)
        XCTAssertEqual(request.parameters["future_setting"], .object(["x": .number(1)]))

        let unsupported = try decoder.decode(TaskRequest.self, from: Data(#"{"schema":"task-request/9","kind":"video_generation","model_path":"/Models/video","parameters":{}}"#.utf8))
        XCTAssertFalse(unsupported.isSupported)
        XCTAssertEqual(unsupported.kind, .unsupported("video_generation"))

        let record = try decoder.decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        XCTAssertTrue(record.isSupported)
        XCTAssertEqual(record.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(record.state, .starting)

        let unknownRecord = Self.publicSummary
            .replacingOccurrences(of: "\"state\":\"starting\"", with: "\"state\":\"paused\"")
            .replacingOccurrences(of: "\"kind\":\"classification\"", with: "\"kind\":\"video_generation\"")
        let decodedUnknown = try decoder.decode(TaskRecord.self, from: Data(unknownRecord.utf8))
        XCTAssertFalse(decodedUnknown.isSupported)
        XCTAssertEqual(decodedUnknown.state, .unsupported("paused"))
        XCTAssertEqual(decodedUnknown.kind, .unsupported("video_generation"))

        let result = try decoder.decode(TaskResultResponse.self, from: Data(#"{"task":\#(Self.publicSummary),"artifact":{"path":"/tasks/artifacts/11111111-1111-4111-8111-111111111111/result.json","sha256":"\#(String(repeating: "a", count: 64))","bytes":9},"inline":true,"result":{"answers":{"future":{"type":"new","future_metric":2}}}}"#.utf8))
        XCTAssertTrue(result.inline)
        XCTAssertEqual(result.result?.objectValue?["answers"]?.objectValue?["future"]?.objectValue?["future_metric"], .number(2))
    }

    func testResultProjectionKeepsUnknownFieldsAndMissingMetricsUnknown() throws {
        let raw = JSONValue.object([
            "answers": .object([
                "route": .object(["type": .string("choice"), "future_metric": .number(0.7)]),
                "rating": .object(["type": .string("score"), "score": .number(2.5), "legend": .object(["0": .string("low")]), "probabilities": .object(["0": .number(0.4)])]),
            ]),
            "future_top_level": .array([.string("preserved")]),
        ])
        let projection = TaskResultProjection(raw: raw)
        XCTAssertEqual(projection.raw, raw)
        XCTAssertEqual(projection.answers["route"]?.type, "choice")
        XCTAssertNil(projection.answers["route"]?.choice)
        XCTAssertNil(projection.answers["route"]?.confidence)
        XCTAssertEqual(projection.answers["rating"]?.score, 2.5)
        XCTAssertNil(projection.answers["rating"]?.confidence)
        XCTAssertEqual(projection.raw.objectValue?["future_top_level"], .array([.string("preserved")]))
    }

    func testArtifactVerifierAcceptsTaskOwnedJSONAndAudioAndDecodesRequest() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let request = Data(#"{"schema":"task-request/1","kind":"classification","model_path":"/Models/laya","parameters":{"state":"refund request","questions":{"route":{"type":"choice","instructions":"Route this request","criteria":["billing","other"]}}}}"#.utf8)
        let result = Data(#"{"answers":{"route":{"type":"choice","choice":"billing","future":true}}}"#.utf8)
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        let requestURL = try fixture.write("request.json", data: request)
        let resultURL = try fixture.write("result.json", data: result)
        let audioURL = try fixture.write("output.wav", data: audio)

        let verifiedRequest = try await TaskArtifactVerifier.verify(reference: fixture.reference(requestURL, data: request), taskID: fixture.taskID, root: fixture.root)
        XCTAssertEqual(verifiedRequest.request?.kind, .classification)
        XCTAssertEqual(verifiedRequest.data, request)
        let verifiedResult = try await TaskArtifactVerifier.verify(reference: fixture.reference(resultURL, data: result), taskID: fixture.taskID, root: fixture.root)
        XCTAssertEqual(verifiedResult.json?.objectValue?["answers"]?.objectValue?["route"]?.objectValue?["future"], .bool(true))
        let verifiedAudio = try await TaskArtifactVerifier.verify(reference: fixture.reference(audioURL, data: audio), taskID: fixture.taskID, root: fixture.root)
        XCTAssertEqual(verifiedAudio.url, audioURL)
        XCTAssertNil(verifiedAudio.json)
    }

    func testArtifactVerifierRejectsUnownedPathsChangedBytesAndInvalidRequests() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let valid = Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"/Models/music","parameters":{"caption":"music"}}"#.utf8)
        let path = try fixture.write("request.json", data: valid)
        let reference = fixture.reference(path, data: valid)

        await assertRejected(TaskArtifactReference(path: path.path + "/../request.json", sha256: reference.sha256, bytes: reference.bytes), taskID: fixture.taskID, root: fixture.root)
        await assertRejected(reference, taskID: "../\(fixture.taskID)", root: fixture.root)
        await assertRejected(TaskArtifactReference(path: path.path, sha256: String(repeating: "0", count: 64), bytes: reference.bytes), taskID: fixture.taskID, root: fixture.root)
        await assertRejected(TaskArtifactReference(path: path.path, sha256: reference.sha256, bytes: reference.bytes + 1), taskID: fixture.taskID, root: fixture.root)
        await assertRejected(TaskArtifactReference(path: fixture.root.appendingPathComponent("outside.json").path, sha256: reference.sha256, bytes: reference.bytes), taskID: fixture.taskID, root: fixture.root)

        let invalidRequest = Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"relative","parameters":{}}"#.utf8)
        try invalidRequest.write(to: path)
        await assertRejected(fixture.reference(path, data: invalidRequest), taskID: fixture.taskID, root: fixture.root)

        let missing = fixture.root.appendingPathComponent("artifacts/\(fixture.taskID)/missing.json")
        await assertRejected(TaskArtifactReference(path: missing.path, sha256: String(repeating: "a", count: 64), bytes: 0), taskID: fixture.taskID, root: fixture.root)
    }

    func testArtifactVerifierRejectsSymlinkAndNonRegularArtifact() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let data = Data("payload".utf8)
        let external = fixture.root.appendingPathComponent("outside")
        try data.write(to: external)
        let link = fixture.artifactDirectory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        await assertRejected(fixture.reference(link, data: data), taskID: fixture.taskID, root: fixture.root)

        let directory = fixture.artifactDirectory.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        await assertRejected(TaskArtifactReference(path: directory.path, sha256: String(repeating: "a", count: 64), bytes: 0), taskID: fixture.taskID, root: fixture.root)

        let intermediate = fixture.root.appendingPathComponent("artifacts/\(fixture.taskID)-link")
        try FileManager.default.createSymbolicLink(at: intermediate, withDestinationURL: fixture.artifactDirectory)
        let throughDirectoryLink = intermediate.appendingPathComponent("linked.json")
        await assertRejected(fixture.reference(throughDirectoryLink, data: data), taskID: fixture.taskID, root: fixture.root)
    }

    private func assertRejected(_ reference: TaskArtifactReference, taskID: String, root: URL, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await TaskArtifactVerifier.verify(reference: reference, taskID: taskID, root: root)
            XCTFail("Expected unsafe or invalid artifact to be rejected", file: file, line: line)
        } catch { }
    }

    private static let publicSummary = #"{"schema":"task-run/1","id":"11111111-1111-4111-8111-111111111111","kind":"classification","state":"starting","model_path":"/Models/laya","created_at":"2026-10-17T12:00:00+00:00","started_at":null,"completed_at":null,"cancel_requested":false,"identity":{"backend":"mlx-embeddings","backend_version":"1.0.0","engine_version":"0.7.0","python_version":"3.12.0","model_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"request":{"path":"/tasks/artifacts/11111111-1111-4111-8111-111111111111/request.json","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bytes":100},"result":null,"error":null,"supervisor":null,"execution":null,"execution_unresolved":false}"#
}

private struct ArtifactFixture {
    let root: URL
    let taskID = "11111111-1111-4111-8111-111111111111"
    let artifactDirectory: URL

    init() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/mlx-workbench-tests", isDirectory: true)
            .appendingPathComponent("mlx-task-artifact-test-\(UUID().uuidString)", isDirectory: true)
        artifactDirectory = root.appendingPathComponent("artifacts/\(taskID)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func write(_ name: String, data: Data) throws -> URL {
        let path = artifactDirectory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return path
    }

    func reference(_ path: URL, data: Data) -> TaskArtifactReference {
        TaskArtifactReference(path: path.path, sha256: data.sha256Hex, bytes: data.count)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
