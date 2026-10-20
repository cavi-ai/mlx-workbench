import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum TF {
    static let home = "/Users/fixture"
    static let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    static func job(_ state: String, repo: String = "org/base-model", out: String = "/Users/fixture/adapters/run-1",
                    pid: Int = 42, log: String? = "/tmp/run.log", identity: Bool = true, receipt: String = "r1") throws -> TrainingJob {
        var object: [String: Any] = ["receipt": receipt, "repo": repo, "out": out, "pid": pid, "state": state]
        if let log { object["log_path"] = log }
        if identity { object["adapter_identity"] = ["sha256": "abc123", "files": ["adapters.safetensors"]] }
        return try JSONDecoder().decode(TrainingJob.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func evaluation(_ id: String, created: String?) throws -> LabValue {
        var object: [String: Any] = ["id": id]
        if let created { object["created_at"] = created }
        return try JSONDecoder().decode(LabValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static let formatter = ISO8601DateFormatter()
}

private struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

@MainActor
final class TrainingInspectionTests: XCTestCase {
    private func report(repo: String? = nil, data: String? = nil, batchSize: Int = 4) throws -> TrainingInspection {
        let checks = ["runtime", "base", "train", "valid"].map { id in
            ["id": id, "status": "ready", "message": "Checked \(id)"]
        }
        var object: [String: Any] = ["schema_version": 1, "ready": true, "batch_size": batchSize, "checks": checks]
        if let repo { object["repo"] = repo }
        if let data { object["data"] = data }
        return try JSONDecoder().decode(TrainingInspection.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testCheckingDoesNotPreviewOrSubmitAndEditsInvalidateTheResult() async throws {
        var inspected: [TrainingDraft] = []
        let result = try report()
        let session = TrainingSession(preview: { _ in XCTFail("Inspection must not preview"); return [:] },
            start: { _, _ in XCTFail("Inspection must not train") }, inspect: { inspected.append($0); return result })
        XCTAssertTrue(session.canInspect)
        await session.inspectTraining()?.value
        XCTAssertEqual(inspected, [TrainingDraft()])
        XCTAssertTrue(try XCTUnwrap(session.inspection).ready)
        XCTAssertNil(session.preview)
        XCTAssertFalse(session.canConfirm)
        session.draft.data = "/different"
        XCTAssertNil(session.inspection)
    }

    func testInspectionDiscardsStaleResponsesAndFailedRechecksClearOldResults() async throws {
        let result = try report()
        var continuation: CheckedContinuation<TrainingInspection, Error>?
        var fails = false
        let session = TrainingSession(preview: { _ in [:] }, start: { _, _ in }, inspect: { _ in
            if fails { throw Boom() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let task = session.inspectTraining()
        while continuation == nil { await Task.yield() }
        XCTAssertFalse(session.canInspect)
        session.draft.repo = "org/changed"
        continuation?.resume(returning: result)
        await task?.value
        XCTAssertNil(session.inspection)
        continuation = nil
        let second = session.inspectTraining()
        while continuation == nil { await Task.yield() }
        continuation?.resume(returning: try report(repo: "org/changed"))
        await second?.value
        XCTAssertNotNil(session.inspection)
        fails = true
        await session.inspectTraining()?.value
        XCTAssertNil(session.inspection)
        XCTAssertNotNil(session.errorMessage)
    }

    func testBridgeRunsIndependentInspectionWithoutConfirmationOrReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"text\":\"One example\"}\nnot json\n".utf8).write(to: root.appendingPathComponent("train.jsonl"))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: source.appendingPathComponent("vendor/mlx-agent").path, receiptDirectory: root.path)
        let report = try await api.trainingInspection(repo: "workbench-fixture/uncached", data: root.path, batchSize: 4)
        XCTAssertFalse(report.ready)
        XCTAssertEqual(report.checks.map(\.id), [.runtime, .base, .train, .valid])
        XCTAssertTrue(report.checks.first { $0.id == .train }?.message.contains("line 2") == true)
        XCTAssertEqual(report.checks.first { $0.id == .valid }?.code, "validation_required")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mlx-agent-receipts").path))
    }
}

@MainActor
final class TrainingInspectionContractTests: XCTestCase {
    func testKnownBlockersPreventConfirmationAndMismatchNeverPublishes() async throws {
        var object: [String: Any] = ["schema_version": 1, "ready": false, "batch_size": 4,
            "repo": "org/base", "data": "/dataset", "checks": [
                ["id": "runtime", "status": "blocked", "message": "Training runtime missing"],
                ["id": "base", "status": "ready", "message": "Cached"],
                ["id": "train", "status": "ready", "message": "4 examples"],
                ["id": "valid", "status": "ready", "message": "4 examples"]]]
        var response = try JSONDecoder().decode(TrainingInspection.self, from: JSONSerialization.data(withJSONObject: object))
        let session = TrainingSession(preview: { _ in ["preview_hash": "reviewed"] },
            start: { _, _ in XCTFail("A known blocker must prevent submission") }, inspect: { _ in response })
        session.draft = TrainingDraft(repo: "org/base", data: "/dataset")
        await session.inspectTraining()?.value
        await session.previewTraining()?.value
        XCTAssertFalse(session.canConfirm)
        XCTAssertEqual(session.confirmationBlocker, "Training runtime missing")
        XCTAssertNil(session.confirmTraining())
        object["repo"] = "org/different"
        response = try JSONDecoder().decode(TrainingInspection.self, from: JSONSerialization.data(withJSONObject: object))
        await session.inspectTraining()?.value
        XCTAssertNil(session.inspection)
        XCTAssertNil(session.preview, "Rechecking must revoke the prior confirmation")
        XCTAssertNotNil(session.errorMessage)
    }

    func testInspectionRejectsIncompleteReportsAndInvalidBatchSizes() throws {
        let invalid = #"{"schema_version":1,"ready":true,"batch_size":4,"checks":[{"id":"runtime","status":"ready","message":"Found"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TrainingInspection.self, from: Data(invalid.utf8)))
        let session = TrainingSession(preview: { _ in [:] }, start: { _, _ in }, inspect: { _ in throw Boom() })
        session.draft.batchSize = "0"
        XCTAssertFalse(session.canInspect)
        XCTAssertNil(session.inspectTraining())
    }
}

@MainActor
final class TrainingOutputTests: XCTestCase {
    func testBlankOutputCapturesAFreshDestinationWithoutChangingTheDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var choices = 0
        var previews: [TrainingRequest] = [], starts: [TrainingRequest] = []
        let session = TrainingSession(preview: { request in
            previews.append(request); return ["preview_hash": "reviewed", "out": request.output!]
        }, start: { request, hash in
            starts.append(request); XCTAssertEqual(hash, "reviewed")
        }, outputDestination: {
            choices += 1; return root.appendingPathComponent(String(choices))
        })
        session.draft = TrainingDraft(repo: "org/base", data: "/dataset", output: "  ")
        let original = session.draft
        await session.previewTraining()?.value
        let first = try XCTUnwrap(session.preview?.request.output)
        XCTAssertEqual(session.draft, original)
        XCTAssertTrue(session.canConfirm)
        XCTAssertEqual(starts.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        await session.previewTraining()?.value
        let second = try XCTUnwrap(session.preview?.request.output)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(choices, 2)
        await session.confirmTraining()?.value
        XCTAssertEqual(starts, [previews[1]])
        XCTAssertEqual(starts.first?.output, second)
        XCTAssertEqual(choices, 2)
        XCTAssertEqual(session.draft, original)
    }

    func testExplicitOutputIsPreservedAndEditsInvalidateItsPreview() async {
        let session = TrainingSession(preview: { ["preview_hash": "reviewed", "out": $0.output!] },
            start: { _, _ in XCTFail("Edited output must be previewed again") },
            outputDestination: { XCTFail("An explicit output must not use a default"); return URL(fileURLWithPath: "/unused") })
        session.draft = TrainingDraft(repo: "org/base", data: "/dataset", output: " /chosen/adapter ")
        await session.previewTraining()?.value
        XCTAssertEqual(session.preview?.request.output, "/chosen/adapter")
        XCTAssertTrue(session.canConfirm)
        session.draft.output = "/different/adapter"
        XCTAssertNil(session.preview)
        XCTAssertNil(session.confirmTraining())
    }

    func testDefaultDestinationUsesApplicationSupportAndCliPreviewCreatesNoOutput() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["train.jsonl", "valid.jsonl"] {
            try Data((String(repeating: "{\"text\":\"A local example.\"}\n", count: 4)).utf8).write(to: root.appendingPathComponent(name))
        }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: source.appendingPathComponent("vendor/mlx-agent").path,
            receiptDirectory: root.path)
        let session = TrainingSession(preview: { request in
            try await api.loraPreview(repo: request.repo, data: request.data, iters: request.iterations, out: request.output, batchSize: request.batchSize)
        }, start: { _, _ in XCTFail("A preview must never start training") })
        session.draft = TrainingDraft(repo: "workbench-fixture/uncached-training-input", data: root.path)
        await session.previewTraining()?.value
        let preview = try XCTUnwrap(session.preview, session.errorMessage ?? "Missing preview")
        let output = try XCTUnwrap(preview.request.output)
        let expectedParent = WorkbenchStatePaths.applicationSupport().appendingPathComponent("trained-adapters")
        XCTAssertEqual(URL(fileURLWithPath: output).deletingLastPathComponent().path, expectedParent.path)
        XCTAssertEqual(preview.payload["out"] as? String, output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mlx-agent-receipts").path))
    }
}

@MainActor
final class TrainingBatchTests: XCTestCase {
    func testNativeBridgePreservesBatchSizeInPreviewAndConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["train.jsonl", "valid.jsonl"] {
            try Data("{\"text\":\"A local example.\"}\n".utf8).write(to: root.appendingPathComponent(name))
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: source.appendingPathComponent("vendor/mlx-agent").path,
            receiptDirectory: root.path)
        let repo = "workbench-fixture/uncached-training-input", output = root.appendingPathComponent("adapter").path
        let plan = try await api.loraPreview(repo: repo, data: root.path, iters: 1, out: output, batchSize: 1)
        XCTAssertEqual(plan["batch_size"] as? Int, 1)
        XCTAssertEqual(TrainingPlanSummary(payload: plan).trainingExamples, 1)
        do {
            _ = try await api.loraStart(repo: repo, data: root.path, previewHash: "unconfirmed", iters: 1, out: output, batchSize: 1)
            XCTFail("A deliberately invalid hash must not start training")
        } catch BridgeError.remote(let code, _, _) { XCTAssertEqual(code, "preview_stale") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mlx-agent-receipts").path))
    }

    func testBatchSizeIsBoundedAndPartOfTheCapturedRequest() async throws {
        var draft = TrainingDraft(repo: "org/base", data: "/dataset")
        XCTAssertEqual(draft.request?.batchSize, 4)
        for invalid in ["", "0", "65", "1.5", "many"] {
            draft.batchSize = invalid
            XCTAssertNil(draft.request)
            XCTAssertNotNil(draft.batchSizeError)
        }
        draft.batchSize = "1"
        XCTAssertEqual(draft.request?.batchSize, 1)
        var captured: [Int] = []
        let session = TrainingSession(preview: { request in
            captured.append(request.batchSize)
            return ["preview_hash": "reviewed", "batch_size": request.batchSize,
                "dataset": ["train_lines": 4, "valid_lines": 4]]
        }, start: { request, _ in XCTAssertEqual(request.batchSize, 1) })
        session.draft = draft
        await session.previewTraining()?.value
        XCTAssertTrue(session.canConfirm)
        session.draft.batchSize = "2"
        XCTAssertFalse(session.canConfirm)
        session.draft.batchSize = "1"
        await session.previewTraining()?.value
        await session.confirmTraining()?.value
        XCTAssertEqual(captured, [1, 1])
    }

    func testDatasetCountsBlockAnIncompatibleHistoricalPlanWithoutInventingDefaults() {
        let missingValidation = TrainingPlanSummary(payload: ["batch_size": 4,
            "dataset": ["train_lines": 8, "valid_lines": 0]])
        XCTAssertNotNil(missingValidation.blockingReason)
        let small = TrainingPlanSummary(payload: ["batch_size": 4,
            "dataset": ["train_lines": 1, "valid_lines": 4]])
        XCTAssertNotNil(small.blockingReason)
        XCTAssertNil(TrainingPlanSummary(payload: ["batch_size": 1,
            "dataset": ["train_lines": 1, "valid_lines": 1]]).blockingReason)
        XCTAssertNil(TrainingPlanSummary(payload: [:]).batchSize)
        XCTAssertNil(TrainingPlanSummary(payload: [:]).blockingReason)
    }
}

@MainActor
final class TrainedAdapterRuntimeTests: XCTestCase {
    func testCompletedLocalAdapterEvaluationRetainsAndReopensRealOutputs() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MLX_WORKBENCH_REAL_ADAPTER_RECEIPT"] else {
            throw XCTSkip("Set MLX_WORKBENCH_REAL_ADAPTER_RECEIPT for real adapter evaluation acceptance.")
        }
        guard environment["HF_HUB_OFFLINE"] == "1", environment["TRANSFORMERS_OFFLINE"] == "1" else {
            throw WorkflowEvidenceError.invalid("Real adapter evaluation requires offline model loading.")
        }
        let receipt = URL(fileURLWithPath: path).standardizedFileURL
        let original = try Data(contentsOf: receipt)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertEqual(record["process_exit_code"] as? Int, 0)
        XCTAssertEqual(record["exit_status"] as? String, "done")
        let base = try XCTUnwrap(record["base_identity"] as? [String: Any])
        let basePath = URL(fileURLWithPath: try XCTUnwrap(base["path"] as? String))
        let weights = try FileManager.default.contentsOfDirectory(at: basePath, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "safetensors" }
        let bytes = try weights.reduce(0) { try $0 + ($1.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard bytes > 0, bytes < 1_000_000_000 else {
            throw WorkflowEvidenceError.invalid("Use an existing base smaller than 1 GB for bounded evaluation acceptance.")
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let evidence = source.appendingPathComponent(".run/real-training-evaluation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let suite = "mlx-workbench.evaluation-acceptance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(evidence.appendingPathComponent("lab").path, forKey: "mlx-workbench.lab-store")
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: source.appendingPathComponent("vendor/mlx-agent").path,
            receiptDirectory: evidence.path)
        let lab = LabCoordinator(api: api, defaults: defaults)
        let session = TrainingEvaluationSession(receipt: receipt.path) { try await lab.request($0) }
        session.prompt = "Explain in one sentence why previewing a local model change is useful."
        await session.previewEvaluation()?.value
        let preview = try XCTUnwrap(session.preview, session.errorMessage ?? "Missing evaluation preview")
        XCTAssertEqual(preview.plan.object?["training_receipt"]?.text, receipt.path)
        XCTAssertEqual(preview.plan.object?["base_path"]?.text, basePath.path)
        XCTAssertTrue(session.canEvaluate)
        XCTAssertNil(session.result)
        let before = try await lab.request(LabRequest(operation: "training-history"))
        XCTAssertEqual(before.evaluations, [])

        await session.evaluate()?.value
        let result = try XCTUnwrap(session.result, session.errorMessage ?? "Evaluation returned no retained outputs")
        let outputs = try XCTUnwrap(result.report?.object?["outputs"]?.object)
        for variant in ["baseline", "adapter"] {
            XCTAssertFalse(try XCTUnwrap(outputs[variant]?.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertEqual(result.report?.object?["judgment"], .null)
        XCTAssertEqual(result.artifactSHA256?.count, 64)
        XCTAssertEqual(result.report?.object?["preview_hash"]?.text, preview.hash)

        let loader = TrainingLoader(jobs: { [] },
            history: { try await lab.request(LabRequest(operation: "training-history")).evaluations ?? [] },
            inspect: { try await lab.request(LabRequest(operation: "training-inspect", evaluationID: $0)) })
        await loader.refreshHistory()?.value
        XCTAssertNil(loader.historyError)
        XCTAssertEqual(loader.evaluations.count, 1)
        let identity = try XCTUnwrap(loader.evaluations.first?.object?["id"]?.text)
        await loader.inspect(identity)?.value
        let retained = try XCTUnwrap(loader.inspection, loader.inspectionError ?? "Retained evaluation did not reopen")
        XCTAssertEqual(retained.recordID, identity)
        XCTAssertEqual(retained.response.artifactSHA256, result.artifactSHA256)
        XCTAssertEqual(retained.response.report, result.report)
        XCTAssertEqual(try Data(contentsOf: receipt), original)
        try XCTUnwrap(result.report).jsonText.write(to: evidence.appendingPathComponent("report.json"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["evaluation_id": identity,
            "artifact_sha256": try XCTUnwrap(result.artifactSHA256), "training_receipt": receipt.path,
            "history_reopened": true, "quality_improvement_measured": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("result.json"))
        print("Real adapter evaluation evidence: \(evidence.path)")
    }

    func testBlankOutputTrainingCreatesARealAdapterInApplicationSupport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let repo = environment["MLX_WORKBENCH_REAL_TRAINING_REPO"],
              let dataset = environment["MLX_WORKBENCH_REAL_TRAINING_DATA"] else {
            throw XCTSkip("Set MLX_WORKBENCH_REAL_TRAINING_REPO and MLX_WORKBENCH_REAL_TRAINING_DATA for real training acceptance.")
        }
        guard environment["HF_HUB_OFFLINE"] == "1", environment["TRANSFORMERS_OFFLINE"] == "1" else {
            throw WorkflowEvidenceError.invalid("Real training acceptance requires offline model loading.")
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let evidence = source.appendingPathComponent(".run/real-training-output-" + UUID().uuidString)
        let previousRoot = WorkbenchStatePaths.hostedTestRoot
        WorkbenchStatePaths.hostedTestRoot = evidence
        defer { WorkbenchStatePaths.hostedTestRoot = previousRoot }
        let support = WorkbenchStatePaths.applicationSupport()
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: source.appendingPathComponent("vendor/mlx-agent").path,
            receiptDirectory: support.path)
        let session = TrainingSession(preview: { request in
            try await api.loraPreview(repo: request.repo, data: request.data, iters: request.iterations, out: request.output, batchSize: request.batchSize)
        }, start: { request, hash in
            _ = try await api.loraStart(repo: request.repo, data: request.data, previewHash: hash,
                iters: request.iterations, out: request.output, batchSize: request.batchSize)
        })
        session.draft = TrainingDraft(repo: repo, data: dataset, iterations: "1", batchSize: "1")
        let original = session.draft
        await session.previewTraining()?.value
        let preview = try XCTUnwrap(session.preview, session.errorMessage ?? "Missing training preview")
        let output = try XCTUnwrap(preview.request.output)
        XCTAssertEqual(URL(fileURLWithPath: output).deletingLastPathComponent().path,
            support.appendingPathComponent("trained-adapters").path)
        XCTAssertEqual(preview.payload["out"] as? String, output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        let summary = TrainingPlanSummary(payload: preview.payload)
        guard session.canConfirm, summary.trainingExamples == 1, summary.validationExamples == 1,
              let base = summary.basePath else {
            throw WorkflowEvidenceError.invalid("Bounded training acceptance needs a cached base and one example per split.")
        }
        let weights = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "safetensors" }
        let bytes = try weights.reduce(0) { try $0 + ($1.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard bytes > 0, bytes < 1_000_000_000 else { throw WorkflowEvidenceError.invalid("Use an existing base smaller than 1 GB.") }
        do {
            await session.confirmTraining()?.value
            XCTAssertNil(session.errorMessage)
            let deadline = Date().addingTimeInterval(120)
            var completed: TrainingJob?
            while Date() < deadline {
                let jobs = try await api.trainingStatus().jobs
                if let job = jobs.first(where: { $0.out == output }), job.state == "done" || job.state == "failed" {
                    completed = job; break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            let job = try XCTUnwrap(completed, session.errorMessage ?? "Training did not finish within its bound")
            guard job.state == "done", job.adapterIdentity != nil else {
                throw WorkflowEvidenceError.invalid("Training failed; inspect \(job.logPath ?? job.receipt).")
            }
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: job.receipt))) as? [String: Any])
            XCTAssertEqual(record["process_exit_code"] as? Int, 0)
            XCTAssertEqual(record["out"] as? String, output)
            XCTAssertEqual(session.draft, original)
            try JSONSerialization.data(withJSONObject: ["training_receipt": job.receipt, "record": record,
                "preview": preview.payload, "quality_improvement_measured": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("result.json"))
            print("Real default-output training evidence: \(evidence.path)")
        } catch {
            do {
                for job in try await api.trainingStatus().jobs where job.out == output && ["running", "unknown"].contains(job.state) {
                    _ = try await api.trainingStop(pid: job.pid)
                }
            } catch { XCTFail("Training acceptance cleanup failed: \(error)") }
            throw error
        }
    }

    func testCompletedLocalAdapterServesThroughRunAndStops() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MLX_WORKBENCH_REAL_ADAPTER_RECEIPT"] else {
            throw XCTSkip("Set MLX_WORKBENCH_REAL_ADAPTER_RECEIPT for real adapter-serving acceptance.")
        }
        guard environment["HF_HUB_OFFLINE"] == "1", environment["TRANSFORMERS_OFFLINE"] == "1" else {
            throw WorkflowEvidenceError.invalid("Real adapter acceptance requires offline model loading.")
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let receipt = URL(fileURLWithPath: path).standardizedFileURL
        let original = try Data(contentsOf: receipt)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertEqual(record["process_exit_code"] as? Int, 0)
        XCTAssertEqual(record["exit_status"] as? String, "done")
        let base = try XCTUnwrap(record["base_identity"] as? [String: Any])
        let basePath = URL(fileURLWithPath: try XCTUnwrap(base["path"] as? String))
        let weights = try FileManager.default.contentsOfDirectory(at: basePath, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "safetensors" }
        let weightBytes = try weights.reduce(0) { try $0 + ($1.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard weightBytes > 0, weightBytes < 1_000_000_000 else {
            throw WorkflowEvidenceError.invalid("This bounded acceptance requires an existing base smaller than 1 GB.")
        }
        let trainingAPI = WorkbenchAPI(cli: CLIProcess(), agentPath: source.appendingPathComponent("vendor/mlx-agent").path,
            receiptDirectory: receipt.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path)
        let jobs = try await trainingAPI.trainingStatus().jobs
        let job = try XCTUnwrap(jobs.first { URL(fileURLWithPath: $0.receipt).standardizedFileURL == receipt })
        XCTAssertEqual(job.state, "done")
        XCTAssertNotNil(job.adapterIdentity)
        let evidence = source.appendingPathComponent(".run/real-trained-adapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: source.appendingPathComponent("vendor/mlx-agent").path,
            receiptDirectory: evidence.path)
        let coordinator = TrainedAdapterServingCoordinator(api: .live(api))
        let port = try XCTUnwrap(EphemeralPort.pick())
        coordinator.portText = String(port)
        XCTAssertTrue(coordinator.select(job))
        XCTAssertNil(coordinator.preview)
        await coordinator.previewServe()?.value
        let reviewed = try XCTUnwrap(coordinator.preview, coordinator.errorMessage ?? "Missing serving preview")
        XCTAssertEqual(reviewed.binding.receiptPath, receipt.path)
        do {
            await coordinator.confirmServe()?.value
            let server = try XCTUnwrap(coordinator.runningServer, coordinator.errorMessage ?? "Adapter did not start")
            XCTAssertTrue(reviewed.binding.matches(server))
            let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
            let prober = OpenAIEndpointProber(requestTimeout: 60)
            let prompt = "What should happen before starting a local model server?"
            let response = try await prober.chat(baseURL: baseURL, model: server.modelIdentity, prompt: prompt, maxTokens: 32)
            XCTAssertFalse(response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            var result: [String: Any] = ["training_receipt": receipt.path, "serve_plan": reviewed.plan,
                "server": try JSONSerialization.jsonObject(with: JSONEncoder().encode(server)), "prompt": prompt,
                "response": response.text, "quality_improvement_measured": false]
            _ = try await api.serveStop(port: port)
            let stopped = try await api.serveStatus()
            let stillRunning = stopped.contains { $0.pid == server.pid && $0.state == "running" }
            XCTAssertFalse(stillRunning)
            coordinator.receiveServers(stopped)
            XCTAssertNil(coordinator.runningServer)
            let stillReady = await prober.isReady(baseURL: baseURL)
            XCTAssertFalse(stillReady)
            XCTAssertEqual(try Data(contentsOf: receipt), original)
            result["server_stopped"] = !stillRunning && !stillReady
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("result.json"))
            print("Real trained-adapter evidence: \(evidence.path)")
        } catch {
            do { _ = try await api.serveStop(port: port) }
            catch { XCTFail("Adapter acceptance cleanup failed: \(error)") }
            throw error
        }
    }
}

private enum TrainedServeFixture {
    static let identity: [String: Any] = ["adapter_config.json": ["sha256": String(repeating: "a", count: 64), "bytes": 2],
        "adapters.safetensors": ["sha256": String(repeating: "b", count: 64), "bytes": 100]]
    static let binding: [String: Any] = ["training_receipt": "/receipts/trained.json", "training_receipt_sha256": String(repeating: "c", count: 64),
        "training_run_id": "run-a", "base_repo": "org/base", "base_path": "/models/base", "base_fingerprint": String(repeating: "d", count: 64),
        "adapter_path": "/adapters/tuned", "adapter_identity": identity]
    static let hash = String(repeating: "e", count: 64)
    static var plan: [String: Any] { ["runtime": "mlx_lm", "port": 8766, "path": "/models/base", "adapter_path": "/adapters/tuned",
        "adapter_identity": identity, "training_binding": binding, "preview_hash": hash] }
    static var receipt: [String: Any] { plan.merging(["pid": 77, "started_at": "2026-10-15T00:00:00Z"]) { _, new in new } }
    static func job() throws -> TrainingJob {
        let identity = try JSONDecoder().decode(LabValue.self, from: JSONSerialization.data(withJSONObject: identity))
        return TrainingJob(receipt: "/receipts/trained.json", repo: "org/base", out: "/adapters/tuned", pid: 9, state: "done", logPath: nil, adapterIdentity: identity)
    }
    static func server() throws -> ServerInfo {
        let row = receipt.merging(["state": "running"]) { _, new in new }
        return try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [row]])?.first)
    }
}

@MainActor
final class TrainedAdapterServingTests: XCTestCase {
    func testSelectionDoesNotStartAndConfirmationUsesTheReviewedPairAndPort() async throws {
        var starts = 0, running = false
        let coordinator = TrainedAdapterServingCoordinator(api: .init(preview: { receipt, _ in
            XCTAssertEqual(receipt, "/receipts/trained.json"); return TrainedServeFixture.plan
        }, start: { receipt, port, hash in
            XCTAssertEqual(receipt, "/receipts/trained.json"); XCTAssertEqual(port, 8766); XCTAssertEqual(hash, TrainedServeFixture.hash)
            starts += 1; running = true; return ["receipt": TrainedServeFixture.receipt]
        }, status: { running ? [try TrainedServeFixture.server()] : [] }))
        XCTAssertTrue(coordinator.select(try TrainedServeFixture.job()))
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(coordinator.canConfirm)
        await coordinator.previewServe()?.value
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(coordinator.canConfirm)
        await coordinator.confirmServe()?.value
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(coordinator.runningServer?.adapterPath, "/adapters/tuned")
        XCTAssertNotNil(coordinator.runningServer?.trainingBinding)
        XCTAssertFalse(try TrainedServeFixture.server().matchesUnadaptedModel("/models/base"))
    }

    func testPortEditsAndDelayedPreviewsNeverGrantOldConfirmation() async throws {
        var completion: CheckedContinuation<[String: Any], Never>?
        let started = expectation(description: "preview started")
        let coordinator = TrainedAdapterServingCoordinator(api: .init(preview: { _, _ in
            await withCheckedContinuation { completion = $0; started.fulfill() }
        }, start: { _, _, _ in XCTFail("Must preview the edited port"); return [:] }, status: { [] }))
        XCTAssertTrue(coordinator.select(try TrainedServeFixture.job()))
        let task = coordinator.previewServe()
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertNil(coordinator.previewServe())
        XCTAssertNil(coordinator.confirmServe())
        await fulfillment(of: [started], timeout: 1)
        coordinator.portText = "8767"
        completion?.resume(returning: TrainedServeFixture.plan)
        await task?.value
        XCTAssertNil(coordinator.preview)
        XCTAssertFalse(coordinator.canConfirm)
        XCTAssertNil(coordinator.confirmServe())
    }

    func testMissingBindingOrConflictingServerCannotConfirm() async throws {
        var legacy = true
        let coordinator = TrainedAdapterServingCoordinator(api: .init(preview: { _, _ in
            legacy ? ["preview_hash": TrainedServeFixture.hash] : TrainedServeFixture.plan
        }, start: { _, _, _ in XCTFail("Must not start"); return [:] }, status: {
            [ServerInfo(path: "/models/base", port: 8766, pid: 1, state: "running")]
        }))
        XCTAssertTrue(coordinator.select(try TrainedServeFixture.job()))
        await coordinator.previewServe()?.value
        XCTAssertFalse(coordinator.canConfirm)
        XCTAssertNotNil(coordinator.errorMessage)
        legacy = false
        await coordinator.previewServe()?.value
        XCTAssertFalse(coordinator.canConfirm)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testMismatchedStartReceiptDoesNotBecomeRunningOrRemainConfirmable() async throws {
        let coordinator = TrainedAdapterServingCoordinator(api: .init(preview: { _, _ in TrainedServeFixture.plan },
            start: { _, _, _ in ["receipt": TrainedServeFixture.receipt.merging(["preview_hash": "wrong"]) { _, new in new }] },
            status: { [] }))
        XCTAssertTrue(coordinator.select(try TrainedServeFixture.job()))
        await coordinator.previewServe()?.value
        await coordinator.confirmServe()?.value
        XCTAssertNil(coordinator.runningServer)
        XCTAssertFalse(coordinator.canConfirm)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testExistingPairOnAnotherPortDoesNotCreateAnotherServer() async throws {
        let row = TrainedServeFixture.receipt.merging(["port": 9876, "state": "running"]) { _, new in new }
        let existing = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [row]])?.first)
        let coordinator = TrainedAdapterServingCoordinator(api: .init(preview: { _, _ in TrainedServeFixture.plan },
            start: { _, _, _ in XCTFail("Must not load a duplicate server"); return [:] }, status: { [existing] }))
        XCTAssertTrue(coordinator.select(try TrainedServeFixture.job()))
        await coordinator.previewServe()?.value
        XCTAssertFalse(coordinator.canConfirm)
        XCTAssertTrue(coordinator.errorMessage?.contains("9876") == true)
    }
}

@MainActor
final class TrainingEvaluationSessionTests: XCTestCase {
    private func plan(_ hash: String = "reviewed") -> LabResponse {
        LabResponse(plan: .object(["preview_hash": .string(hash)]))
    }
    private func retained(_ prompt: String = "Prompt") -> LabResponse {
        LabResponse(evaluationID: "text_eval_fixture", report: .object(["schema_version": .string("text-training-evaluation/1"),
            "prompt": .string(prompt), "max_tokens": .integer(128), "preview_hash": .string("reviewed"),
            "outputs": .object(["baseline": .string("Base"), "adapter": .string("Tuned")])]),
            artifactSHA256: String(repeating: "a", count: 64))
    }

    func testEditedPromptRejectsDelayedPreviewAndDuplicateActions() async {
        var completion: CheckedContinuation<LabResponse, Never>?
        let started = expectation(description: "preview requested")
        let session = TrainingEvaluationSession(receipt: "/training/receipt.json") { request in
            XCTAssertEqual(request.operation, "training-preview")
            XCTAssertEqual(request.prompt, "First prompt")
            return await withCheckedContinuation { completion = $0; started.fulfill() }
        }
        session.prompt = "First prompt"
        let task = session.previewEvaluation()
        XCTAssertTrue(session.isBusy)
        XCTAssertNil(session.previewEvaluation())
        XCTAssertNil(session.evaluate())
        await fulfillment(of: [started], timeout: 1)
        session.prompt = "Edited prompt"
        completion?.resume(returning: plan())
        await task?.value
        XCTAssertNil(session.preview)
        XCTAssertFalse(session.canEvaluate)
        XCTAssertTrue(session.canPreview)
    }

    func testEvaluationUsesReviewedPromptReceiptAndHashAndEditsClearEvidence() async {
        var calls: [LabRequest] = []
        let session = TrainingEvaluationSession(receipt: "/training/receipt.json") { request in
            calls.append(request)
            return request.operation == "training-preview" ? self.plan() : self.retained(request.prompt ?? "Prompt")
        }
        session.prompt = " Compare this prompt "
        await session.previewEvaluation()?.value
        XCTAssertTrue(session.canEvaluate)
        await session.evaluate()?.value
        XCTAssertEqual(calls.map(\.operation), ["training-preview", "training-evaluate"])
        XCTAssertEqual(calls.map(\.prompt), [session.prompt, session.prompt])
        XCTAssertTrue(calls.allSatisfy { $0.receipt == "/training/receipt.json" && $0.maxTokens == 128 })
        XCTAssertEqual(calls.last?.previewHash, "reviewed")
        XCTAssertNotNil(session.result?.artifactSHA256)
        session.prompt = "Different prompt"
        XCTAssertNil(session.result)
        XCTAssertNil(session.preview)
        XCTAssertFalse(session.canEvaluate)
    }

    func testFailedOrHashlessRepreviewRevokesOldConfirmationAndResults() async {
        var previews = 0
        let session = TrainingEvaluationSession(receipt: "/receipt.json") { request in
            if request.operation == "training-evaluate" { return self.retained(request.prompt ?? "Prompt") }
            previews += 1
            if previews == 2 { throw Boom() }
            return previews == 3 ? LabResponse() : self.plan()
        }
        session.prompt = "Prompt"
        await session.previewEvaluation()?.value
        await session.evaluate()?.value
        XCTAssertNotNil(session.result)
        let retry = session.previewEvaluation()
        XCTAssertNil(session.result)
        XCTAssertNil(session.preview)
        await retry?.value
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(session.canEvaluate)
        await session.previewEvaluation()?.value
        XCTAssertNotNil(session.errorMessage)
        XCTAssertNil(session.preview)
        XCTAssertNil(session.evaluate())
    }

    func testEditedPromptRejectsDelayedEvaluationAndFailureRemainsRetryable() async {
        var completion: CheckedContinuation<LabResponse, Never>?
        let started = expectation(description: "evaluation requested")
        let session = TrainingEvaluationSession(receipt: "/receipt.json") { request in
            if request.operation == "training-preview" { return self.plan() }
            return await withCheckedContinuation { completion = $0; started.fulfill() }
        }
        session.prompt = "Prompt"
        await session.previewEvaluation()?.value
        let task = session.evaluate()
        XCTAssertTrue(session.isBusy)
        XCTAssertNil(session.evaluate())
        await fulfillment(of: [started], timeout: 1)
        session.prompt = "Edited"
        completion?.resume(returning: retained())
        await task?.value
        XCTAssertNil(session.result)
        XCTAssertFalse(session.canEvaluate)
        XCTAssertTrue(session.canPreview)

        var attempts = 0
        let retry = TrainingEvaluationSession(receipt: "/receipt.json") { request in
            if request.operation == "training-preview" { return self.plan() }
            attempts += 1
            if attempts == 1 { throw Boom() }
            return attempts == 2 ? LabResponse() : self.retained()
        }
        retry.prompt = "Prompt"
        await retry.previewEvaluation()?.value
        for _ in 0..<2 {
            await retry.evaluate()?.value
            XCTAssertNil(retry.result)
            XCTAssertNotNil(retry.errorMessage)
            XCTAssertTrue(retry.canEvaluate)
        }
        await retry.evaluate()?.value
        XCTAssertNotNil(retry.result)
        XCTAssertNil(retry.errorMessage)
    }
}

@MainActor
final class TrainingEvaluationSuiteSessionTests: XCTestCase {
    private var set: PromptSet {
        PromptSet(id: "evaluation", name: "Held-out questions", useCase: nil, prompts: [
            PromptEntry(id: "first", text: "Explain previews.", maxTokens: 32),
            PromptEntry(id: "second", text: "Explain rollback.", maxTokens: 64)], origin: .userCreated)
    }
    private func response(_ suite: TrainingEvaluationSuite) -> LabResponse {
        let snapshot = try! JSONDecoder().decode(LabValue.self, from: JSONEncoder().encode(suite))
        return LabResponse(evaluationID: "text_eval_suite", reviews: [], report: .object([
            "schema_version": .string("text-training-evaluation/2"), "preview_hash": .string("reviewed"),
            "prompt_suite": snapshot,
            "samples": .array(suite.prompts.map { prompt in .object(["id": .string(prompt.id),
                "prompt": .string(prompt.text), "max_tokens": .integer(prompt.maxTokens),
                "outputs": .object(["baseline": .string("Base " + prompt.text), "adapter": .string("Adapter " + prompt.text)])]) })]),
            artifactSHA256: String(repeating: "a", count: 64))
    }
    private func plan(_ suite: TrainingEvaluationSuite) throws -> LabResponse {
        LabResponse(plan: .object(["preview_hash": .string("reviewed"),
            "prompt_suite": try JSONDecoder().decode(LabValue.self, from: JSONEncoder().encode(suite))]))
    }

    func testSuiteSnapshotsPreserveEntriesAndRejectUnsupportedSettings() throws {
        var source = set
        let snapshot = try TrainingEvaluationSuite(source)
        source.prompts[0].text = "Later edit"
        XCTAssertEqual(snapshot.prompts[0].text, "Explain previews.")
        XCTAssertEqual(snapshot.prompts.map(\.maxTokens), [32, 64])
        source.prompts[0].inputPath = "/input"
        XCTAssertThrowsError(try TrainingEvaluationSuite(source))
        source = set; source.prompts[0].expectedKeywords = ["preview"]
        XCTAssertThrowsError(try TrainingEvaluationSuite(source))
        source = set; source.prompts[0].maxTokens = 513
        XCTAssertThrowsError(try TrainingEvaluationSuite(source))
    }

    func testSuitePreviewAndEvaluationUseIdenticalCapturedInputsAndRejectPartialResults() async throws {
        let suite = try TrainingEvaluationSuite(set)
        var calls: [LabRequest] = []
        var partial = true
        let session = TrainingEvaluationSession(receipt: "/receipt") { request in
            calls.append(request)
            if request.operation == "training-preview" { return try self.plan(suite) }
            var result = self.response(suite)
            if partial, var report = result.report?.object, case .array(let values) = report["samples"] {
                report["samples"] = .array(Array(values.prefix(1))); result.report = .object(report)
            }
            return result
        }
        session.selectSuite(set)
        await session.previewEvaluation()?.value
        XCTAssertTrue(session.canEvaluate)
        await session.evaluate()?.value
        XCTAssertNil(session.result)
        XCTAssertNotNil(session.errorMessage)
        partial = false
        await session.evaluate()?.value
        XCTAssertEqual(session.samples.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.promptSuite == suite && $0.prompt == nil && $0.maxTokens == nil })
        session.useSinglePrompt()
        XCTAssertNil(session.result)
        XCTAssertNil(session.preview)
    }

    func testFailedReviewKeepsOutputsAndDraftsAndSuccessfulReviewSurvivesReopening() async throws {
        let suite = try TrainingEvaluationSuite(set)
        var fails = true
        let session = TrainingEvaluationSession(receipt: "/receipt") { request in
            if request.operation == "training-preview" { return try self.plan(suite) }
            if request.operation == "training-evaluate" { return self.response(suite) }
            if fails { throw Boom() }
            XCTAssertEqual(request.promptID, "first")
            let review = TrainingEvaluationReview(id: "review_1", evaluationID: "text_eval_suite",
                artifactSHA256: String(repeating: "a", count: 64), promptID: "first", reviewerID: "reviewer",
                preference: request.preference!, notes: request.notes!, createdAt: "2026-10-16T00:00:00Z")
            return LabResponse(evaluationID: "text_eval_suite", reviews: [review], artifactSHA256: review.artifactSHA256,
                               reviewID: review.id)
        }
        session.selectSuite(set)
        await session.previewEvaluation()?.value; await session.evaluate()?.value
        session.updateReview("first", .init(preference: "adapter", notes: "More specific"))
        session.selectedPromptID = "second"
        XCTAssertEqual(session.draft("first").notes, "More specific")
        session.selectedPromptID = "first"
        XCTAssertTrue(session.hasUnsavedReviews)
        XCTAssertFalse(session.canPreview)
        await session.saveReview()?.value
        XCTAssertNotNil(session.reviewError)
        XCTAssertEqual(session.samples.count, 2)
        XCTAssertEqual(session.draft("first").notes, "More specific")
        fails = false
        await session.saveReview()?.value
        XCTAssertFalse(session.hasUnsavedReviews)
        XCTAssertFalse(session.canSaveReview)
        let reopened = TrainingEvaluationSession(receipt: "", retained: try XCTUnwrap(session.result)) { _ in
            XCTFail("Opening retained evidence must not generate"); return LabResponse()
        }
        XCTAssertTrue(reopened.isRetainedOnly)
        XCTAssertFalse(reopened.canPreview)
        XCTAssertEqual(reopened.reviews.first?.preference, "adapter")
    }
}

// MARK: - Presentation

final class TrainingPresentationTests: XCTestCase {
    func testTrainingPlanShowsCapturedOutputAndDatasetCounts() {
        let payload: [String: Any] = ["preview_hash": "h", "out": "model-lora",
            "base_identity": ["path": "/cache/snapshots/revision"],
            "dataset": ["train_lines": 12, "valid_lines": 0]]
        let summary = TrainingPlanSummary(payload: payload)
        XCTAssertEqual(summary.outputPath, "model-lora")
        XCTAssertEqual(summary.basePath, "/cache/snapshots/revision")
        XCTAssertEqual(summary.trainingExamples, 12)
        XCTAssertEqual(summary.validationExamples, 0)
        XCTAssertFalse(summary.baseMissing)
        XCTAssertEqual(TrainingPlanSummary(payload: ["plan": payload]), summary)
    }

    func testTrainingPlanDoesNotInventMissingLegacyFieldsOrCounts() {
        let legacy = TrainingPlanSummary(payload: ["preview_hash": "h"])
        XCTAssertNil(legacy.outputPath)
        XCTAssertNil(legacy.basePath)
        XCTAssertNil(legacy.trainingExamples)
        XCTAssertNil(legacy.validationExamples)
        XCTAssertFalse(legacy.baseMissing, "An older preview without identity is not proof of a missing model")
        let missing = TrainingPlanSummary(payload: ["base_identity": NSNull(), "out": " ",
            "dataset": ["train_lines": -1, "valid_lines": "unknown"]])
        XCTAssertTrue(missing.baseMissing)
        XCTAssertNil(missing.outputPath)
        XCTAssertNil(missing.trainingExamples)
        XCTAssertNil(missing.validationExamples)
    }

    func testEveryAgentStateMapsToAStatus() throws {
        let running = TrainingJobRow(job: try TF.job("running"), home: TF.home).status
        XCTAssertEqual(running.label, "Running")
        XCTAssertTrue(running.isLive)
        let done = TrainingJobRow(job: try TF.job("done"), home: TF.home).status
        XCTAssertEqual(done.label, "Completed")
        XCTAssertFalse(done.isLive)
        XCTAssertEqual(done.tone, .success)
        XCTAssertNotEqual(done.tone, running.tone)
        let failed = TrainingJobRow(job: try TF.job("failed"), home: TF.home).status
        XCTAssertEqual(failed.label, "Failed")
        XCTAssertEqual(failed.tone, .failure)
        let stopped = TrainingJobRow(job: try TF.job("stopped"), home: TF.home).status
        XCTAssertEqual(stopped.label, "Stopped")
        XCTAssertEqual(stopped.tone, .neutral)
    }

    func testUnknownStateKeepsItsOwnWording() throws {
        let status = TrainingJobRow(job: try TF.job("waiting_for_gpu_slot"), home: TF.home).status
        XCTAssertEqual(status.label, "Waiting For Gpu Slot")
        XCTAssertEqual(status.tone, .neutral)
        let odd = TrainingJobRow(job: try TF.job("rebalancing"), home: TF.home).status
        XCTAssertEqual(odd.label, "Rebalancing")
        XCTAssertEqual(odd.tone, .neutral)
        XCTAssertFalse(odd.isLive)
    }

    func testEmptyStatesAreSelectedByContent() throws {
        let empty = TrainingPresentation.make(jobs: [], evaluations: [], home: TF.home, now: TF.now)
        XCTAssertTrue(empty.showsNoJobs)
        XCTAssertTrue(empty.showsNoEvaluations)
        XCTAssertEqual(TrainingPresentation.noJobsSentence, "No training jobs yet. Preview and confirm a fine-tune to start one.")
        let filled = TrainingPresentation.make(
            jobs: [try TF.job("done")], evaluations: [try TF.evaluation("abcdef0123456789", created: nil)], home: TF.home, now: TF.now
        )
        XCTAssertFalse(filled.showsNoJobs)
        XCTAssertFalse(filled.showsNoEvaluations)
    }

    func testALoadFailureReplacesTheEmptySentenceWithItsOwn() throws {
        let failed = TrainingPresentation.make(jobs: [], evaluations: [], jobsError: "usage: mlx-agent", historyError: "usage: mlx-agent", home: TF.home, now: TF.now)
        XCTAssertFalse(failed.showsNoJobs)
        XCTAssertFalse(failed.showsNoEvaluations)
        XCTAssertEqual(failed.jobsError, "usage: mlx-agent")
        XCTAssertEqual(TrainingPresentation.jobsFailureSentence, "Training jobs couldn't load.")
        XCTAssertEqual(TrainingPresentation.evaluationsFailureSentence, "Evaluations couldn't load.")
        let historyOnly = TrainingPresentation.make(jobs: [], evaluations: [], historyError: "boom", home: TF.home, now: TF.now)
        XCTAssertTrue(historyOnly.showsNoJobs)
        XCTAssertFalse(historyOnly.showsNoEvaluations)
    }

    func testBaseModelsKeepLanguageAndLegacyCandidatesAndOmitKnownNonLanguageTasks() {
        func model(_ path: String, task: ModelTaskType? = nil, draft: ModelDraft? = nil) -> LibraryModel {
            let item = ModelItem(
                path: path, name: "m", bytes: 1, modifiedAt: nil, shard: nil, modelKey: "m", architecture: nil,
                quantization: nil, parameters: nil, structure: nil, signature: nil, companion: nil, readable: true,
                status: "ready", outputs: [], tensorCount: nil, error: nil,
                task: task.map { ModelTask(type: $0, useCases: [], source: "registry", confidence: "confirmed") }, draft: draft
            )
            return LibraryModel(item: item, readiness: .ready)
        }
        var models = [
                model("/c/models--org--zeta/snapshots/a"), model("/c/models--org--alpha/snapshots/b"),
                model("/c/models--org--alpha/snapshots/c"), model("/models/local-mlx"),
                model("/c/models--org--text/snapshots/a", task: .textLLM),
                model("/c/models--org--vision/snapshots/a", task: .visionLanguage),
                model("/c/models--org--legacy-draft/snapshots/a", draft: ModelDraft(port: nil, target: "org/base", blockSize: 8)),
            ]
        for type in ModelTaskType.allCases where ![.textLLM, .visionLanguage].contains(type) {
            models.append(model("/c/models--org--\(type.rawValue)/snapshots/a", task: type))
        }
        let snapshot = LibrarySnapshot(
            models: models,
            groups: [], hardware: HardwareProfile(chip: "Test", model: nil, memoryBytes: 0, macOSVersion: nil),
            generatedAt: TF.now
        )
        let candidates = TrainingPresentation.baseModels(snapshot)
        XCTAssertEqual(candidates, ["org/alpha", "org/text", "org/vision", "org/zeta"])
        XCTAssertEqual(TrainingPresentation.baseModels(nil), [])
        let custom = TrainingBaseModelChoice()
        XCTAssertEqual(custom.selection(repo: "org/speech_to_text", cached: candidates), "")
        XCTAssertTrue(custom.showsField(repo: "org/speech_to_text", cached: candidates))
    }

    func testTypingACachedIDKeepsTheFieldAndPickingItHidesTheField() {
        let cached = ["org/alpha", "org/zeta"]
        var choice = TrainingBaseModelChoice()
        XCTAssertTrue(choice.showsField(repo: "", cached: cached))
        XCTAssertEqual(choice.selection(repo: "org/alpha", cached: cached), "")
        XCTAssertTrue(choice.showsField(repo: "org/alpha", cached: cached), "typing a cached id must not hide the focused field")
        XCTAssertEqual(choice.select("org/alpha"), "org/alpha")
        XCTAssertFalse(choice.showsField(repo: "org/alpha", cached: cached))
        XCTAssertEqual(choice.selection(repo: "org/alpha", cached: cached), "org/alpha")
        XCTAssertEqual(choice.select(""), "")
        XCTAssertTrue(choice.showsField(repo: "", cached: cached))
        XCTAssertTrue(TrainingBaseModelChoice().showsField(repo: "", cached: []))
    }

    func testAnUnavailableCachedSelectionRemainsVisibleForCorrection() {
        var choice = TrainingBaseModelChoice()
        let repo = choice.select("org/alpha")
        let remaining = ["org/zeta"]
        XCTAssertEqual(repo, "org/alpha")
        XCTAssertEqual(choice.selection(repo: repo, cached: remaining), "")
        XCTAssertTrue(choice.showsField(repo: repo, cached: remaining))
        let edited = choice.edit("org/zeta")
        XCTAssertEqual(edited, "org/zeta")
        XCTAssertTrue(choice.showsField(repo: edited, cached: remaining), "Typing a cached ID must keep the correction field visible")
        XCTAssertEqual(choice.selection(repo: edited, cached: remaining), "")
    }

    func testRetainedEvidenceCarriesTheInspectedShortID() {
        let evidence = TrainingRetainedEvidence(evaluationID: "0123456789abcdef", reportText: "{}", sha256: "ff")
        XCTAssertEqual(evidence.shortID, "01234567")
    }

    func testJobRowValuesAndActionsFollowTheState() throws {
        let done = TrainingJobRow(job: try TF.job("done"), home: TF.home)
        XCTAssertEqual(done.outputPath, "~/adapters/run-1")
        XCTAssertEqual(done.repo, "org/base-model")
        XCTAssertTrue(done.canCompare)
        XCTAssertFalse(done.canCancel)
        XCTAssertEqual(done.logPath, "/tmp/run.log")

        let doneWithoutIdentity = TrainingJobRow(job: try TF.job("done", identity: false), home: TF.home)
        XCTAssertFalse(doneWithoutIdentity.canCompare)
        XCTAssertNil(doneWithoutIdentity.adapterIdentity)

        let running = TrainingJobRow(job: try TF.job("running", log: nil, identity: false), home: TF.home)
        XCTAssertTrue(running.canCancel)
        XCTAssertFalse(running.canCompare)
        XCTAssertNil(running.logPath)

        let failed = TrainingJobRow(job: try TF.job("failed"), home: TF.home)
        XCTAssertFalse(failed.canCancel)
        XCTAssertFalse(failed.canCompare)
    }

    func testPathAbbreviationOnlyTouchesTheHomePrefix() {
        XCTAssertEqual(TrainingPresentation.abbreviated("/Users/fixture/a/b", home: "/Users/fixture"), "~/a/b")
        XCTAssertEqual(TrainingPresentation.abbreviated("/Users/fixture", home: "/Users/fixture"), "~")
        XCTAssertEqual(TrainingPresentation.abbreviated("/Users/fixtures/a", home: "/Users/fixture"), "/Users/fixtures/a")
        XCTAssertEqual(TrainingPresentation.abbreviated("/Volumes/x/a", home: "/Users/fixture"), "/Volumes/x/a")
        XCTAssertEqual(TrainingPresentation.abbreviated("/Volumes/x/a", home: nil), "/Volumes/x/a")
    }

    func testEvaluationRowsShowAShortIDAndARelativeDate() throws {
        let created = Date(timeIntervalSinceReferenceDate: 1_000_000_000 - 7_200)
        let raw = TF.formatter.string(from: created)
        let rows = TrainingPresentation.make(
            jobs: [], evaluations: [try TF.evaluation("0123456789abcdef", created: raw)], home: TF.home, now: TF.now
        ).evaluations
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "0123456789abcdef")
        XCTAssertEqual(rows[0].shortID, "01234567")
        XCTAssertEqual(rows[0].dateText, WorkbenchRelativeTime.text(for: created, style: .full, now: TF.now))
        XCTAssertNotEqual(rows[0].dateText, raw)
    }

    func testEvaluationDatesFallBackToTheirOwnText() throws {
        XCTAssertEqual(TrainingPresentation.dateText("yesterday-ish", now: TF.now), "yesterday-ish")
        let row = try XCTUnwrap(TrainingEvaluationRow(value: TF.evaluation("short", created: nil), now: TF.now))
        XCTAssertEqual(row.shortID, "short")
        XCTAssertNil(row.dateText)
        let noID = try JSONDecoder().decode(LabValue.self, from: Data(#"{"created_at":"x"}"#.utf8))
        XCTAssertNil(TrainingEvaluationRow(value: noID, now: TF.now))
    }
}

// MARK: - Loader

@MainActor
final class TrainingLoaderTests: XCTestCase {
    func testRunningJobUpdatesStopAfterCompletionWithoutReadingEvaluationHistory() async throws {
        let running = try TF.job("running"), done = try TF.job("done")
        let evaluation = try TF.evaluation("retained", created: nil)
        var reads = 0, waits = 0, historyReads = 0
        let loader = TrainingLoader(jobs: { reads += 1; return [reads == 1 ? running : done] },
            history: { historyReads += 1; return [] }, seededJobs: [running], seededEvaluations: [evaluation])
        await loader.refreshActiveJobs(wait: { waits += 1 })
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(loader.jobs.first?.state, "done")
        XCTAssertEqual(loader.evaluations, [evaluation])
        XCTAssertEqual(historyReads, 0)
        XCTAssertFalse(loader.needsJobUpdates)
    }

    func testInactiveJobStatesNeverStartAutomaticReads() async throws {
        for state in ["done", "failed", "cancelled", "unknown"] {
            let loader = TrainingLoader(jobs: { XCTFail("Must not read terminal or unknown jobs"); return [] },
                history: { [] }, seededJobs: [try TF.job(state)])
            await loader.refreshActiveJobs(wait: { XCTFail("Must not schedule terminal or unknown jobs") })
        }
        let empty = TrainingLoader(jobs: { XCTFail("Must not read an empty history"); return [] }, history: { [] })
        await empty.refreshActiveJobs(wait: { XCTFail("Must not schedule an empty history") })
    }

    func testJobReadFailureStopsUpdatesUntilManualRetry() async throws {
        let running = try TF.job("running"), done = try TF.job("done")
        var failing = true, reads = 0, waits = 0
        let loader = TrainingLoader(jobs: {
            reads += 1
            if failing { throw Boom() }
            return [reads == 2 ? running : done]
        }, history: { [] }, render: { $0.localizedDescription }, seededJobs: [running])
        await loader.refreshActiveJobs(wait: { waits += 1 })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(loader.jobs.first?.state, "running")
        XCTAssertEqual(loader.jobsError, "boom")
        XCTAssertFalse(loader.needsJobUpdates)
        failing = false
        await loader.refreshJobs()?.value
        XCTAssertTrue(loader.needsJobUpdates)
        await loader.refreshActiveJobs(wait: { waits += 1 })
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(loader.jobs.first?.state, "done")
        XCTAssertNil(loader.jobsError)
    }

    func testCancelledJobUpdatesDoNotReadAfterTheWaitReturns() async throws {
        var release: CheckedContinuation<Void, Never>?
        let loader = TrainingLoader(jobs: { XCTFail("Cancellation must prevent the next read"); return [] },
            history: { [] }, seededJobs: [try TF.job("running")])
        let updates = Task { await loader.refreshActiveJobs(wait: { await withCheckedContinuation { release = $0 } }) }
        await yieldUntil { release != nil }
        XCTAssertNotNil(release)
        updates.cancel()
        release?.resume()
        await updates.value
        XCTAssertFalse(loader.isLoadingJobs)
        XCTAssertNil(loader.jobsError)
    }

    func testCompletionDuringTheWaitPreventsAnotherRead() async throws {
        let done = try TF.job("done")
        var release: CheckedContinuation<Void, Never>?, reads = 0
        let loader = TrainingLoader(jobs: { reads += 1; return [done] }, history: { [] },
            seededJobs: [try TF.job("running")])
        let updates = Task { await loader.refreshActiveJobs(wait: { await withCheckedContinuation { release = $0 } }) }
        await yieldUntil { release != nil }
        XCTAssertNotNil(release)
        await loader.refreshJobs()?.value
        release?.resume()
        await updates.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(loader.jobs.first?.state, "done")
    }

    func testAutomaticReadUsesTheRequestLockWithoutShowingManualRefreshProgress() async throws {
        let done = try TF.job("done")
        var release: CheckedContinuation<[TrainingJob], Never>?
        let loader = TrainingLoader(jobs: { await withCheckedContinuation { release = $0 } }, history: { [] },
            seededJobs: [try TF.job("running")])
        let updates = Task { await loader.refreshActiveJobs(wait: {}) }
        await yieldUntil { release != nil }
        XCTAssertNotNil(release)
        XCTAssertFalse(loader.isLoadingJobs)
        XCTAssertNil(loader.refreshJobs(), "Manual and automatic reads share one request lock")
        release?.resume(returning: [done])
        await updates.value
        XCTAssertEqual(loader.jobs.first?.state, "done")
    }

    func testJobsSurviveAHistoryFailure() async throws {
        let job = try TF.job("running")
        let loader = TrainingLoader(jobs: { [job] }, history: { throw Boom() }, render: { $0.localizedDescription })
        await loader.refresh()
        XCTAssertEqual(loader.jobs.map(\.id), ["r1"])
        XCTAssertNil(loader.jobsError)
        XCTAssertEqual(loader.historyError, "boom")
    }

    func testHistorySurvivesAJobsFailure() async throws {
        let evaluation = try TF.evaluation("e1", created: nil)
        let loader = TrainingLoader(jobs: { throw Boom() }, history: { [evaluation] }, render: { $0.localizedDescription })
        await loader.refresh()
        XCTAssertEqual(loader.evaluations, [evaluation])
        XCTAssertEqual(loader.jobsError, "boom")
        XCTAssertNil(loader.historyError)
    }

    func testAFailedRefreshKeepsWhatLoadedBeforeAndARetryClearsTheError() async throws {
        let job = try TF.job("done")
        var failing = false
        let loader = TrainingLoader(
            jobs: { if failing { throw Boom() }; return [job] }, history: { [] }, render: { $0.localizedDescription }
        )
        await loader.refresh()
        failing = true
        await loader.refresh()
        XCTAssertEqual(loader.jobs.count, 1)
        XCTAssertEqual(loader.jobsError, "boom")
        failing = false
        await loader.refresh()
        XCTAssertNil(loader.jobsError)
    }

    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }

    func testHistoryPublishesWhileJobsAreStillLoading() async throws {
        let evaluation = try TF.evaluation("e1", created: nil)
        var release: CheckedContinuation<[TrainingJob], Never>?
        let loader = TrainingLoader(
            jobs: { await withCheckedContinuation { release = $0 } }, history: { [evaluation] },
            render: { $0.localizedDescription }
        )
        let refresh = Task { await loader.refresh() }
        await yieldUntil { !loader.evaluations.isEmpty }
        XCTAssertEqual(loader.evaluations, [evaluation])
        XCTAssertTrue(loader.jobs.isEmpty)
        release?.resume(returning: [try TF.job("running")])
        await refresh.value
        XCTAssertEqual(loader.jobs.map(\.id), ["r1"])
    }

    func testAStaleRefreshNeverOverwritesANewerOne() async throws {
        let stale = try TF.job("running", receipt: "stale"), fresh = try TF.job("done", receipt: "fresh")
        var calls = 0
        var release: CheckedContinuation<[TrainingJob], Never>?
        let loader = TrainingLoader(
            jobs: {
                calls += 1
                if calls == 1 { return await withCheckedContinuation { release = $0 } }
                return [fresh]
            }, history: { [] }, render: { $0.localizedDescription }
        )
        let first = Task { await loader.refresh() }
        await yieldUntil { release != nil }
        await loader.refresh()
        XCTAssertEqual(loader.jobs.map(\.id), ["fresh"])
        release?.resume(returning: [stale])
        await first.value
        XCTAssertEqual(loader.jobs.map(\.id), ["fresh"])
    }
}

// MARK: - Source

final class TrainingSourceTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNoInlineJSONDumps() throws {
        for name in ["TrainingView.swift", "TrainingViews.swift", "TrainingPresentation.swift"] {
            let text = try source(name)
            XCTAssertFalse(text.contains(".jsonText).font("), "\(name) draws raw JSON outside a disclosure")
            if name != "TrainingPresentation.swift" {
                XCTAssertFalse(text.contains("job.state)"), "\(name) shows the raw agent state")
            }
        }
    }

    func testRefreshRunsOnlyWhileTheRouteIsActive() throws {
        let text = try source("TrainingView.swift")
        XCTAssertTrue(text.contains(".task(id: isRouteActive)"))
        XCTAssertTrue(text.contains("guard isRouteActive else { return }"))
    }

    func testEveryBorderedButtonIsSmall() throws {
        let lines = try source("TrainingViews.swift").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.contains(".buttonStyle(.bordered)") {
            let nearby = lines[index...].prefix(2).joined()
            XCTAssertTrue(nearby.contains(".controlSize(.small)"), "line \(index + 1) is not small")
        }
    }

    func testThereIsOneStatusBadge() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mlx-mac/UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil))
        var declarations = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            declarations += text.components(separatedBy: "\n").filter {
                $0.range(of: #"^\s*(private |fileprivate )?struct \w*StatusBadge\b"#, options: .regularExpression) != nil
            }.count
        }
        XCTAssertEqual(declarations, 1)
    }

    func testUITestAnchorsStay() throws {
        let text = try source("TrainingView.swift")
        for anchor in ["LoRA fine-tune", "Base model repo id", "Dataset path", "Preview Training", "Confirm & Train"] {
            XCTAssertTrue(text.contains("\"\(anchor)\""), anchor)
        }
        XCTAssertTrue(text.contains(#"TextField("Iterations""#))
    }
}

// MARK: - Renders

@MainActor
final class TrainingRenderTests: XCTestCase {
    func testTrainedAdapterRunUsesEnginePreviewAndRejectsChangedFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_TRAINED_ADAPTER_CAPTURE"] else {
            throw XCTSkip("Set MLX_WORKBENCH_TRAINED_ADAPTER_CAPTURE for the isolated engine receipt fixture.")
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = URL(fileURLWithPath: path).standardizedFileURL
        XCTAssertEqual(root.deletingLastPathComponent(), source.appendingPathComponent(".run"))
        XCTAssertTrue(root.lastPathComponent.hasPrefix("trained-adapter-"))
        guard root.deletingLastPathComponent() == source.appendingPathComponent(".run"),
              root.lastPathComponent.hasPrefix("trained-adapter-"), root.resolvingSymlinksInPath() == root else {
            throw CocoaError(.fileReadNoPermission)
        }
        let adapterConfig = root.appendingPathComponent("adapter/adapter_config.json")
        guard adapterConfig.resolvingSymlinksInPath() == adapterConfig else { throw CocoaError(.fileReadNoPermission) }
        let original = try Data(contentsOf: adapterConfig)
        defer { if adapterConfig.resolvingSymlinksInPath() == adapterConfig { try? original.write(to: adapterConfig) } }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: source.appendingPathComponent("vendor/mlx-agent").path,
            receiptDirectory: root.appendingPathComponent("state").path)
        let jobs = try await api.trainingStatus().jobs
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.state, "done")
        let coordinator = TrainedAdapterServingCoordinator(api: .live(api))
        XCTAssertTrue(coordinator.select(job))
        XCTAssertNil(coordinator.preview)
        for width in [CGFloat(514), 814] {
            try await attach(TrainedAdapterRunPanel(coordinator: coordinator, refresh: {}).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top), name: "trained-staged", viewport: width,
                dark: true, height: 900, captureDirectory: root)
        }
        await coordinator.previewServe()?.value
        XCTAssertTrue(coordinator.canConfirm, coordinator.errorMessage ?? "Missing confirmation")
        let reviewed = try XCTUnwrap(coordinator.preview)
        XCTAssertEqual(reviewed.binding.receiptPath, job.receipt)
        XCTAssertEqual(reviewed.binding.adapterIdentity, job.adapterIdentity)
        for width in [CGFloat(514), 814] {
            try await attach(TrainedAdapterRunPanel(coordinator: coordinator, refresh: {}).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top), name: "trained-reviewed", viewport: width,
                dark: true, height: 1300, captureDirectory: root)
        }
        guard adapterConfig.resolvingSymlinksInPath() == adapterConfig else { throw CocoaError(.fileReadNoPermission) }
        try Data("{\"fixture_changed\":true}".utf8).write(to: adapterConfig)
        await coordinator.confirmServe()?.value
        XCTAssertNil(coordinator.runningServer)
        XCTAssertFalse(coordinator.canConfirm)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state/.mlx-agent-receipts/serve").path))
        for width in [CGFloat(514), 814] {
            try await attach(TrainedAdapterRunPanel(coordinator: coordinator, refresh: {}).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top), name: "trained-drift-refused", viewport: width,
                dark: true, height: 1000, captureDirectory: root)
        }
    }

    private func config() -> Config {
        Config(
            schemaVersion: Config.SCHEMA_VERSION, ggufRoots: ["/m"], mlxRoots: [], outputDir: "/out/mlx",
            mlxAgentPath: "/agent", quarantineDir: "/quarantine", qBits: 4, signatures: true, host: "127.0.0.1",
            port: 8765, verificationEnabled: true, watchEnabled: true, fitReserveGB: 4, reclaimStaleDays: 60,
            comparisonMaxTokens: 512
        )
    }

    private func host() -> AppHost {
        AppHost(
            config: config(), discoveredRoots: [], configPath: "/state/config.json", agentHealth: .notConfigured,
            runtimeReport: RuntimeReport(
                convert: ConvertStatus(ok: true, modules: [:], executables: [:], missingModules: [], missingExecutables: [], install: "make install", message: "Ready."),
                serve: ServeStatus(ok: true, executables: [:], missingExecutables: [], install: "make install", message: "Ready."),
                install: "make install", ok: true
            ), hardwareProfile: HardwareProfile(chip: "Apple M4 Max", model: nil, memoryBytes: 137_438_953_472, macOSVersion: nil),
            modelWorkflowAPI: ModelWorkflowAPI(
                convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
                servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] }, serveStatus: { [] }, serveStop: { _ in [:] }
            ),
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in })
        )
    }

    private func attach<Content: View>(_ view: Content, name: String, viewport: CGFloat, dark: Bool, height: CGFloat = 1300,
                                     captureDirectory: URL? = nil) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: viewport, height: height).background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: viewport, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        hosting.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name)-\(dark ? "dark" : "light")-\(Int(viewport))"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let captureDirectory {
            try png.write(to: captureDirectory.appendingPathComponent("\(name)-\(Int(viewport)).png"))
        }
    }

    private func loader(jobs: [TrainingJob], evaluations: [LabValue], jobsError: String? = nil, historyError: String? = nil) -> TrainingLoader {
        func failure(_ text: String) -> NSError { NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        return TrainingLoader(
            jobs: { if let jobsError { throw failure(jobsError) }; return jobs },
            history: { if let historyError { throw failure(historyError) }; return evaluations },
            render: { $0.localizedDescription },
            seededJobs: jobs, seededEvaluations: evaluations
        )
    }

    func testTrainingSetupAndCapturedPlanRenderAtNarrowAndRegularWidths() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_TRAINING_CAPTURE"] else {
            throw XCTSkip("Set MLX_WORKBENCH_TRAINING_CAPTURE for training setup captures.")
        }
        let directory = URL(fileURLWithPath: path)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("preview.json"))) as? [String: Any])
        let payload = try XCTUnwrap(envelope["data"] as? [String: Any])
        let plan = WorkbenchAPI.unwrapPlan(payload)
        let repo = try XCTUnwrap(plan["repo"] as? String)
        let dataset = try XCTUnwrap(plan["data"] as? String)
        for planned in [false, true] {
            for width in [CGFloat(514), 814] {
                var previewCalls = 0
                let session = TrainingSession(preview: { _ in previewCalls += 1; return payload },
                    start: { _, _ in XCTFail("Rendering must not start training") })
                if planned {
                    session.draft = TrainingDraft(repo: repo, data: dataset,
                        iterations: (plan["iters"] as? Int).map(String.init) ?? "100", output: plan["out"] as? String ?? "",
                        batchSize: (plan["batch_size"] as? Int).map(String.init) ?? "4")
                    await session.previewTraining()?.value
                    XCTAssertNotNil(session.preview)
                    XCTAssertEqual(session.canConfirm, TrainingPlanSummary(payload: payload).blockingReason == nil)
                }
                let records = loader(jobs: [], evaluations: [])
                await records.refresh()
                let view = TrainingView(appHost: host(), loader: records, session: session)
                try await attach(view.environment(\.isRouteActive, false), name: planned ? "plan" : "setup",
                    viewport: width, dark: true, height: planned ? 1600 : 1000, captureDirectory: directory)
                XCTAssertEqual(previewCalls, planned ? 1 : 0)
            }
        }
    }

    func testEvaluationSheetRendersCompletedFailedAndPendingRequests() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_TRAINING_CAPTURE"] else {
            throw XCTSkip("Set MLX_WORKBENCH_TRAINING_CAPTURE for evaluation sheet captures.")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = host(), job = try TF.job("done")
        let plan = LabResponse(plan: .object(["preview_hash": .string("reviewed")]))
        var fails = false
        let session = TrainingEvaluationSession(receipt: job.receipt) { request in
            if fails { throw Boom() }
            if request.operation == "training-preview" { return plan }
            return LabResponse(evaluationID: "text_eval_capture", report: .object([
                "schema_version": .string("text-training-evaluation/1"), "prompt": .string(request.prompt ?? ""),
                "max_tokens": .integer(128), "preview_hash": .string("reviewed"), "outputs": .object([
                "baseline": .string("Contact the billing team for help."),
                "adapter": .string("Contact billing with your order number to request a refund.")])]),
                artifactSHA256: String(repeating: "a", count: 64))
        }
        session.prompt = "How can I request a refund?"
        await session.previewEvaluation()?.value
        await session.evaluate()?.value
        XCTAssertNotNil(session.result)
        try await attach(TrainingEvaluationSheet(lab: app.lab, job: job, session: session),
            name: "evaluation-completed", viewport: 740, dark: true, height: 620, captureDirectory: directory)
        fails = true
        await session.previewEvaluation()?.value
        XCTAssertNil(session.result)
        XCTAssertFalse(session.canEvaluate)
        try await attach(TrainingEvaluationSheet(lab: app.lab, job: job, session: session),
            name: "evaluation-repreview-failed", viewport: 740, dark: true, height: 620, captureDirectory: directory)

        let started = expectation(description: "preview pending")
        var completion: CheckedContinuation<LabResponse, Never>?
        let pending = TrainingEvaluationSession(receipt: job.receipt) { _ in
            await withCheckedContinuation { completion = $0; started.fulfill() }
        }
        pending.prompt = session.prompt
        let task = pending.previewEvaluation()
        await fulfillment(of: [started], timeout: 1)
        defer { completion?.resume(returning: plan) }
        XCTAssertTrue(pending.isBusy)
        XCTAssertFalse(pending.canPreview)
        XCTAssertFalse(pending.canEvaluate)
        try await attach(TrainingEvaluationSheet(lab: app.lab, job: job, session: pending),
            name: "evaluation-preview-pending", viewport: 740, dark: true, height: 620, captureDirectory: directory)
        completion?.resume(returning: plan); completion = nil
        await task?.value
        XCTAssertTrue(pending.canEvaluate)
    }

    func testEveryStateRendersDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let jobs = [
            try TF.job("running", repo: "mlx-community/Llama-3.2-3B-Instruct-4bit", out: "/Users/fixture/adapters/a-very-long-output-directory/llama-3b-lora-run-0007", identity: false, receipt: "r1"),
            try TF.job("done", repo: "mlx-community/Qwen3-8B-4bit", out: "/Users/fixture/adapters/qwen", receipt: "r2"),
            try TF.job("failed", repo: "org/base-model", out: "/Users/fixture/adapters/failed", identity: false, receipt: "r3"),
            try TF.job("rebalancing", repo: "org/other", out: "/Users/fixture/adapters/other", log: nil, identity: false, receipt: "r4"),
        ]
        let evaluations = [
            try TF.evaluation("0123456789abcdef", created: TF.formatter.string(from: Date().addingTimeInterval(-7_200))),
            try TF.evaluation("fedcba9876543210", created: TF.formatter.string(from: Date().addingTimeInterval(-259_200))),
        ]
        struct Scenario {
            let name: String
            let loader: TrainingLoader
            var planned = false
            var retained: TrainingRetainedEvidence?
        }
        let report = #"{"adapter":"qwen","outputs":[{"prompt":"hello","base":"hi","tuned":"hello there"}],"recipe":{"iters":100}}"#
        let scenarios = [
            Scenario(name: "empty", loader: loader(jobs: [], evaluations: [])),
            Scenario(name: "jobs", loader: loader(jobs: jobs, evaluations: evaluations)),
            Scenario(name: "jobs-error", loader: loader(jobs: [], evaluations: evaluations, jobsError: "usage: mlx-agent train status [-h] --json\nmlx-agent: error: unrecognized arguments")),
            Scenario(name: "history-error", loader: loader(jobs: jobs, evaluations: [], historyError: "usage: mlx-agent lab [-h] operation\nmlx-agent: error: the following arguments are required")),
            Scenario(
                name: "inspected", loader: loader(jobs: jobs, evaluations: evaluations),
                retained: TrainingRetainedEvidence(evaluationID: "0123456789abcdef", reportText: report, sha256: "9f2c4e7a1b0d")
            ),
            Scenario(name: "plan", loader: loader(jobs: jobs, evaluations: evaluations), planned: true),
        ]
        for scenario in scenarios {
            await scenario.loader.refresh()
            if scenario.name == "jobs-error" { XCTAssertNotNil(scenario.loader.jobsError) }
            if scenario.name == "history-error" { XCTAssertNotNil(scenario.loader.historyError) }
            for dark in [true, false] {
                for width in [CGFloat(1220), 824, 514] {
                    let session = TrainingSession(preview: { _ in ["preview_hash": "h"] }, start: { _, _ in })
                    if scenario.planned {
                        session.draft = TrainingDraft(repo: "org/base-model", data: "/Users/fixture/data", iterations: "100", output: "")
                        await session.previewTraining()?.value
                    }
                    let view = TrainingView(appHost: host(), loader: scenario.loader, session: session, seedRetained: scenario.retained)
                    try await attach(view.environment(\.isRouteActive, false), name: "training-\(scenario.name)", viewport: width, dark: dark)
                }
            }
        }
    }
}

