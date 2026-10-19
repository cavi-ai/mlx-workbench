import Foundation
import CryptoKit
import AVFoundation
import AppKit
import XCTest

@testable import mlx_workbench

final class InferenceTaskTests: XCTestCase {
    func testOptInRealEngineMediaTaskAcceptance() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let kindValue = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_KIND"],
              let modelPath = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_MODEL"],
              let agentPath = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_AGENT"],
              let evidenceValue = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_EVIDENCE_ROOT"] else {
            throw XCTSkip("Set task kind, absolute model and engine paths, and an isolated evidence root to run local inference.")
        }
        let evidenceRoot = URL(fileURLWithPath: evidenceValue, isDirectory: true)
        guard evidenceRoot.path.hasPrefix("/"), modelPath.hasPrefix("/"), agentPath.hasPrefix("/") else {
            throw XCTSkip("Task acceptance paths must be explicit absolute paths.")
        }
        let kind: TaskKind
        let request: TaskRequest
        var ownedInput: URL?
        var suppliedInputDigest: String?
        switch kindValue {
        case "classification":
            kind = .classification
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: [
                "state": .string("A customer requests a refund for a duplicate monthly charge."),
                "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Route the support request to the correct team."), "criteria": .array([.string("billing"), .string("other")])])]),
            ])
        case "music_generation":
            kind = .musicGeneration
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: ["caption": .string("A short quiet piano instrumental")])
        case "transcribe":
            kind = .transcribe
            guard let inputValue = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_INPUT"] else {
                throw XCTSkip("Transcription acceptance requires an explicit absolute audio input path.")
            }
            let source = URL(fileURLWithPath: inputValue)
            let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard source.path.hasPrefix("/"), sourceValues.isRegularFile == true else {
                throw XCTSkip("Transcription input must be an explicit absolute regular file.")
            }
            try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try Data(contentsOf: source)
            suppliedInputDigest = Self.sha256(data)
            let owned = evidenceRoot.appendingPathComponent("submitted-input.wav")
            try data.write(to: owned, options: .atomic)
            ownedInput = owned
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: ["audio_path": .string(owned.path)])
        case "speak":
            kind = .speak
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: ["text": .string("This is a short speech acceptance check.")])
        case "image_generation":
            kind = .imageGeneration
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: [
                "prompt": .string("A red ceramic cup on a plain white table"),
                "width": .number(512), "height": .number(512), "steps": .number(20), "seed": .number(42),
            ])
        case "image_understanding":
            kind = .imageUnderstanding
            guard let inputValue = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_INPUT"] else {
                throw XCTSkip("Image understanding acceptance requires an explicit absolute PNG input path.")
            }
            let source = URL(fileURLWithPath: inputValue)
            let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard source.path.hasPrefix("/"), source.pathExtension.lowercased() == "png", sourceValues.isRegularFile == true,
                  CGImageSourceCreateWithURL(source as CFURL, nil) != nil else {
                throw XCTSkip("Image understanding input must be an explicit absolute regular PNG file.")
            }
            try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try Data(contentsOf: source)
            suppliedInputDigest = Self.sha256(data)
            let owned = evidenceRoot.appendingPathComponent("submitted-input.png")
            try data.write(to: owned, options: .atomic)
            ownedInput = owned
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: [
                "image_path": .string(owned.path),
                "prompt": .string("Describe the main subject and its visible colors."),
            ])
        default:
            throw XCTSkip("Unsupported media task acceptance kind.")
        }
        let stateRoot = evidenceRoot.appendingPathComponent("task-state", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agentPath, taskStateDirectory: stateRoot)
        let started = try await api.taskStart(request)
        XCTAssertEqual(started.kind, kind)
        let submittedInputPath = ownedInput?.path
        if let ownedInput {
            XCTAssertEqual(started.inputArtifact?.sha256, suppliedInputDigest,
                           "The task must retain the explicitly copied source before returning its ID.")
            XCTAssertNotEqual(started.inputArtifact?.path, ownedInput.path)
            try FileManager.default.removeItem(at: ownedInput)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ownedInput.path), "The engine must retain its accepted input before Start returns.")
        }
        var receipt = TaskAcceptanceReceipt(kind: kindValue, modelPath: modelPath, agentPath: agentPath,
                                            taskID: started.id, state: started.state.wireValue,
                                            identity: started.identity, requestArtifact: started.request,
                                            resultArtifact: started.result, resultDigest: nil,
                                            outputArtifact: nil, outputDigest: nil, inputArtifact: started.inputArtifact,
                                            inputDigest: started.inputArtifact?.sha256, suppliedInputDigest: suppliedInputDigest,
                                            submittedInputPath: submittedInputPath, transcript: nil, audioMetadata: nil, terminal: false)
        try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
        let deadline = Date().addingTimeInterval(20 * 60)
        var current = started
        while current.state.isActive && Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            current = try await api.taskStatus(id: started.id)
            receipt.state = current.state.wireValue
            receipt.identity = current.identity
            receipt.resultArtifact = current.result
            try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
        }
        if current.state.isActive {
            receipt.pendingFailure = "Task exceeded the 20-minute acceptance deadline; cancellation was requested and must settle before state cleanup."
            do {
                current = try await api.taskCancel(id: started.id)
                receipt.state = current.state.wireValue
                try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
            } catch {
                receipt.pendingFailure = "Task exceeded the deadline and cancellation could not settle: \(error.localizedDescription)"
                try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
                XCTFail(receipt.pendingFailure ?? "Cancellation did not settle")
                return
            }
            let cancelDeadline = Date().addingTimeInterval(60)
            while current.state.isActive && Date() < cancelDeadline {
                try await Task.sleep(for: .seconds(2))
                do { current = try await api.taskStatus(id: started.id) }
                catch {
                    receipt.pendingFailure = "Cancellation was requested but terminal status remains unknown: \(error.localizedDescription)"
                    try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
                    XCTFail(receipt.pendingFailure ?? "Cancellation status is unknown")
                    return
                }
                receipt.state = current.state.wireValue
                receipt.identity = current.identity
                receipt.resultArtifact = current.result
                try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
            }
            guard !current.state.isActive else {
                receipt.pendingFailure = "Cancellation was requested, but the engine still reports an active task. State was retained."
                try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
                XCTFail(receipt.pendingFailure ?? "Task cancellation remains active")
                return
            }
        }
        XCTAssertFalse(current.state.isActive, "Task \(started.id) did not reach a terminal state")
        XCTAssertEqual(current.state, .succeeded, current.error?.message ?? "Task failed without an engine error detail")
        let verifiedModel = try await api.taskVerifyModel(id: started.id)
        XCTAssertTrue(verifiedModel.matches)
        XCTAssertEqual(verifiedModel.modelPath, modelPath)

        let savedResult = try await api.taskResult(id: started.id)
        let verifiedJSON = try await TaskArtifactVerifier.verify(reference: savedResult.artifact, taskID: started.id, root: stateRoot)
        XCTAssertNotNil(verifiedJSON.json)
        receipt.resultArtifact = savedResult.artifact
        receipt.resultDigest = savedResult.artifact.sha256
        if kind == .transcribe {
            let text = try XCTUnwrap(savedResult.result?.objectValue?["text"]?.stringValue)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let returned = try XCTUnwrap(savedResult.result?.objectValue?["input_artifact"])
            let returnedReference = try JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(returned))
            XCTAssertEqual(returnedReference, started.inputArtifact)
            let retained = try XCTUnwrap(started.inputArtifact)
            let verifiedInput = try await TaskArtifactVerifier.verify(reference: retained, taskID: started.id, root: stateRoot)
            XCTAssertEqual(verifiedInput.reference.sha256, retained.sha256)
            receipt.inputArtifact = retained
            receipt.inputDigest = retained.sha256
            receipt.transcript = text
        } else if kind == .musicGeneration || kind == .speak {
            let output = try XCTUnwrap(savedResult.result?.objectValue?["output_artifact"])
            let reference = try JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(output))
            let verifiedAudio = try await TaskArtifactVerifier.verify(reference: reference, taskID: started.id, root: stateRoot)
            XCTAssertEqual(verifiedAudio.url.pathExtension.lowercased(), "wav")
            let audioFile = try AVAudioFile(forReading: verifiedAudio.url)
            XCTAssertGreaterThan(audioFile.length, 0)
            XCTAssertGreaterThan(audioFile.processingFormat.sampleRate, 0)
            XCTAssertGreaterThan(audioFile.processingFormat.channelCount, 0)
            receipt.outputArtifact = reference
            receipt.outputDigest = reference.sha256
            receipt.audioMetadata = ["frames": Int(audioFile.length), "sample_rate": Int(audioFile.processingFormat.sampleRate), "channels": Int(audioFile.processingFormat.channelCount)]
        } else if kind == .imageUnderstanding {
            let text = try XCTUnwrap(savedResult.result?.objectValue?["text"]?.stringValue)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let returned = try XCTUnwrap(savedResult.result?.objectValue?["input_artifact"])
            let returnedReference = try JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(returned))
            XCTAssertEqual(returnedReference, started.inputArtifact)
            let retained = try XCTUnwrap(started.inputArtifact)
            let verifiedInput = try await TaskArtifactVerifier.verifyPNG(reference: retained, taskID: started.id, root: stateRoot)
            XCTAssertEqual(verifiedInput.reference.sha256, suppliedInputDigest)
            receipt.inputArtifact = retained
            receipt.inputDigest = retained.sha256
            receipt.transcript = text
        } else if kind == .imageGeneration {
            let output = try XCTUnwrap(savedResult.result?.objectValue?["output_artifact"])
            let reference = try JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(output))
            let verifiedImage = try await TaskArtifactVerifier.verifyPNG(reference: reference, taskID: started.id, root: stateRoot)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(verifiedImage.url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 512)
            XCTAssertEqual(image.height, 512)
            receipt.outputArtifact = reference
            receipt.outputDigest = reference.sha256
            receipt.imageMetadata = ["width": image.width, "height": image.height]
        } else if kind == .classification {
            let answer = try XCTUnwrap(savedResult.result?.objectValue?["answers"]?.objectValue?["route"]?.objectValue?["choice"]?.stringValue)
            XCTAssertEqual(answer, "billing")
        }
        receipt.state = current.state.wireValue
        receipt.identity = current.identity
        receipt.terminal = !current.state.isActive
        try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
    }

    private static func write(_ receipt: TaskAcceptanceReceipt, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

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

    func testSpeechTaskCapabilitiesAndRequestsUsePerKindV2Schemas() throws {
        let json = #"{"schema":"task-capabilities/1","request_schema":"task-request/1","run_schema":"task-run/1","tasks":[{"kind":"classification","result_schema":"decide/1","cancellation":true,"requires_local_model":true},{"kind":"transcribe","result_schema":"transcribe/1","cancellation":true,"requires_local_model":true,"request_schema":"task-request/2","run_schema":"task-run/2"},{"kind":"speak","result_schema":"speak/1","cancellation":true,"requires_local_model":true,"request_schema":"task-request/2","run_schema":"task-run/2"}]}"#
        let capabilities = try JSONDecoder().decode(TaskCapabilities.self, from: Data(json.utf8))
        XCTAssertTrue(capabilities.isSupported)
        XCTAssertEqual(capabilities.requestSchema(for: .classification), "task-request/1")
        XCTAssertEqual(capabilities.runSchema(for: .classification), "task-run/1")
        XCTAssertEqual(capabilities.requestSchema(for: .transcribe), "task-request/2")
        XCTAssertEqual(capabilities.runSchema(for: .speak), "task-run/2")

        let transcribe = TaskRequest(kind: .transcribe, modelPath: "/Models/whisper", parameters: ["audio_path": .string("/tmp/input.wav")])
        XCTAssertEqual(transcribe.schema, "task-request/2")
        XCTAssertNoThrow(try transcribe.validate())
        let encodedTranscribe = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(transcribe)) as? [String: Any])
        let transcribeParameters = try XCTUnwrap(encodedTranscribe["parameters"] as? [String: Any])
        XCTAssertEqual(transcribeParameters["audio_path"] as? String, "/tmp/input.wav")
        XCTAssertNil(transcribeParameters["language"])

        let speak = TaskRequest(kind: .speak, modelPath: "/Models/tts", parameters: ["text": .string("A short test.")])
        XCTAssertEqual(speak.schema, "task-request/2")
        XCTAssertNoThrow(try speak.validate())
        let encodedSpeak = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(speak)) as? [String: Any])
        let speakParameters = try XCTUnwrap(encodedSpeak["parameters"] as? [String: Any])
        XCTAssertEqual(speakParameters["text"] as? String, "A short test.")
        XCTAssertNil(speakParameters["voice"])
        XCTAssertNil(speakParameters["speed"])
        XCTAssertNil(speakParameters["lang_code"])
    }

    func testImageTaskCapabilitiesAndRequestsUsePerKindV2Schemas() throws {
        let json = #"{"schema":"task-capabilities/1","request_schema":"task-request/1","run_schema":"task-run/1","tasks":[{"kind":"classification","result_schema":"decide/1","cancellation":true,"requires_local_model":true},{"kind":"image_generation","result_schema":"generate/1","cancellation":true,"requires_local_model":true,"request_schema":"task-request/2","run_schema":"task-run/2"},{"kind":"image_understanding","result_schema":"describe/1","cancellation":true,"requires_local_model":true,"request_schema":"task-request/2","run_schema":"task-run/2"}]}"#
        let capabilities = try JSONDecoder().decode(TaskCapabilities.self, from: Data(json.utf8))
        let generation = TaskKind.imageGeneration
        let understanding = TaskKind.imageUnderstanding
        XCTAssertEqual(capabilities.requestSchema(for: generation), "task-request/2")
        XCTAssertEqual(capabilities.runSchema(for: generation), "task-run/2")
        XCTAssertEqual(capabilities.requestSchema(for: understanding), "task-request/2")
        XCTAssertEqual(capabilities.runSchema(for: understanding), "task-run/2")

        let generate = try JSONDecoder().decode(TaskRequest.self, from: Data(#"{"schema":"task-request/2","kind":"image_generation","model_path":"/Models/qwen-image","parameters":{"prompt":"A red kite above a green field"}}"#.utf8))
        XCTAssertTrue(generate.isSupported)
        XCTAssertNoThrow(try generate.validate())
        XCTAssertEqual(generate.parameters, ["prompt": .string("A red kite above a green field")])

        let understand = try JSONDecoder().decode(TaskRequest.self, from: Data(#"{"schema":"task-request/2","kind":"image_understanding","model_path":"/Models/qwen-vl","parameters":{"image_path":"/Images/chart.png","prompt":"Read the chart title and values."}}"#.utf8))
        XCTAssertTrue(understand.isSupported)
        XCTAssertNoThrow(try understand.validate())
        XCTAssertEqual(Set(understand.parameters.keys), ["image_path", "prompt"])

        let invalid = try JSONDecoder().decode(TaskRequest.self, from: Data(#"{"schema":"task-request/2","kind":"image_understanding","model_path":"/Models/qwen-vl","parameters":{"image_path":"relative.png","prompt":"Describe it.","fps":1}}"#.utf8))
        XCTAssertThrowsError(try invalid.validate())
    }

    func testImageTaskDraftsOmitUnsetPlannerSettingsAndReuseRetainedInput() throws {
        let generation = try ImageGenerationTaskDraft(prompt: "A red kite above a green field").request(modelPath: "/Models/qwen-image")
        XCTAssertEqual(generation.parameters, ["prompt": .string("A red kite above a green field")])
        let configuredGeneration = try ImageGenerationTaskDraft(prompt: "A landscape", width: "512", height: "768", steps: "20", seed: "42")
            .request(modelPath: "/Models/qwen-image")
        XCTAssertEqual(configuredGeneration.parameters, [
            "prompt": .string("A landscape"), "width": .number(512), "height": .number(768),
            "steps": .number(20), "seed": .number(42),
        ])

        let imagePath = "/private/retained/input.png"
        let understanding = try ImageUnderstandingTaskDraft(imagePath: "/private/source/chart.png", prompt: "Read the chart.")
            .request(modelPath: "/Models/qwen-vl")
        XCTAssertEqual(understanding.parameters, [
            "image_path": .string("/private/source/chart.png"), "prompt": .string("Read the chart."),
        ])
        var reused = ImageUnderstandingTaskDraft()
        try reused.load(understanding, retainedImagePath: imagePath)
        XCTAssertEqual(reused.imagePath, imagePath)
        XCTAssertEqual(try reused.request(modelPath: "/Models/qwen-vl").parameters, [
            "image_path": .string(imagePath), "prompt": .string("Read the chart."),
        ])
    }

    @MainActor
    func testActiveTaskModelPathsRemainOccupiedUntilTerminal() async throws {
        let active = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let terminalJSON = Self.publicSummary
            .replacingOccurrences(of: "\"state\":\"starting\"", with: "\"state\":\"succeeded\"")
            .replacingOccurrences(of: "\"completed_at\":null", with: "\"completed_at\":\"2026-10-17T12:01:00+00:00\"")
        let terminal = try JSONDecoder().decode(TaskRecord.self, from: Data(terminalJSON.utf8))
        let api = FakeInferenceTaskAPI(record: active, capabilities: Self.taskCapabilities, listedRecords: [active])
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tmp/task-occupancy"))
        await coordinator.refreshRecent()
        XCTAssertEqual(coordinator.activeModelPaths, [active.modelPath])

        let completedAPI = FakeInferenceTaskAPI(record: terminal, capabilities: Self.taskCapabilities, listedRecords: [terminal])
        let completed = InferenceTaskCoordinator(api: completedAPI, artifactRoot: URL(fileURLWithPath: "/tmp/task-occupancy"))
        await completed.refreshRecent()
        XCTAssertTrue(completed.activeModelPaths.isEmpty)
    }

    func testArtifactVerifierDecodesOnlyTaskOwnedPNG() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let validData = try Self.pngData()
        let validURL = try fixture.write("output.png", data: validData)
        let valid = try await TaskArtifactVerifier.verifyPNG(reference: fixture.reference(validURL, data: validData), taskID: fixture.taskID, root: fixture.root)
        XCTAssertEqual(valid.url, validURL)

        let invalidData = Data("not a PNG".utf8)
        let invalidURL = try fixture.write("input.png", data: invalidData)
        await assertRejectedPNG(fixture.reference(invalidURL, data: invalidData), taskID: fixture.taskID, root: fixture.root)

        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: validData))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        let jpegURL = try fixture.write("input.jpg", data: jpeg)
        let verifiedJPEG = try await TaskArtifactVerifier.verifyImage(reference: fixture.reference(jpegURL, data: jpeg), taskID: fixture.taskID, root: fixture.root)
        XCTAssertEqual(verifiedJPEG.url, jpegURL)
        let mislabeledURL = try fixture.write("mislabeled.png", data: jpeg)
        await assertRejectedPNG(fixture.reference(mislabeledURL, data: jpeg), taskID: fixture.taskID, root: fixture.root)
    }

    @MainActor
    func testTaskImageArtifactRefusalAndExportProjection() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let request = TaskRequest(kind: .imageGeneration, modelPath: "/Models/qwen-image", parameters: ["prompt": .string("A lighthouse")])
        let requestData = try JSONEncoder().encode(request)
        let requestURL = try fixture.write("request.json", data: requestData)
        let requestRef = fixture.reference(requestURL, data: requestData)
        let record = try Self.taskRecordV2(id: fixture.taskID, kind: "image_generation", modelPath: request.modelPath, request: requestRef, input: nil)

        let png = try Self.pngData()
        let outputURL = try fixture.write("output.png", data: png)
        let outputRef = fixture.reference(outputURL, data: png)
        let outputValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(outputRef))
        let payload = JSONValue.object([
            "schema": .string("generate/1"), "width": .number(1), "height": .number(1),
            "prompt": .string("A lighthouse"), "output_artifact": outputValue,
        ])
        let resultData = try JSONEncoder().encode(payload)
        let resultURL = try fixture.write("result.json", data: resultData)
        let response = TaskResultResponse(task: record, artifact: fixture.reference(resultURL, data: resultData), inline: true, result: payload)
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, resultResponse: response)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: fixture.root)

        await coordinator.inspect(id: record.id)
        let verifiedOutputURL = coordinator.verifiedOutput?.url
        XCTAssertEqual(verifiedOutputURL, outputURL)

        let exportedURL = fixture.root.appendingPathComponent("exports/image.png")
        try await coordinator.exportImage(id: record.id, to: exportedURL)
        XCTAssertEqual(try Data(contentsOf: exportedURL), png)
        let jsonURL = fixture.root.appendingPathComponent("exports/result.json")
        try await coordinator.export(id: record.id, to: jsonURL)
        let exported = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: jsonURL))
        XCTAssertEqual(exported.objectValue?["width"], .number(1))
        XCTAssertNil(exported.objectValue?["prompt"])
        XCTAssertNil(exported.objectValue?["output_artifact"])

        let forgedInput = fixture.reference(fixture.artifactDirectory.appendingPathComponent("input.png"), data: png)
        let forgedValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(forgedInput))
        let wrongPayload = JSONValue.object(["output_artifact": forgedValue])
        let wrongData = try JSONEncoder().encode(wrongPayload)
        let wrongURL = try fixture.write("wrong-result.json", data: wrongData)
        let wrongResponse = TaskResultResponse(task: record, artifact: fixture.reference(wrongURL, data: wrongData), inline: true, result: wrongPayload)
        let wrongCoordinator = InferenceTaskCoordinator(api: FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, resultResponse: wrongResponse), artifactRoot: fixture.root)
        do {
            try await wrongCoordinator.exportImage(id: record.id, to: fixture.root.appendingPathComponent("exports/forged.png"))
            XCTFail("An image-generation task cannot export its input as generated output")
        } catch { }
    }

    @MainActor
    func testImageUnderstandingRequiresMatchingRetainedPNGAndKeepsFullAnswer() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let request = TaskRequest(kind: .imageUnderstanding, modelPath: "/Models/qwen-vl", parameters: [
            "image_path": .string("/incoming/chart.png"), "prompt": .string("Read every visible chart label."),
        ])
        let requestData = try JSONEncoder().encode(request)
        let requestRef = fixture.reference(try fixture.write("request.json", data: requestData), data: requestData)
        let imageData = try Self.pngData()
        let inputRef = fixture.reference(try fixture.write("input.png", data: imageData), data: imageData)
        let record = try Self.taskRecordV2(id: fixture.taskID, kind: "image_understanding", modelPath: request.modelPath,
                                           request: requestRef, input: inputRef)
        let inputValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(inputRef))
        let answer = "The chart title is Revenue. Values rise from 12 to 18 across the two visible quarters."
        let payload = JSONValue.object(["schema": .string("describe/1"), "text": .string(answer), "input_artifact": inputValue])
        let resultData = try JSONEncoder().encode(payload)
        let resultRef = fixture.reference(try fixture.write("result.json", data: resultData), data: resultData)
        let response = TaskResultResponse(task: record, artifact: resultRef, inline: true, result: payload)
        let coordinator = InferenceTaskCoordinator(api: FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities,
                                                                               resultResponse: response), artifactRoot: fixture.root)

        await coordinator.inspect(id: record.id)

        XCTAssertNil(coordinator.readError)
        XCTAssertEqual(coordinator.verifiedInput?.url, URL(fileURLWithPath: inputRef.path))
        XCTAssertEqual(coordinator.verifiedResult?.json?.objectValue?["text"]?.stringValue, answer)

        let mismatchedPayload = JSONValue.object(["schema": .string("describe/1"), "text": .string("unverified"),
                                                   "input_artifact": .object(["path": .string("/outside/input.png")])])
        let mismatchedData = try JSONEncoder().encode(mismatchedPayload)
        let mismatchedRef = fixture.reference(try fixture.write("mismatched-result.json", data: mismatchedData), data: mismatchedData)
        let mismatchedResponse = TaskResultResponse(task: record, artifact: mismatchedRef, inline: true, result: mismatchedPayload)
        let mismatch = InferenceTaskCoordinator(api: FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities,
                                                                            resultResponse: mismatchedResponse), artifactRoot: fixture.root)
        await mismatch.inspect(id: record.id)
        XCTAssertNil(mismatch.selectedResult)
        XCTAssertNil(mismatch.verifiedResult)
        XCTAssertNotNil(mismatch.readError)
    }

    func testSpeechDraftsOmitUnsetSettingsAndTranscribeReuseUsesRetainedInput() throws {
        let transcribe = try TranscribeTaskDraft(audioPath: "/private/source.wav").request(modelPath: "/Models/whisper")
        XCTAssertEqual(transcribe.parameters, ["audio_path": .string("/private/source.wav")])
        let speak = try SpeakTaskDraft(text: "Read this.").request(modelPath: "/Models/tts")
        XCTAssertEqual(speak.parameters, ["text": .string("Read this.")])

        let recorded = TaskRequest(kind: .transcribe, modelPath: "/Models/whisper", parameters: [
            "audio_path": .string("/private/source.wav"), "language": .string("en"),
        ])
        var reused = TranscribeTaskDraft(audioPath: "/other.wav")
        try reused.load(recorded, retainedAudioPath: "/state/artifacts/11111111-1111-4111-8111-111111111111/input.wav")
        XCTAssertEqual(reused.audioPath, "/state/artifacts/11111111-1111-4111-8111-111111111111/input.wav")
        XCTAssertEqual(reused.language, "en")
    }

    func testUntouchedSpeechFormsHaveNoInputToValidate() {
        XCTAssertFalse(SpeakTaskDraft().hasInput)
        XCTAssertNotNil(SpeakTaskDraft().validationError)
        XCTAssertTrue(SpeakTaskDraft(voice: "af_heart").hasInput)
        XCTAssertTrue(TranscribeTaskDraft().audioPath.isEmpty)
    }

    func testTaskRunV2DecodesCanonicalNullableInputArtifactAndKeepsV1Support() throws {
        let recordV2 = Self.publicSummary
            .replacingOccurrences(of: "task-run/1", with: "task-run/2")
            .replacingOccurrences(of: "classification", with: "transcribe")
            .replacingOccurrences(of: "\"execution_unresolved\":false", with: "\"execution_unresolved\":false,\"input_artifact\":{\"path\":\"/tasks/artifacts/11111111-1111-4111-8111-111111111111/input.wav\",\"sha256\":\"\(String(repeating: "b", count: 64))\",\"bytes\":32}")
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: Data(recordV2.utf8))
        XCTAssertTrue(decoded.isSupported)
        XCTAssertEqual(decoded.schema, "task-run/2")
        XCTAssertEqual(decoded.inputArtifact?.bytes, 32)
        XCTAssertTrue(try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8)).isSupported)
    }

    func testResultProjectionKeepsUnknownFieldsAndMissingMetricsUnknown() throws {
        let raw = JSONValue.object([
            "answers": .object([
                "route": .object(["type": .string("choice"), "choice": .string("billing"), "confidence": .number(0.8),
                                  "probabilities": .object(["billing": .number(0.8)]), "future_metric": .number(0.7)]),
                "rating": .object(["type": .string("score"), "score": .number(2.5), "legend": .object(["0": .string("low")]), "probabilities": .object(["0": .number(0.4)])]),
            ]),
            "future_top_level": .array([.string("preserved")]),
        ])
        let projection = TaskResultProjection(raw: raw)
        XCTAssertEqual(projection.raw, raw)
        XCTAssertEqual(projection.answers["route"]?.type, "choice")
        XCTAssertEqual(projection.answers["route"]?.choice, "billing")
        XCTAssertEqual(projection.answers["route"]?.confidence, 0.8)
        XCTAssertEqual(projection.answers["route"]?.probabilities?["billing"], .number(0.8))
        XCTAssertEqual(projection.answers["rating"]?.score, 2.5)
        XCTAssertNil(projection.answers["rating"]?.confidence)
        XCTAssertEqual(projection.answers["rating"]?.legend?["0"], .string("low"))
        XCTAssertEqual(projection.raw.objectValue?["future_top_level"], .array([.string("preserved")]))
    }

    func testClassificationDraftSerializesOrderedChoiceScoreAndNoulQuestions() throws {
        var draft = ClassificationDraft(state: "Refund request", questions: [])
        draft.questions = [
            ClassificationQuestionDraft(name: "route", instructions: "Choose a team", type: .choice, options: ["billing", "support"]),
            ClassificationQuestionDraft(name: "urgency", instructions: "Rate the urgency", type: .score, options: ["low", "medium", "high"]),
            ClassificationQuestionDraft(name: "duplicate", instructions: "Is this duplicated?", type: .noul,
                                        falseDescription: "No duplicate", trueDescription: "Duplicate charge"),
        ]
        let request = try draft.request(modelPath: "/Models/laya")
        XCTAssertEqual(request.parameters["state"], .string("Refund request"))
        let questions = try XCTUnwrap(request.parameters["questions"]?.objectValue)
        XCTAssertEqual(questions["route"]?.objectValue?["criteria"], .array([.string("billing"), .string("support")]))
        XCTAssertEqual(questions["urgency"]?.objectValue?["criteria"], .array([.string("low"), .string("medium"), .string("high")]))
        XCTAssertEqual(questions["duplicate"]?.objectValue?["criteria"]?.objectValue?["true"], .string("Duplicate charge"))
    }

    func testReuseRefusesUnsupportedStructuredStateWithoutReplacingDraft() throws {
        let originalState = "keep this draft"
        var draft = ClassificationDraft(state: originalState)
        let request = TaskRequest(kind: .classification, modelPath: "/Models/laya", parameters: [
            "state": .object(["ticket": .string("refund")]),
            "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Route"), "criteria": .array([.string("billing"), .string("other")])])]),
        ])
        XCTAssertThrowsError(try draft.load(request))
        XCTAssertEqual(draft.state, originalState)
        let unknownQuestionValue = TaskRequest(kind: .classification, modelPath: "/Models/laya", parameters: [
            "state": .string("ticket"),
            "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Route"), "criteria": .array([.string("billing"), .string("other")]), "future_semantics": .object(["weight": .number(2)])])]),
        ])
        XCTAssertThrowsError(try draft.load(unknownQuestionValue))
        XCTAssertEqual(draft.state, originalState)
    }

    func testMusicDraftUsesEngineInstrumentalDefaultsAndValidatesRanges() throws {
        var draft = MusicTaskDraft(caption: "Quiet piano")
        let request = try draft.request(modelPath: "/Models/music")
        XCTAssertNil(request.parameters["lyrics"])
        XCTAssertEqual(request.parameters["duration"], .number(15))
        XCTAssertEqual(request.parameters["steps"], .number(30))
        XCTAssertEqual(request.parameters["seed"], .number(42))
        draft.duration = 361
        XCTAssertThrowsError(try draft.request(modelPath: "/Models/music"))
    }

    func testInvalidMusicReuseLeavesExistingDraftUntouched() throws {
        var draft = MusicTaskDraft(caption: "Keep this setup", lyrics: "Keep these words", duration: 8, steps: 12, seed: 7)
        let invalid = TaskRequest(kind: .musicGeneration, modelPath: "/Models/music", parameters: [
            "caption": .string("Invalid recorded setup"), "duration": .number(361),
        ])
        XCTAssertThrowsError(try draft.load(invalid))
        XCTAssertEqual(draft.caption, "Keep this setup")
        XCTAssertEqual(draft.lyrics, "Keep these words")
        XCTAssertEqual(draft.duration, 8)
        XCTAssertEqual(draft.steps, 12)
        XCTAssertEqual(draft.seed, 7)
    }

    @MainActor
    func testCoordinatorStartsOnlyReadyMatchingModelAndRetainsDraft() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        coordinator.classificationDraft.state = "Refund request"
        coordinator.classificationDraft.questions[0].instructions = "Choose the correct team"
        let model = Self.libraryModel(type: .classification)
        await coordinator.start(kind: .classification, model: model)
        let evidence = await api.startEvidence()
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.parameters["state"], .string("Refund request"))
        let selectedID = coordinator.selectedTask?.id
        let retainedState = coordinator.classificationDraft.state
        XCTAssertEqual(selectedID, record.id)
        XCTAssertEqual(retainedState, "Refund request")

        let wrongType = Self.libraryModel(type: .musicGeneration)
        await coordinator.start(kind: .classification, model: wrongType)
        let afterWrongType = await api.startEvidence()
        XCTAssertEqual(afterWrongType.count, 1)
    }

    @MainActor
    func testCoordinatorKeepsUnknownStartUnownedUntilExplicitRefresh() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, startUnknown: true)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        coordinator.classificationDraft.state = "Refund request"
        coordinator.classificationDraft.questions[0].instructions = "Choose the correct team"
        await coordinator.start(kind: .classification, model: Self.libraryModel(type: .classification))
        let unknownBeforeRefresh = coordinator.startOutcomeUnknown
        let selectedBeforeRefresh = coordinator.selectedTask
        let recentBeforeRefresh = coordinator.recent
        XCTAssertTrue(unknownBeforeRefresh)
        XCTAssertNil(selectedBeforeRefresh)
        XCTAssertTrue(recentBeforeRefresh.isEmpty)
        await coordinator.refreshRecent()
        let unknownAfterRefresh = coordinator.startOutcomeUnknown
        let recentAfterRefresh = coordinator.recent
        XCTAssertFalse(unknownAfterRefresh)
        XCTAssertTrue(recentAfterRefresh.isEmpty)
    }

    @MainActor
    func testCancelIntentIsClearedWhenCapabilitiesRejectOrFailBeforeStart() async throws {
        let rejected = try JSONDecoder().decode(TaskCapabilities.self, from: Data(#"{"schema":"task-capabilities/1","request_schema":"task-request/1","run_schema":"task-run/1","tasks":[]}"#.utf8))
        let activeRecord = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        for failure in [FakeInferenceTaskAPI.FirstCapabilityOutcome.rejected, .failed] {
            let api = FakeInferenceTaskAPI(record: activeRecord, capabilities: Self.taskCapabilities,
                                           firstCapabilities: rejected, firstCapabilityOutcome: failure,
                                           gateFirstCapabilities: true)
            let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
            coordinator.classificationDraft.state = "Refund request"
            coordinator.classificationDraft.questions[0].instructions = "Choose the correct team"
            let model = Self.libraryModel(type: .classification)
            let attempt = Task { await coordinator.start(kind: .classification, model: model) }
            await api.waitForFirstCapabilities()
            coordinator.requestCancelDuringStart()
            await api.releaseFirstCapabilities()
            await attempt.value

            let pendingAfterFailure = coordinator.cancellationPending
            XCTAssertFalse(pendingAfterFailure)
            let nextAttempt = Task { await coordinator.start(kind: .classification, model: model) }
            await nextAttempt.value
            let cancelledIDs = await api.cancelledIDs()
            XCTAssertTrue(cancelledIDs.isEmpty)
        }
    }

    @MainActor
    func testCancelDuringStartUsesOnlyTheReturnedTaskID() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, gateFirstCapabilities: true)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        coordinator.classificationDraft.state = "Refund request"
        coordinator.classificationDraft.questions[0].instructions = "Choose the correct team"
        let attempt = Task { await coordinator.start(kind: .classification, model: Self.libraryModel(type: .classification)) }
        await api.waitForFirstCapabilities()
        coordinator.requestCancelDuringStart()
        await api.releaseFirstCapabilities()
        await attempt.value

        let cancelledIDs = await api.cancelledIDs()
        XCTAssertEqual(cancelledIDs, [record.id])
    }

    @MainActor
    func testReuseUsesTheClickedRecentRecordWithoutASelectedTask() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let model = Self.libraryModel(type: .classification)
        let request = TaskRequest(kind: .classification, modelPath: model.item.path, parameters: [
            "state": .string("Refund request from the history row"),
            "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Choose a team"), "criteria": .array([.string("billing"), .string("support")])])]),
        ])
        let requestData = try JSONEncoder().encode(request)
        let requestURL = try fixture.write("request.json", data: requestData)
        let reference = fixture.reference(requestURL, data: requestData)
        let record = try Self.taskRecord(id: fixture.taskID, kind: "classification", state: "succeeded",
                                         modelPath: model.item.path, request: reference)
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, listedRecords: [record])
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: fixture.root)
        await coordinator.refreshRecent()
        let selectionBeforeReuse = coordinator.selectedTask
        XCTAssertNil(selectionBeforeReuse)

        await coordinator.reuse(id: record.id, for: model)

        let reusedState = coordinator.classificationDraft.state
        let error = coordinator.error
        XCTAssertEqual(reusedState, "Refund request from the history row")
        XCTAssertNil(error)
    }

    func testRecentTaskHistoryIsGlobalInToolbarAndScopedInInspector() throws {
        let decoder = JSONDecoder()
        let first = try decoder.decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let secondJSON = Self.publicSummary
            .replacingOccurrences(of: first.id, with: "22222222-2222-4222-8222-222222222222")
            .replacingOccurrences(of: "/Models/laya", with: "/Models/other")
        let second = try decoder.decode(TaskRecord.self, from: Data(secondJSON.utf8))
        let records = [first, second]
        let selectedModel = Self.libraryModel(type: .classification, path: first.modelPath)

        let toolbarTasks = RecentTaskList.visibleTasks(in: records, for: nil)
        let inspectorTasks = RecentTaskList.visibleTasks(in: records, for: selectedModel)

        XCTAssertEqual(toolbarTasks.map(\.id), [first.id, second.id])
        XCTAssertEqual(inspectorTasks.map(\.id), [first.id])
        XCTAssertNil(RecentTaskList.visibleSelectedTask(second, in: inspectorTasks))
        XCTAssertEqual(RecentTaskList.visibleSelectedTask(first, in: inspectorTasks)?.id, first.id)
    }

    @MainActor
    func testStatusReadFailureKeepsLastKnownTaskAndShowsReadError() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, listedRecords: [record], statusFails: true)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        await coordinator.refreshRecent()
        await coordinator.selectTask(id: record.id)

        let selectedID = coordinator.selectedTask?.id
        let readError = coordinator.readError
        XCTAssertEqual(selectedID, record.id)
        XCTAssertNotNil(readError)
        await api.allowStatusReads()
        await coordinator.refresh(id: record.id)
        let recoveredError = coordinator.readError
        XCTAssertNil(recoveredError)
    }

    @MainActor
    func testHistoryReadFailureKeepsLastKnownRowsAndCanRetry() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, listedRecords: [record])
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        await coordinator.refreshRecent()
        await api.failListReads()
        await coordinator.refreshRecent()
        let staleRows = coordinator.recent
        let readError = coordinator.readError
        XCTAssertEqual(staleRows.map(\.id), [record.id])
        XCTAssertNotNil(readError)
        await api.allowListReads()
        await coordinator.refreshRecent()
        let recoveredRows = coordinator.recent
        let recoveredError = coordinator.readError
        XCTAssertEqual(recoveredRows.map(\.id), [record.id])
        XCTAssertNil(recoveredError)
    }

    @MainActor
    func testPollingStopsAfterExplicitDeactivation() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, listedRecords: [record])
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"), pollInterval: .milliseconds(1))
        await coordinator.refreshRecent()
        await coordinator.selectTask(id: record.id)
        let callsBeforePolling = await api.statusCallCount()
        coordinator.startPolling(id: record.id, owner: "model-inspector")
        await api.waitForStatusCall(after: callsBeforePolling)
        coordinator.startPolling(id: record.id, owner: "recent-task-sheet")
        coordinator.stopPolling(owner: "recent-task-sheet")
        let callsAfterSheetCloses = await api.statusCallCount()
        await api.waitForStatusCall(after: callsAfterSheetCloses)
        let callsAfterInspectorContinues = await api.statusCallCount()
        XCTAssertGreaterThan(callsAfterInspectorContinues, callsAfterSheetCloses)
        coordinator.stopPolling(owner: "model-inspector")
        let callsAtStop = await api.statusCallCount()
        try await Task.sleep(for: .milliseconds(20))
        let callsAfterStop = await api.statusCallCount()
        XCTAssertEqual(callsAfterStop, callsAtStop)
    }

    @MainActor
    func testExportAudioCopiesOnlyVerifiedTaskOwnedWAV() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let request = TaskRequest(kind: .musicGeneration, modelPath: "/Models/music", parameters: ["caption": .string("Quiet piano")])
        let requestData = try JSONEncoder().encode(request)
        let requestURL = try fixture.write("request.json", data: requestData)
        let requestReference = fixture.reference(requestURL, data: requestData)
        let record = try Self.taskRecord(id: fixture.taskID, kind: "music_generation", state: "succeeded",
                                         modelPath: request.modelPath, request: requestReference)
        let audioData = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        let audioURL = try fixture.write("output.wav", data: audioData)
        let audioReference = fixture.reference(audioURL, data: audioData)
        let encodedReference = try JSONEncoder().encode(audioReference)
        let outputValue = try JSONDecoder().decode(JSONValue.self, from: encodedReference)
        let resultData = try JSONEncoder().encode(JSONValue.object(["output_artifact": outputValue]))
        let resultURL = try fixture.write("result.json", data: resultData)
        let resultReference = fixture.reference(resultURL, data: resultData)
        let response = TaskResultResponse(task: record, artifact: resultReference, inline: true,
                                          result: .object(["output_artifact": outputValue]))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, resultResponse: response)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: fixture.root)
        let destination = fixture.root.appendingPathComponent("exports/result.wav")

        try await coordinator.exportAudio(id: record.id, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), audioData)
    }

    @MainActor
    func testTaskResultExportOmitsSourcePathsAndArtifactReferences() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let requestData = Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"/Models/music","parameters":{"caption":"quiet piano"}}"#.utf8)
        let requestURL = try fixture.write("request.json", data: requestData)
        let requestReference = fixture.reference(requestURL, data: requestData)
        let record = try Self.taskRecord(id: fixture.taskID, kind: "music_generation", state: "succeeded", modelPath: "/Models/music", request: requestReference)
        let payload = JSONValue.object([
            "schema": .string("speak/1"), "text": .string("hello"), "seconds": .number(1.2),
            "audio": .string("/private/tasks/artifacts/\(fixture.taskID)/input.wav"),
            "model": .string("/private/model"), "path": .string("/private/output.wav"),
            "prompt": .string("private input"), "request": .object(["text": .string("private input")]),
            "input_artifact": .object(["path": .string("/private/input.wav")]),
            "output_artifact": .object(["path": .string("/private/output.wav")]),
        ])
        let resultData = try JSONEncoder().encode(payload)
        let resultURL = try fixture.write("result.json", data: resultData)
        let reference = fixture.reference(resultURL, data: resultData)
        let response = TaskResultResponse(task: record, artifact: reference, inline: true, result: payload)
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, resultResponse: response)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: fixture.root)
        let destination = fixture.root.appendingPathComponent("exports/result.json")

        try await coordinator.export(id: record.id, to: destination)

        let exported = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: destination))
        XCTAssertEqual(exported.objectValue?["text"], .string("hello"))
        XCTAssertEqual(exported.objectValue?["seconds"], .number(1.2))
        XCTAssertNil(exported.objectValue?["path"])
        XCTAssertNil(exported.objectValue?["model"])
        XCTAssertNil(exported.objectValue?["input_artifact"])
        XCTAssertNil(exported.objectValue?["output_artifact"])
        XCTAssertNil(exported.objectValue?["prompt"])
        XCTAssertNil(exported.objectValue?["request"])
        XCTAssertNil(exported.objectValue?["audio"])
    }

    @MainActor
    func testInspectRejectsInlineResultThatDiffersFromVerifiedArtifact() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let requestData = Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"/Models/music","parameters":{"caption":"quiet piano"}}"#.utf8)
        let requestURL = try fixture.write("request.json", data: requestData)
        let requestReference = fixture.reference(requestURL, data: requestData)
        let record = try Self.taskRecord(id: fixture.taskID, kind: "music_generation", state: "succeeded",
                                         modelPath: "/Models/music", request: requestReference)
        let verifiedPayload = JSONValue.object(["text": .string("Verified transcript")])
        let resultData = try JSONEncoder().encode(verifiedPayload)
        let resultURL = try fixture.write("result.json", data: resultData)
        let resultReference = fixture.reference(resultURL, data: resultData)
        let response = TaskResultResponse(task: record, artifact: resultReference, inline: true,
                                          result: .object(["text": .string("Forged transcript")]))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, resultResponse: response)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: fixture.root)

        await coordinator.inspect(id: record.id)

        XCTAssertNil(coordinator.selectedResult)
        XCTAssertNil(coordinator.verifiedResult)
        XCTAssertNotNil(coordinator.readError)
    }

    @MainActor
    func testTranscribeInputArtifactCannotBePresentedOrExportedAsGeneratedOutput() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let request = TaskRequest(kind: .transcribe, modelPath: "/Models/whisper", parameters: ["audio_path": .string("/incoming/input.wav")])
        let requestData = try JSONEncoder().encode(request)
        let requestURL = try fixture.write("request.json", data: requestData)
        let requestReference = fixture.reference(requestURL, data: requestData)
        let inputData = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        let inputURL = try fixture.write("input.wav", data: inputData)
        let inputReference = fixture.reference(inputURL, data: inputData)
        let v1Record = try Self.taskRecord(id: fixture.taskID, kind: "transcribe", state: "succeeded",
                                           modelPath: request.modelPath, request: requestReference)
        var recordObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(v1Record)) as? [String: Any])
        recordObject["schema"] = "task-run/2"
        recordObject["input_artifact"] = ["path": inputReference.path, "sha256": inputReference.sha256, "bytes": inputReference.bytes]
        let record = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: recordObject))
        let inputValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(inputReference))
        let resultPayload = JSONValue.object([
            "text": .string("A retained transcript"),
            "input_artifact": inputValue,
            "output_artifact": inputValue,
        ])
        let resultData = try JSONEncoder().encode(resultPayload)
        let resultURL = try fixture.write("result.json", data: resultData)
        let resultReference = fixture.reference(resultURL, data: resultData)
        let response = TaskResultResponse(task: record, artifact: resultReference, inline: true, result: resultPayload)
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, resultResponse: response)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: fixture.root)

        await coordinator.inspect(id: record.id)

        XCTAssertNotNil(coordinator.verifiedInput)
        XCTAssertNil(coordinator.verifiedOutput)
        do {
            try await coordinator.exportAudio(id: record.id, to: fixture.root.appendingPathComponent("exports/output.wav"))
            XCTFail("Transcription input audio must not be exported as generated audio")
        } catch { }
    }

    private static let taskCapabilities = try! JSONDecoder().decode(TaskCapabilities.self, from: Data(#"{"schema":"task-capabilities/1","request_schema":"task-request/1","run_schema":"task-run/1","tasks":[{"kind":"classification","result_schema":"decide/1","cancellation":true,"requires_local_model":true,"model_verification":true},{"kind":"music_generation","result_schema":"music/1","cancellation":true,"requires_local_model":true,"model_verification":true}]}"#.utf8))

    private static func libraryModel(type: ModelTaskType, path: String? = nil) -> LibraryModel {
        let item = ModelItem(path: path ?? "/Models/\(type.rawValue)", name: "local-model", bytes: 100, modifiedAt: nil,
                             shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil,
                             structure: nil, signature: nil, companion: nil, readable: true, status: "ready",
                             outputs: [], tensorCount: nil, error: nil,
                             task: ModelTask(type: type, useCases: [], source: "test", confidence: "high"))
        return LibraryModel(item: item, readiness: .ready)
    }

    private static func taskRecord(id: String, kind: String, state: String, modelPath: String,
                                   request: TaskArtifactReference) throws -> TaskRecord {
        let summary = #"{"schema":"task-run/1","id":"\#(id)","kind":"\#(kind)","state":"\#(state)","model_path":"\#(modelPath)","created_at":"2026-10-17T12:00:00+00:00","started_at":null,"completed_at":"2026-10-17T12:01:00+00:00","cancel_requested":false,"identity":{"backend":"mlx-embeddings","backend_version":"1.0.0","engine_version":"0.7.0","python_version":"3.12.0","model_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"request":{"path":"\#(request.path)","sha256":"\#(request.sha256)","bytes":\#(request.bytes)},"result":null,"error":null,"supervisor":null,"execution":null,"execution_unresolved":false}"#
        return try JSONDecoder().decode(TaskRecord.self, from: Data(summary.utf8))
    }

    private static func taskRecordV2(id: String, kind: String, modelPath: String, request: TaskArtifactReference,
                                     input: TaskArtifactReference?) throws -> TaskRecord {
        let base = try taskRecord(id: id, kind: kind, state: "succeeded", modelPath: modelPath, request: request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        object["schema"] = "task-run/2"
        object["input_artifact"] = input.map { ["path": $0.path, "sha256": $0.sha256, "bytes": $0.bytes] as [String: Any] } ?? NSNull()
        return try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func pngData() throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 4, bitsPerPixel: 32))
        image.setColor(.systemRed, atX: 0, y: 0)
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    private func assertRejectedPNG(_ reference: TaskArtifactReference, taskID: String, root: URL,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await TaskArtifactVerifier.verifyPNG(reference: reference, taskID: taskID, root: root)
            XCTFail("Expected a corrupt PNG to be rejected", file: file, line: line)
        } catch { }
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

        let extraMember = Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"/Models/music","parameters":{"caption":"music"},"future_semantics":{"mode":"x"}}"#.utf8)
        try extraMember.write(to: path)
        await assertRejected(fixture.reference(path, data: extraMember), taskID: fixture.taskID, root: fixture.root)

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

        let pipe = fixture.artifactDirectory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        await assertRejected(TaskArtifactReference(path: pipe.path, sha256: String(repeating: "a", count: 64), bytes: 0), taskID: fixture.taskID, root: fixture.root)

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

private actor FakeInferenceTaskAPI: InferenceTaskAPI {
    enum FirstCapabilityOutcome { case rejected, failed }

    private let record: TaskRecord
    private let capabilities: TaskCapabilities
    private let startUnknown: Bool
    private let firstCapabilities: TaskCapabilities?
    private let firstCapabilityOutcome: FirstCapabilityOutcome?
    private let gateFirstCapabilities: Bool
    private let listedRecords: [TaskRecord]
    private var statusFails: Bool
    private var listFails = false
    private let resultResponse: TaskResultResponse?
    private var requests: [TaskRequest] = []
    private var capabilityCalls = 0
    private var firstCapabilitiesReached = false
    private var firstCapabilitiesWaiter: CheckedContinuation<Void, Never>?
    private var firstCapabilitiesRelease: CheckedContinuation<Void, Never>?
    private var statusCalls = 0
    private var statusWaiter: CheckedContinuation<Void, Never>?
    private var statusWaitAfter = 0
    private var cancelled: [String] = []

    init(record: TaskRecord, capabilities: TaskCapabilities, startUnknown: Bool = false,
         firstCapabilities: TaskCapabilities? = nil, firstCapabilityOutcome: FirstCapabilityOutcome? = nil,
         gateFirstCapabilities: Bool = false, listedRecords: [TaskRecord] = [], statusFails: Bool = false,
         resultResponse: TaskResultResponse? = nil) {
        self.record = record
        self.capabilities = capabilities
        self.startUnknown = startUnknown
        self.firstCapabilities = firstCapabilities
        self.firstCapabilityOutcome = firstCapabilityOutcome
        self.gateFirstCapabilities = gateFirstCapabilities
        self.listedRecords = listedRecords
        self.statusFails = statusFails
        self.resultResponse = resultResponse
    }

    func taskCapabilities() async throws -> TaskCapabilities {
        capabilityCalls += 1
        if capabilityCalls == 1 && gateFirstCapabilities {
            firstCapabilitiesReached = true
            firstCapabilitiesWaiter?.resume()
            firstCapabilitiesWaiter = nil
            await withCheckedContinuation { firstCapabilitiesRelease = $0 }
        }
        if capabilityCalls == 1, let firstCapabilityOutcome {
            switch firstCapabilityOutcome {
            case .rejected: return firstCapabilities ?? capabilities
            case .failed: throw TaskProtocolError.unsupportedCapability
            }
        }
        return capabilities
    }
    func taskStart(_ request: TaskRequest) async throws -> TaskRecord {
        requests.append(request)
        if startUnknown { throw TaskStartOutcomeUnknown() }
        return record
    }
    func taskStatus(id: String) async throws -> TaskRecord {
        statusCalls += 1
        if statusCalls > statusWaitAfter { statusWaiter?.resume(); statusWaiter = nil }
        if statusFails { throw TaskProtocolError.unsupportedCapability }
        return record
    }
    func taskList(limit: Int) async throws -> TaskPage {
        if listFails { throw TaskProtocolError.unsupportedCapability }
        return TaskPage(tasks: listedRecords, hasMore: false)
    }
    func taskResult(id: String) async throws -> TaskResultResponse {
        guard let resultResponse else { throw TaskProtocolError.unsupportedCapability }
        return resultResponse
    }
    func taskCancel(id: String) async throws -> TaskRecord { cancelled.append(id); return record }
    func taskVerifyModel(id: String) async throws -> TaskModelVerification {
        TaskModelVerification(id: id, modelPath: record.modelPath, modelFingerprint: "test", matches: true)
    }
    func startEvidence() -> [TaskRequest] { requests }
    func cancelledIDs() -> [String] { cancelled }
    func waitForFirstCapabilities() async {
        if firstCapabilitiesReached { return }
        await withCheckedContinuation { firstCapabilitiesWaiter = $0 }
    }
    func releaseFirstCapabilities() { firstCapabilitiesRelease?.resume(); firstCapabilitiesRelease = nil }
    func waitForStatusCall(after previousCount: Int) async {
        if statusCalls > previousCount { return }
        statusWaitAfter = previousCount
        await withCheckedContinuation { statusWaiter = $0 }
    }
    func statusCallCount() -> Int { statusCalls }
    func allowStatusReads() { statusFails = false }
    func failListReads() { listFails = true }
    func allowListReads() { listFails = false }
}

private struct TaskAcceptanceReceipt: Codable {
    let kind: String
    let modelPath: String
    let agentPath: String
    let taskID: String
    var state: String
    var identity: TaskIdentitySummary
    let requestArtifact: TaskArtifactReference
    var resultArtifact: TaskArtifactReference?
    var resultDigest: String?
    var outputArtifact: TaskArtifactReference?
    var outputDigest: String?
    var inputArtifact: TaskArtifactReference?
    var inputDigest: String?
    let suppliedInputDigest: String?
    let submittedInputPath: String?
    var transcript: String?
    var audioMetadata: [String: Int]?
    var imageMetadata: [String: Int]?
    var terminal: Bool
    var pendingFailure: String?

    init(kind: String, modelPath: String, agentPath: String, taskID: String, state: String,
         identity: TaskIdentitySummary, requestArtifact: TaskArtifactReference,
         resultArtifact: TaskArtifactReference?, resultDigest: String?, outputArtifact: TaskArtifactReference?,
         outputDigest: String?, inputArtifact: TaskArtifactReference?, inputDigest: String?,
         suppliedInputDigest: String?, submittedInputPath: String?, transcript: String?, audioMetadata: [String: Int]?, imageMetadata: [String: Int]? = nil,
         terminal: Bool, pendingFailure: String? = nil) {
        self.kind = kind
        self.modelPath = modelPath
        self.agentPath = agentPath
        self.taskID = taskID
        self.state = state
        self.identity = identity
        self.requestArtifact = requestArtifact
        self.resultArtifact = resultArtifact
        self.resultDigest = resultDigest
        self.outputArtifact = outputArtifact
        self.outputDigest = outputDigest
        self.inputArtifact = inputArtifact
        self.inputDigest = inputDigest
        self.suppliedInputDigest = suppliedInputDigest
        self.submittedInputPath = submittedInputPath
        self.transcript = transcript
        self.audioMetadata = audioMetadata
        self.imageMetadata = imageMetadata
        self.terminal = terminal
        self.pendingFailure = pendingFailure
    }
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