final class TrainingDatasetTests: XCTestCase {
    private func draft(batch: Int = 1) -> TrainingDatasetDraft {
        var value = TrainingDatasetDraft(batchSize: batch)
        value.train = (0..<batch).map { .init(prompt: "Learning request \($0)", reply: "Learning reply \($0)") }
        value.valid = (0..<batch).map { .init(prompt: "Held-out request \($0)", reply: "Held-out reply \($0)") }
        return value
    }

    func testBatchCountsBlankFieldsAndCrossSplitOverlapBlockExport() throws {
        var value = draft(batch: 4)
        XCTAssertNil(value.validationMessage)
        value.valid.removeLast()
        XCTAssertNotNil(value.validationMessage)
        value = draft()
        value.train[0].reply = " \n"
        XCTAssertNotNil(value.validationMessage)
        XCTAssertThrowsError(try value.encodedSplits())
        value = draft()
        value.valid = [.init(prompt: " \(value.train[0].prompt) ", reply: value.train[0].reply)]
        XCTAssertTrue(value.validationMessage?.contains("both splits") == true)
    }

    func testEncodingPreservesUnicodeAndEmbeddedNewlinesInOneRecord() throws {
        var value = draft()
        value.train[0] = .init(prompt: "Café\nWhat does it mean?", reply: "  A café serves coffee.\n☕  ")
        let data = try XCTUnwrap(value.encodedSplits()["train.jsonl"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self).split(separator: "\n").count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]])
        XCTAssertEqual(object["messages"]?.map { $0["role"] }, ["user", "assistant"])
        XCTAssertEqual(object["messages"]?[0]["content"], value.train[0].prompt)
        XCTAssertEqual(object["messages"]?[1]["content"], value.train[0].reply)
        value.train[0].reply = String(repeating: "x", count: 1024 * 1024)
        XCTAssertThrowsError(try value.encodedSplits())
    }

    func testExportPublishesBothFilesAndNeverReplacesExistingDirectoryOrLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("dataset")
        try TrainingDatasetExporter.save(draft(), to: target)
        let train = try Data(contentsOf: target.appendingPathComponent("train.jsonl"))
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: target.path)), ["train.jsonl", "valid.jsonl"])
        XCTAssertThrowsError(try TrainingDatasetExporter.save(draft(batch: 2), to: target))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("train.jsonl")), train)
        let link = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try TrainingDatasetExporter.save(draft(), to: link))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("train.jsonl")), train)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: root.path)), ["dataset", "linked"], "Failed saves must remove only their own staging folders")
    }

    func testInvalidDraftCreatesNothingAndDuplicateIdentitiesAreRefused() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try TrainingDatasetExporter.save(TrainingDatasetDraft(batchSize: 1), to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        var value = draft(batch: 2)
        value.train[1].id = value.train[0].id
        XCTAssertNotNil(value.validationMessage)
        XCTAssertThrowsError(try value.encodedSplits())
    }
}
