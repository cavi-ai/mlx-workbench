import Foundation
import XCTest
import AppKit
import SwiftUI

@testable import mlx_workbench

// MARK: - Fixtures

private enum Fixture {
    static let agentReady = AgentHealth.ready(path: "/agent", cli: "/agent/scripts/mlx-agent")
    static let agentNotConfigured = AgentHealth.notConfigured
    static let agentNotFound = AgentHealth.notFound(path: "/missing/agent", cli: "/missing/agent/scripts/mlx-agent")
    static let agentNotUsable = AgentHealth.notUsable(path: "/agent", cli: "/agent/scripts/mlx-agent", reason: "scripts/mlx-agent is not readable.")
    static let agents: [AgentHealth] = [agentReady, agentNotConfigured, agentNotFound, agentNotUsable]

    static let convertModules = ["torch", "transformers", "gguf", "accelerate"]
    static let allPrepare = Set(convertModules + ["mlx_lm.convert"])

    static func report(
        python: String? = "/venv/bin/python",
        missingPrepare: Set<String> = [],
        missingRun: Bool = false
    ) -> RuntimeReport {
        var modules: [String: Bool] = [:]
        for name in convertModules { modules[name] = !missingPrepare.contains(name) }
        let executables = ["mlx_lm.convert": !missingPrepare.contains("mlx_lm.convert")]
        let missingModules = convertModules.filter { missingPrepare.contains($0) }
        let missingExecutables = missingPrepare.contains("mlx_lm.convert") ? ["mlx_lm.convert"] : []
        let convertOK = missingPrepare.isEmpty
        let serveOK = !missingRun
        return RuntimeReport(
            convert: ConvertStatus(
                ok: convertOK, modules: modules, executables: executables,
                missingModules: missingModules, missingExecutables: missingExecutables,
                install: "make install", message: ""
            ),
            serve: ServeStatus(
                ok: serveOK, executables: ["mlx_lm.server": serveOK],
                missingExecutables: serveOK ? [] : ["mlx_lm.server"],
                install: "make install", message: ""
            ),
            install: "make install",
            ok: convertOK && serveOK,
            python: python
        )
    }

    static let fingerprint = EnvironmentFingerprint(macOSVersion: "15.6", chip: "Apple M4 Max", mlxLMVersion: "0.28.1")

    static func chain(
        _ agent: AgentHealth = agentReady,
        _ report: RuntimeReport = Fixture.report(),
        installAvailable: Bool = true
    ) -> HealthChain {
        HealthPresentation.chain(agent: agent, report: report, fingerprint: fingerprint, installAvailable: installAvailable)
    }

    static func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    static let doctorReport = """
    {
      "inventory": [],
      "summary": {"models": 12, "hf_cache_bytes": 4800000000, "wired_configs": 3, "findings": 5},
      "wired": [], "endpoints": [], "runtime_errors": [],
      "findings": [
        {"code": "hf_cache_incomplete", "path": null, "model": "mlx-community/atlas-4bit",
         "remediation": "The cached snapshot is incomplete; re-download the model with the runtime's own pull command."},
        {"code": "drift_missing_model", "path": "/work/.continue/config.json", "model": "ghost-model",
         "remediation": "Re-download the model into a local inventory, or re-run wire render for a model that is present."},
        {"code": "drift_missing_file", "path": "/work/.config/opencode/opencode.json", "receipt_id": "r1",
         "remediation": "The wired file is gone; restore it from the receipt backup or roll the receipt back."},
        {"code": "drift_hash_mismatch", "path": "/work/.zed/settings.json", "receipt_id": "r2",
         "remediation": "The wired file changed after wiring; inspect it, then re-apply or roll back the receipt."},
        {"code": "drift_endpoint_conflict", "path": "/work/aider.conf.yml", "model": "atlas",
         "remediation": "Two wired configs for different runtimes claim http://127.0.0.1:8080; move one runtime to its own port."}
      ]
    }
    """

    static func finding(_ code: String, path: String = "/work/config.json", model: String? = nil, size: Int64? = nil) -> DoctorFinding {
        DoctorFinding(path: path, kind: code, message: "remediation for \(code)", size: size, model: model)
    }

    static func result(_ findings: [DoctorFinding]?, prune: Int? = nil, summary: DoctorSummary? = nil) -> DoctorResult {
        DoctorResult(findings: findings, prune_count: prune, preview_hash: nil, reclaimedBytes: nil, removed: nil, summary: summary)
    }

    static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac", isDirectory: true)
    }

    static func source(_ relative: String) throws -> String {
        try String(contentsOf: sourceDirectory.appendingPathComponent(relative), encoding: .utf8)
    }
}

// MARK: - AC1 chain truth table

final class HealthChainTests: XCTestCase {
    @MainActor
    func testHealthRuntimeScopeRendersAtWideAndCompactWidths() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_HEALTH_CAPTURE"] else {
            throw XCTSkip("Set MLX_WORKBENCH_HEALTH_CAPTURE to inspect the native Health layout.")
        }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for missing in [false, true] {
            var config = Config.defaults(ggufRoots: [])
            config.watchEnabled = false
            let app = AppHost(config: config, discoveredRoots: [], vendorAgentPath: "/agent",
                configPath: root.appendingPathComponent("config.json").path,
                agentHealth: Fixture.agentReady, runtimeReport: Fixture.report(missingRun: missing))
            for width: CGFloat in [814, 1190] {
                let host = NSHostingView(rootView: DoctorView(appHost: app)
                    .frame(width: width, height: 1000).background(WorkbenchColor.canvas).preferredColorScheme(.dark))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: root.appendingPathComponent("health-\(missing ? "missing-base" : "base-passed")-\(Int(width)).png"))
            }
        }
    }

    private func words(_ chain: HealthChain) -> [String] { chain.links.map(\.stateWord) }

    func testAllReady() {
        let chain = Fixture.chain()
        XCTAssertEqual(chain.verdict, .ready)
        XCTAssertEqual(chain.verdict.text, "Base runtime checks passed")
        XCTAssertEqual(chain.links.map(\.title), ["mlx-agent", "Base Python", "Base conversion", "Base serving"])
        XCTAssertEqual(words(chain), ["Found", "Found", "Ready", "Ready"])
        XCTAssertEqual(chain.foundation.map(\.id), [.agent, .python])
        XCTAssertEqual(chain.capabilities.map(\.id), [.prepare, .run])
        XCTAssertEqual(chain.actions.prominentCount, 0)
        XCTAssertFalse(chain.actions.showsInstallCommand)
    }

    func testAgentStatesBlockPrepareAndRunButNotPython() {
        let cases: [(AgentHealth, HealthVerdict, String)] = [
            (Fixture.agentNotConfigured, .agentNotConfigured, "Not configured"),
            (Fixture.agentNotFound, .agentNotFound, "Not found"),
            (Fixture.agentNotUsable, .agentNotUsable, "Can't be used"),
        ]
        for (agent, verdict, word) in cases {
            let chain = Fixture.chain(agent)
            XCTAssertEqual(chain.verdict, verdict)
            XCTAssertEqual(words(chain), [word, "Found", "Waiting on mlx-agent", "Waiting on mlx-agent"], "\(agent)")
            XCTAssertFalse(chain.verdict.isReady)
        }
        XCTAssertEqual(Fixture.chain(Fixture.agentNotConfigured).verdict.text, "mlx-agent isn't configured")
        XCTAssertEqual(Fixture.chain(Fixture.agentNotFound).verdict.text, "mlx-agent wasn't found")
        XCTAssertEqual(Fixture.chain(Fixture.agentNotUsable).verdict.text, "mlx-agent can't be used")
    }

    func testAgentLinkNeverClaimsItRan() {
        let link = Fixture.chain().foundation[0]
        XCTAssertEqual(link.stateWord, "Found")
        XCTAssertEqual(link.detail, "/agent")
        XCTAssertTrue(link.detailIsPath)
        XCTAssertEqual(Fixture.chain(Fixture.agentNotFound).foundation[0].detail, "/missing/agent")
        XCTAssertEqual(Fixture.chain(Fixture.agentNotUsable).foundation[0].detail, "scripts/mlx-agent is not readable.")
        XCTAssertEqual(Fixture.chain(Fixture.agentNotConfigured).foundation[0].detail, "Set the checkout path in Settings.")
    }

    func testPythonMissingWithServeOKWaitsOnPython() {
        let report = Fixture.report(python: nil, missingPrepare: Fixture.allPrepare, missingRun: false)
        XCTAssertTrue(report.serve.ok)
        let chain = Fixture.chain(Fixture.agentReady, report)
        XCTAssertEqual(chain.verdict, .pythonMissing)
        XCTAssertEqual(chain.verdict.text, "Base Python wasn't found")
        XCTAssertEqual(words(chain), ["Found", "Not found", "Waiting on Python", "Waiting on Python"])
    }

    func testPrepareMissingOnly() {
        let chain = Fixture.chain(Fixture.agentReady, Fixture.report(missingPrepare: ["torch"]))
        XCTAssertEqual(chain.verdict, .prepareNeedsSetup)
        XCTAssertEqual(chain.verdict.text, "Base conversion needs setup")
        XCTAssertEqual(words(chain), ["Found", "Found", "Missing 1", "Ready"])
        XCTAssertEqual(chain.capabilities[0].parts.map(\.isPresent), [false, true, true, true, true])
    }

    func testRunMissingOnly() {
        let chain = Fixture.chain(Fixture.agentReady, Fixture.report(missingRun: true))
        XCTAssertEqual(chain.verdict, .runNeedsSetup)
        XCTAssertEqual(chain.verdict.text, "Base serving needs setup")
        XCTAssertEqual(words(chain), ["Found", "Found", "Ready", "Missing 1"])
        XCTAssertEqual(chain.capabilities[1].parts.map(\.isPresent), [false])
    }

    func testBothMissing() {
        let chain = Fixture.chain(Fixture.agentReady, Fixture.report(missingPrepare: ["torch", "gguf"], missingRun: true))
        XCTAssertEqual(chain.verdict, .prepareAndRunNeedSetup)
        XCTAssertEqual(chain.verdict.text, "Base runtimes need setup")
        XCTAssertEqual(words(chain), ["Found", "Found", "Missing 2", "Missing 1"])
    }

    func testAgentBrokenAndRuntimeBrokenTogether() {
        let chain = Fixture.chain(Fixture.agentNotFound, Fixture.report(missingPrepare: ["torch"], missingRun: true))
        XCTAssertEqual(chain.verdict, .agentNotFound)
        XCTAssertEqual(words(chain), ["Not found", "Found", "Waiting on mlx-agent", "Waiting on mlx-agent"])
        XCTAssertTrue(chain.actions.showsInstall, "Install stays reachable when the agent is also broken")
        XCTAssertTrue(chain.actions.showsInstallCommand)
        XCTAssertTrue(chain.actions.showsOpenSettings)
        XCTAssertFalse(chain.actions.openSettingsIsProminent)
        XCTAssertEqual(chain.actions.prominentCount, 1)
    }

    func testRuntimeOnlyBrokenDoesNotOfferOpenSettings() {
        let chain = Fixture.chain(Fixture.agentReady, Fixture.report(missingPrepare: ["torch"]))
        XCTAssertFalse(chain.actions.showsOpenSettings)
        XCTAssertTrue(chain.actions.showsInstallCommand)
    }

    func testReadyAppearsIffAgentReadyAndReportOK() {
        let pythons: [String?] = ["/venv/bin/python", nil]
        for agent in Fixture.agents {
            for python in pythons {
                for convertBroken in [false, true] {
                    for runBroken in [false, true] {
                        let report = Fixture.report(
                            python: python, missingPrepare: convertBroken ? ["torch"] : [], missingRun: runBroken
                        )
                        let chain = Fixture.chain(agent, report)
                        var agentReady = false
                        if case .ready = agent { agentReady = true }
                        XCTAssertEqual(chain.verdict.isReady, agentReady && report.ok, "\(agent) \(python ?? "nil") \(convertBroken) \(runBroken)")
                        XCTAssertEqual(chain.verdict.text == "Base runtime checks passed", chain.verdict.isReady)
                        XCTAssertFalse(chain.capabilities[1].stateWord.contains("Prepare"), "Run never waits on Prepare")
                        XCTAssertEqual(chain.foundation[1].stateWord, python == nil ? "Not found" : "Found", "Python shows its own state")
                    }
                }
            }
        }
    }

    func testPartsKeepTheProbeDeclaredOrder() throws {
        let chain = Fixture.chain()
        XCTAssertEqual(chain.capabilities[0].parts.map(\.name), ["torch", "transformers", "gguf", "accelerate", "mlx_lm.convert"])
        XCTAssertEqual(chain.capabilities[1].parts.map(\.name), ["mlx_lm.server"])
        let checker = try Fixture.source("Services/RuntimeChecker.swift")
        XCTAssertTrue(checker.contains(#"convertModules = ["torch", "transformers", "gguf", "accelerate"]"#))
        XCTAssertTrue(checker.contains(#"convertExecutables = ["mlx_lm.convert"]"#))
        XCTAssertTrue(checker.contains(#"serveExecutables = ["mlx_lm.server"]"#))
        XCTAssertEqual(HealthPresentation.prepareParts, ["torch", "transformers", "gguf", "accelerate", "mlx_lm.convert"])
        XCTAssertEqual(HealthPresentation.runParts, ["mlx_lm.server"])
    }

    func testEnvironmentLineNamesUnknownParts() {
        XCTAssertEqual(HealthPresentation.environmentLine(Fixture.fingerprint), "macOS 15.6 · Apple M4 Max · mlx-lm 0.28.1")
        let unknown = EnvironmentFingerprint(macOSVersion: "unknown", chip: "unknown", mlxLMVersion: nil)
        XCTAssertEqual(HealthPresentation.environmentLine(unknown), "macOS unknown · chip unknown · mlx-lm unknown")
    }

    func testAtMostOneProminentActionPerState() {
        for agent in Fixture.agents {
            for broken in [false, true] {
                for installAvailable in [false, true] {
                    let report = Fixture.report(missingPrepare: broken ? ["torch"] : [])
                    let actions = Fixture.chain(agent, report, installAvailable: installAvailable).actions
                    XCTAssertLessThanOrEqual(actions.prominentCount, 1, "\(agent) \(broken) \(installAvailable)")
                    XCTAssertEqual(actions.showsInstall, broken && installAvailable)
                    var agentReady = false
                    if case .ready = agent { agentReady = true }
                    XCTAssertEqual(actions.showsOpenSettings, !agentReady)
                    if !agentReady && !actions.showsInstall {
                        XCTAssertTrue(actions.openSettingsIsProminent, "Open Settings leads when it is the only fix")
                    }
                }
            }
        }
    }

    func testRuntimeReportPythonDefaultsToNil() {
        let plain = RuntimeReport(
            convert: Fixture.report().convert, serve: Fixture.report().serve, install: "make install", ok: true
        )
        XCTAssertNil(plain.python)
        XCTAssertEqual(Fixture.report(python: "/usr/bin/python3").python, "/usr/bin/python3")
    }
}

// MARK: - AC2, AC3 decoder and prunable count

final class HealthDecoderTests: XCTestCase {
    func testDoctorReportDecodesFiveCodesAndSummary() throws {
        let result = WorkbenchAPI.doctor(from: try Fixture.json(Fixture.doctorReport))
        let findings = try XCTUnwrap(result.findings)
        XCTAssertEqual(findings.map(\.kind), [
            "hf_cache_incomplete", "drift_missing_model", "drift_missing_file", "drift_hash_mismatch", "drift_endpoint_conflict",
        ])
        XCTAssertEqual(findings[0].path, "mlx-community/atlas-4bit", "a null path decodes to the repo id")
        XCTAssertEqual(findings[0].model, "mlx-community/atlas-4bit")
        XCTAssertEqual(findings[1].path, "/work/.continue/config.json")
        XCTAssertEqual(findings[1].model, "ghost-model", "model survives when a path is present")
        XCTAssertNil(findings[2].model)
        XCTAssertEqual(findings[4].model, "atlas")
        XCTAssertTrue(findings.allSatisfy { $0.message?.isEmpty == false }, "remediation becomes the message")
        XCTAssertEqual(result.summary, DoctorSummary(models: 12, hfCacheBytes: 4_800_000_000, wiredConfigs: 3, findings: 5))
        XCTAssertEqual(result.prune_count, 1, "only the incomplete download is prunable")
    }

    func testPrunableCountRules() throws {
        let mixed = WorkbenchAPI.doctor(from: try Fixture.json("""
        {"findings": [
          {"code": "drift_missing_file", "path": "/a"},
          {"code": "drift_hash_mismatch", "path": "/b"},
          {"code": "hf_cache_incomplete", "path": null, "model": "org/repo"}
        ]}
        """))
        XCTAssertEqual(mixed.prune_count, 1)

        let driftOnly = WorkbenchAPI.doctor(from: try Fixture.json("""
        {"findings": [
          {"code": "drift_missing_file", "path": "/a"},
          {"code": "drift_endpoint_conflict", "path": "/b"}
        ]}
        """))
        XCTAssertEqual(driftOnly.prune_count, 0)
        let state = DoctorCheckState.completed(driftOnly)
        XCTAssertFalse(state.isClean, "drift is a finding")
        let groups = HealthDoctor.groups(findings: state.findings, prunableCount: state.pruneCount, models: [])
        XCTAssertTrue(groups.allSatisfy { $0.prunableLine == nil })

        let explicit = WorkbenchAPI.doctor(from: try Fixture.json("""
        {"prune_count": 4, "findings": [{"code": "drift_missing_file", "path": "/a"}]}
        """))
        XCTAssertEqual(explicit.prune_count, 4)
    }

    func testPreviewConfirmAndEmptyShapes() throws {
        let preview = WorkbenchAPI.doctor(from: try Fixture.json("""
        {"plan": {"candidates": [{"repo": "a/b", "path": "/c/a", "bytes": 10}, {"repo": "c/d", "path": "/c/c", "bytes": 20}],
                  "total_bytes": 30, "preview_hash": "abc"}, "requires_confirmation": true}
        """))
        XCTAssertNil(preview.findings)
        XCTAssertEqual(preview.prune_count, 2)
        XCTAssertEqual(preview.preview_hash, "abc")
        XCTAssertEqual(preview.reclaimedBytes, 30)

        let confirm = WorkbenchAPI.doctor(from: try Fixture.json("""
        {"status": "pruned", "removed": [{"repo": "a/b", "removed": true, "bytes": 10}]}
        """))
        XCTAssertEqual(confirm.prune_count, 0)
        XCTAssertEqual(confirm.removed?.count, 1)

        let empty = WorkbenchAPI.doctor(from: try Fixture.json(#"{"findings": [], "prune_count": 0}"#))
        XCTAssertEqual(empty.findings, [])
        XCTAssertEqual(empty.prune_count, 0)
        XCTAssertNil(empty.summary)
        XCTAssertTrue(DoctorCheckState.completed(empty).isClean)
    }

    func testStoredFieldsAreAdditive() {
        let finding = DoctorFinding(path: "/a", kind: nil, message: nil, size: nil)
        XCTAssertNil(finding.model)
        XCTAssertNil(Fixture.result([]).summary)
        XCTAssertTrue(DoctorFinding(path: "x", kind: "hf_cache_incomplete", message: nil, size: nil).isIncompleteDownload)
        XCTAssertFalse(DoctorFinding(path: "x", kind: "drift_missing_file", message: nil, size: nil).isIncompleteDownload)
        XCTAssertTrue(DoctorFinding(path: "x", kind: "drift_missing_file", message: nil, size: nil).isDrift)
    }
}

// MARK: - AC4, AC5 copy and naming

final class HealthDoctorCopyTests: XCTestCase {
    private func groups(_ report: String = Fixture.doctorReport) throws -> [HealthFindingGroup] {
        let result = WorkbenchAPI.doctor(from: try Fixture.json(report))
        let state = DoctorCheckState.completed(result)
        return HealthDoctor.groups(findings: state.findings, prunableCount: state.pruneCount, models: [])
    }

    func testGroupsAreOrderedAndTitledByCode() throws {
        let groups = try groups()
        XCTAssertEqual(groups.map(\.title), [
            "Incomplete download", "Client config names a missing model", "Wired file missing",
            "Wired file changed after wiring", "Port claimed by two runtimes",
        ])
        XCTAssertEqual(groups[0].heading, "Incomplete download · 1")
    }

    func testRowsAreNamedByCodeNotByPathShape() throws {
        let groups = try groups()
        let incomplete = groups[0].rows[0]
        XCTAssertEqual(incomplete.title, "mlx-community/atlas-4bit")
        XCTAssertNil(incomplete.detail)
        let missingModel = groups[1].rows[0]
        XCTAssertEqual(missingModel.title, "ghost-model")
        XCTAssertEqual(missingModel.detail, "/work/.continue/config.json")
        let missingFile = groups[2].rows[0]
        XCTAssertEqual(missingFile.title, "opencode.json")
        XCTAssertEqual(missingFile.detail, "/work/.config/opencode/opencode.json")
        XCTAssertEqual(groups[3].rows[0].title, "settings.json")
        XCTAssertEqual(groups[4].rows[0].title, "aider.conf.yml")
        XCTAssertEqual(groups[4].rows[0].detail, "/work/aider.conf.yml")
    }

    func testRemediationIsVerbatimAndUnknownCodesAreHumanized() throws {
        let groups = try groups()
        XCTAssertEqual(
            groups[2].rows[0].remediation,
            "The wired file is gone; restore it from the receipt backup or roll the receipt back."
        )
        let unknown = HealthDoctor.groups(
            findings: [Fixture.finding("disk_almost_full", path: "/vol", size: 2_000_000_000)], prunableCount: 0, models: []
        )
        XCTAssertEqual(unknown.map(\.title), ["Disk almost full"])
        XCTAssertEqual(unknown[0].rows[0].remediation, "remediation for disk_almost_full")
        XCTAssertNotNil(unknown[0].rows[0].size)
        let unlabeled = HealthDoctor.groups(
            findings: [DoctorFinding(path: "/x", kind: nil, message: nil, size: nil)], prunableCount: 0, models: []
        )
        XCTAssertEqual(unlabeled.map(\.title), ["Issue"])
    }

    func testPrunableLineLivesOnlyUnderTheIncompleteGroup() throws {
        let groups = try groups()
        XCTAssertEqual(groups[0].prunableLine, "1 incomplete download can be removed in Reclaim")
        XCTAssertTrue(groups.dropFirst().allSatisfy { $0.prunableLine == nil })
        let onlyCount = HealthDoctor.groups(findings: [], prunableCount: 2, models: [])
        XCTAssertEqual(onlyCount.map(\.title), ["Incomplete download"])
        XCTAssertEqual(onlyCount[0].prunableLine, "2 incomplete downloads can be removed in Reclaim")
    }

    func testCleanCopyCountsModelsHonestly() {
        let summary = DoctorSummary(models: 12, hfCacheBytes: 4_800_000_000, wiredConfigs: 3, findings: 0)
        let lines = HealthDoctor.cleanLines(summary)
        XCTAssertEqual(lines[0], "12 models checked across the Hugging Face cache and running local servers")
        XCTAssertTrue(lines[1].hasSuffix("in the default Hugging Face cache"))
        XCTAssertEqual(HealthDoctor.cleanLines(DoctorSummary(models: 1, hfCacheBytes: nil, wiredConfigs: nil, findings: nil)),
                       ["1 model checked across the Hugging Face cache and running local servers"])
        XCTAssertEqual(HealthDoctor.cleanLines(nil), [], "no summary, no number")
        for line in lines {
            XCTAssertFalse(line.localizedCaseInsensitiveContains("files"))
            XCTAssertFalse(line.localizedCaseInsensitiveContains("client config"))
            XCTAssertFalse(line.localizedCaseInsensitiveContains("wired"))
        }
    }

    func testDoctorCheckStateStringsStayByteForByte() {
        XCTAssertEqual(DoctorCheckState.notRun.message, "Inventory has not been checked. Run doctor to check local model files.")
        XCTAssertEqual(DoctorCheckState.running.message, "Checking local model files for inventory issues…")
        XCTAssertEqual(DoctorCheckState.completed(Fixture.result([])).message, "No inventory issues found in the latest doctor run.")
        XCTAssertEqual(
            DoctorCheckState.completed(Fixture.result([Fixture.finding("drift_missing_file")])).message,
            "The latest doctor run found inventory issues. Review the findings below."
        )
        XCTAssertEqual(
            DoctorCheckState.failed("Fixture doctor failed").message,
            "Inventory check failed. Fixture doctor failed Retry Run doctor after resolving the issue."
        )
    }

    func testUITestStringsStayInTheSources() throws {
        let doctor = try Fixture.source("UI/Views/DoctorView.swift")
        for text in [
            #"SectionTitle(text: "Model inventory findings")"#,
            "Inventory has not been checked. Run doctor to check local model files.",
            "No inventory issues found in the latest doctor run.",
            #"Button("Clear")"#,
            #""Run doctor""#,
            #""Checking…""#,
            #".accessibilityLabel("Checking inventory")"#,
            #"Label("Setup Assistant…""#,
            #"appHost.setup.presentAgain()"#,
            #"onRouteSelection(.settings)"#,
            #"onRouteSelection(.reclaim)"#,
        ] {
            XCTAssertTrue(doctor.contains(text), "DoctorView.swift is missing \(text)")
        }
        let views = try Fixture.source("UI/Views/HealthViews.swift")
        for text in [#"Button("Copy command")"#, #"Button("Open Settings""#, #"Button("Open Reclaim""#, "RuntimeInstallView(installer: installer"] {
            XCTAssertTrue(views.contains(text), "HealthViews.swift is missing \(text)")
        }
    }

    func testCheckedTimeIsRelativeAndOutsideTheCompletedPayload() throws {
        let checked = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(HealthDoctor.checkedText(checked, now: checked.addingTimeInterval(30)), "Checked just now")
        XCTAssertEqual(
            HealthDoctor.checkedText(checked, now: checked.addingTimeInterval(180)),
            "Checked " + WorkbenchRelativeTime.text(for: checked, style: .full, now: checked.addingTimeInterval(180))
        )
        let doctor = try Fixture.source("UI/Views/DoctorView.swift")
        XCTAssertTrue(doctor.contains("TimelineView(.everyMinute)"))
        let state = DoctorCheckState.completed(Fixture.result([]))
        if case .completed(let result) = state { XCTAssertNil(result.summary) } else { XCTFail("completed keeps its one payload") }
    }

    func testDoctorToneByState() {
        XCTAssertEqual(HealthDoctor.tone(.notRun), .pending)
        XCTAssertEqual(HealthDoctor.tone(.running), .pending)
        XCTAssertEqual(HealthDoctor.tone(.failed("x")), .negative)
        XCTAssertEqual(HealthDoctor.tone(.completed(Fixture.result([]))), .positive)
        XCTAssertEqual(HealthDoctor.tone(.completed(Fixture.result([Fixture.finding("drift_missing_file")]))), .caution)
    }
}

// MARK: - AC3 Reclaim sibling

@MainActor
final class HealthReclaimSiblingTests: XCTestCase {
    func testDriftFindingsNeverReachReclaimsCacheList() async {
        let coordinator = ReclaimCoordinator(now: { Date(timeIntervalSince1970: 1_790_000_000) })
        coordinator.doctorScan = {
            Fixture.result([
                Fixture.finding("drift_missing_file", path: "/wired/a", size: 9_000),
                Fixture.finding("hf_cache_incomplete", path: "org/repo", model: "org/repo", size: 2_000),
                Fixture.finding("drift_hash_mismatch", path: "/wired/b", size: 7_000),
            ])
        }

        await coordinator.checkCache()

        XCTAssertEqual(coordinator.cacheFindings.map(\.path), ["org/repo"])
        XCTAssertEqual(coordinator.cacheReclaimableBytes, 2_000)
    }

    func testDriftFindingsNeverReachReclaimAfterConfirm() async {
        let coordinator = ReclaimCoordinator(now: { Date(timeIntervalSince1970: 1_790_000_000) })
        coordinator.doctorPrunePreview = {
            DoctorResult(findings: nil, prune_count: 1, preview_hash: "h", reclaimedBytes: 10, removed: nil)
        }
        coordinator.doctorPruneConfirm = { _ in
            Fixture.result([Fixture.finding("drift_missing_file", path: "/wired/a", size: 9_000)])
        }
        await coordinator.previewCachePrune()
        let confirmed = await coordinator.confirmCachePrune()
        XCTAssertTrue(confirmed)
        XCTAssertTrue(coordinator.cacheFindings.isEmpty)
        XCTAssertEqual(coordinator.cacheReclaimableBytes, 0)
    }
}

// MARK: - AC6 spawn safety

@MainActor
final class HealthSpawnSafetyTests: XCTestCase {
    func testColdFingerprintPassesThroughAndHealthCopyIsPending() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-health-\(UUID().uuidString)", isDirectory: true)
        let cold = EnvironmentFingerprint(macOSVersion: "15.6", chip: "Apple M4 Max", mlxLMVersion: nil)
        let coordinator = WatchCoordinator(
            watchDiff: { [] },
            watchSnapshot: {},
            fingerprint: { cold },
            verifiedReports: { [] },
            alertStore: JSONStore<WatchAlert>(fileURL: directory.appendingPathComponent("alerts.json")),
            stateStore: JSONStore<WatchState>(fileURL: directory.appendingPathComponent("state.json"))
        )

        let fingerprint = coordinator.currentFingerprint

        XCTAssertEqual(fingerprint, cold)
        XCTAssertNil(fingerprint.mlxLMVersion)
        XCTAssertTrue(HealthPresentation.environmentLine(fingerprint).hasSuffix("mlx-lm unknown"))
        XCTAssertEqual(EnvironmentEvidence.make(reports: [], fingerprint: fingerprint).status, .pending)
        XCTAssertEqual(EnvironmentEvidence.pendingText, "Environment check pending")
    }

    func testHealthSourcesNeverResolveOrProbe() throws {
        let files = ["UI/Views/DoctorView.swift", "UI/Views/HealthPresentation.swift", "UI/Views/HealthViews.swift"]
        let forbidden = ["RuntimeChecker", "WorkbenchPython", "probeMLXLVersion", "FileManager"]
        for file in files {
            let text = try Fixture.source(file)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file) references \(token)")
            }
            XCTAssertNil(text.range(of: #"\bProcess\b"#, options: .regularExpression), "\(file) references Process")
        }
    }

    func testDoctorStaysClickOnly() throws {
        let doctor = try Fixture.source("UI/Views/DoctorView.swift")
        XCTAssertFalse(doctor.contains(".onAppear"))
        XCTAssertFalse(doctor.contains(".task"))
        XCTAssertEqual(doctor.components(separatedBy: "appHost.api.doctor(").count - 1, 1)
        XCTAssertFalse(doctor.contains(".animation("))
    }

    func testRuntimeReportIsProducedOnlyByAppHost() throws {
        let host = try Fixture.source("AppHost.swift")
        XCTAssertEqual(host.components(separatedBy: "RuntimeChecker.report()").count - 1, 4)
        // The initializer probes once; a property default would probe again on every construction.
        XCTAssertTrue(host.contains("@Published var runtimeReport: RuntimeReport\n"))
        var others: [String] = []
        let enumerator = FileManager.default.enumerator(at: Fixture.sourceDirectory, includingPropertiesForKeys: nil)
        for case let url as URL in enumerator?.allObjects ?? [] where url.pathExtension == "swift" {
            guard url.lastPathComponent != "AppHost.swift", url.lastPathComponent != "RuntimeChecker.swift" else { continue }
            if try String(contentsOf: url, encoding: .utf8).contains("RuntimeChecker.report()") { others.append(url.lastPathComponent) }
        }
        XCTAssertEqual(others, [])
    }
}

// MARK: - AC7 layout

final class HealthLayoutTests: XCTestCase {
    /// A viewport that offers exactly this page content width.
    private func layout(content: CGFloat, previous: HealthLayout? = nil) -> HealthLayout {
        HealthLayout(viewportWidth: content + WorkbenchSpacing.pageInset * 2, previous: previous)
    }

    func testForkStacksBelowTheTwoLinkMinimum() {
        XCTAssertEqual(layout(content: 459).forkMode, .stacked)
        XCTAssertEqual(layout(content: 460).forkMode, .twoRow)
        let stacked = layout(content: 459)
        XCTAssertEqual(layout(content: 475, previous: stacked).forkMode, .stacked)
        XCTAssertEqual(layout(content: 476, previous: stacked).forkMode, .twoRow)
    }

    func testForkGoesOneRowAtTheFullForkWidth() {
        XCTAssertEqual(layout(content: 527).forkMode, .twoRow)
        XCTAssertEqual(layout(content: 528).forkMode, .oneRow)
        let twoRow = layout(content: 527)
        XCTAssertEqual(layout(content: 543, previous: twoRow).forkMode, .twoRow)
        XCTAssertEqual(layout(content: 544, previous: twoRow).forkMode, .oneRow)
        XCTAssertEqual(WorkbenchSize.Health.forkRowThreshold, 528)
        XCTAssertEqual(WorkbenchSize.Health.forkStackThreshold, 460)
    }

    func testHeaderWrapsBelowItsThreshold() {
        XCTAssertTrue(layout(content: 439).wrapsHeader)
        XCTAssertFalse(layout(content: 440).wrapsHeader)
        let wrapped = layout(content: 439)
        XCTAssertTrue(layout(content: 455, previous: wrapped).wrapsHeader)
        XCTAssertFalse(layout(content: 456, previous: wrapped).wrapsHeader)
    }

    func testFindingsGoCompactBelowTheirThreshold() {
        XCTAssertTrue(layout(content: 439).compactFindings)
        XCTAssertFalse(layout(content: 440).compactFindings)
        let compact = layout(content: 439)
        XCTAssertTrue(layout(content: 455, previous: compact).compactFindings)
        XCTAssertFalse(layout(content: 456, previous: compact).compactFindings)
    }

    func testSupportedViewports() {
        // A 740-pt window offers a 514-pt viewport: content 466, inside the surface 426.
        let minimum = HealthLayout(viewportWidth: 514)
        XCTAssertEqual(minimum.contentWidth, 466)
        XCTAssertEqual(minimum.innerWidth, 426)
        XCTAssertEqual(minimum.forkMode, .twoRow)
        XCTAssertFalse(minimum.wrapsHeader)
        XCTAssertFalse(minimum.compactFindings)
        XCTAssertEqual(HealthLayout(viewportWidth: 824).forkMode, .oneRow)
        XCTAssertEqual(HealthLayout(viewportWidth: 1220).forkMode, .oneRow)
        XCTAssertEqual(HealthLayout(viewportWidth: 4000).contentWidth, WorkbenchSize.Health.contentMaxWidth)
        for width in [CGFloat(0), CGFloat(100)] {
            let narrow = HealthLayout(viewportWidth: width)
            XCTAssertEqual(narrow.forkMode, .stacked)
            XCTAssertGreaterThanOrEqual(narrow.innerWidth, 0)
            XCTAssertGreaterThanOrEqual(narrow.contentWidth, 0)
        }
    }

    func testContentIsCappedAtTheRunWidth() {
        XCTAssertEqual(WorkbenchSize.Health.contentMaxWidth, WorkbenchSize.Run.contentMaxWidth)
        XCTAssertEqual(WorkbenchSize.Health.hysteresis, WorkbenchSize.Library.tierHysteresis)
    }
}

// MARK: - Environment evidence

final class EnvironmentEvidenceTests: XCTestCase {
    private let warm = EnvironmentFingerprint(macOSVersion: "26.6.2", chip: "Apple M5 Max", mlxLMVersion: "0.29.1")

    private func report(
        _ path: String, at seconds: TimeInterval, fingerprint: String?, outcome: VerificationOutcome = .passed
    ) -> VerificationReport {
        VerificationReport(
            id: UUID(), modelPath: path, modelSignature: nil, workflowRecordID: nil, suiteVersion: 1, canaries: [],
            tokensPerSecond: nil, timeToFirstTokenSeconds: nil, metricsEstimated: false,
            startedAt: Date(timeIntervalSince1970: seconds), finishedAt: Date(timeIntervalSince1970: seconds),
            outcome: outcome, environmentFingerprint: fingerprint
        )
    }

    func testCountsCurrentEarlierAndUnrecorded() {
        let reports = [
            report("/a", at: 10, fingerprint: warm.description),
            report("/b", at: 10, fingerprint: "15.0|Apple M4|0.28.0"),
            report("/c", at: 10, fingerprint: nil),
            report("/d", at: 10, fingerprint: warm.description),
        ]
        let evidence = EnvironmentEvidence.make(reports: reports, fingerprint: warm)
        XCTAssertEqual(evidence.status, .counted(current: 2, earlier: 1, unrecorded: 1))
        XCTAssertEqual(evidence.parts, "macOS 26.6.2 · Apple M5 Max · mlx-lm 0.29.1")
        XCTAssertEqual(evidence.currentText, "verified models match this environment")
        XCTAssertEqual(evidence.earlierText, "verified under an earlier macOS or mlx-lm")
        XCTAssertEqual(evidence.unrecordedHelp, "1 verified model has no recorded environment")
    }

    func testLatestPassedReportPerModelWins() {
        let reports = [
            report("/a", at: 10, fingerprint: "old|old|old"),
            report("/a", at: 20, fingerprint: warm.description),
            report("/b", at: 10, fingerprint: warm.description),
            report("/b", at: 20, fingerprint: "old|old|old"),
        ]
        XCTAssertEqual(
            EnvironmentEvidence.make(reports: reports, fingerprint: warm).status,
            .counted(current: 1, earlier: 1, unrecorded: 0)
        )
    }

    func testFailedOutcomesAreExcluded() {
        let reports = [
            report("/a", at: 10, fingerprint: warm.description),
            report("/a", at: 20, fingerprint: "old|old|old", outcome: .failed(canaryIDs: ["x"])),
            report("/b", at: 10, fingerprint: warm.description, outcome: .error(message: "boom")),
            report("/c", at: 10, fingerprint: warm.description, outcome: .keptDespiteFailure),
        ]
        XCTAssertEqual(
            EnvironmentEvidence.make(reports: reports, fingerprint: warm).status,
            .counted(current: 1, earlier: 0, unrecorded: 0)
        )
        XCTAssertNil(EnvironmentEvidence.make(reports: reports, fingerprint: warm).earlierText)
        XCTAssertNil(EnvironmentEvidence.make(reports: reports, fingerprint: warm).unrecordedHelp)
    }

    func testColdFingerprintIsPendingAndNeverClassifies() {
        let cold = EnvironmentFingerprint(macOSVersion: "26.6.2", chip: "Apple M5 Max", mlxLMVersion: nil)
        let reports = [report("/a", at: 10, fingerprint: cold.description)]
        XCTAssertEqual(EnvironmentEvidence.make(reports: reports, fingerprint: cold).status, .pending)
        let unknownMac = EnvironmentFingerprint(macOSVersion: "unknown", chip: "Apple M5 Max", mlxLMVersion: "0.29.1")
        XCTAssertEqual(EnvironmentEvidence.make(reports: reports, fingerprint: unknownMac).status, .pending)
    }

    func testNoVerifiedModelsIsEmpty() {
        XCTAssertEqual(EnvironmentEvidence.make(reports: [], fingerprint: warm).status, .noVerifiedModels)
        let failedOnly = [report("/a", at: 10, fingerprint: warm.description, outcome: .failed(canaryIDs: []))]
        XCTAssertEqual(EnvironmentEvidence.make(reports: failedOnly, fingerprint: warm).status, .noVerifiedModels)
        XCTAssertEqual(EnvironmentEvidence.emptyText, "No verified models yet")
        XCTAssertNil(EnvironmentEvidence.make(reports: [], fingerprint: warm).currentText)
    }

    func testSingularCurrentCopy() {
        let evidence = EnvironmentEvidence.make(reports: [report("/a", at: 1, fingerprint: warm.description)], fingerprint: warm)
        XCTAssertEqual(evidence.currentText, "verified model matches this environment")
    }
}

// MARK: - Connector plan

final class HealthConnectorPlanTests: XCTestCase {
    private func links(_ tones: [HealthTone]) -> [HealthLink] {
        let ids: [HealthLinkID] = [.agent, .python, .prepare, .run]
        return zip(ids, tones).map {
            HealthLink(id: $0, title: "", stateWord: "", tone: $1, detail: nil, detailIsPath: false, parts: [])
        }
    }

    private func icons(rows: [CGFloat], columns: [CGFloat]) -> [HealthLinkID: CGRect] {
        let ids: [HealthLinkID] = [.agent, .python, .prepare, .run]
        var result: [HealthLinkID: CGRect] = [:]
        for (index, id) in ids.enumerated() {
            result[id] = CGRect(x: columns[index] - 12, y: rows[index] - 8, width: 24, height: 16)
        }
        return result
    }

    private let oneRowRects = [CGFloat(10), 110, 20, 120]
    private let oneRowSlot = CGRect(x: 100, y: 0, width: WorkbenchSize.Health.connectorWidth, height: 140)
    private let twoRowSlot = CGRect(x: 0, y: 18, width: 400, height: 174)

    private func oneRow(_ tones: [HealthTone]) -> [HealthConnectorSegment] {
        HealthConnectorPlan.segments(
            mode: .oneRow, links: links(tones), icons: icons(rows: oneRowRects, columns: [12, 12, 300, 300]), slot: oneRowSlot
        )
    }

    private func twoRow(_ tones: [HealthTone]) -> [HealthConnectorSegment] {
        HealthConnectorPlan.segments(
            mode: .twoRow, links: links(tones), icons: icons(rows: [10, 10, 200, 200], columns: [12, 300, 12, 300]), slot: twoRowSlot
        )
    }

    private func stacked(_ tones: [HealthTone]) -> [HealthConnectorSegment] {
        HealthConnectorPlan.segments(
            mode: .stacked, links: links(tones), icons: icons(rows: [10, 100, 200, 300], columns: [12, 12, 46, 46]), slot: nil
        )
    }

    private let ready: [HealthTone] = [.positive, .positive, .positive, .positive]
    private let agentBroken: [HealthTone] = [.negative, .positive, .pending, .pending]
    private let pythonBroken: [HealthTone] = [.positive, .negative, .pending, .pending]

    func testOneRowMergesTrunksAndSplitsAtSeparateColumns() {
        let segments = oneRow(ready)
        let x1 = 100 + oneRowSlot.width / 3
        let x2 = 100 + oneRowSlot.width * 2 / 3
        XCTAssertEqual(segments.count, 7)
        XCTAssertEqual(segments[0], HealthConnectorSegment(from: CGPoint(x: 100, y: 10), to: CGPoint(x: x1, y: 10), isLive: true))
        XCTAssertEqual(segments[1], HealthConnectorSegment(from: CGPoint(x: 100, y: 110), to: CGPoint(x: x1, y: 110), isLive: true))
        XCTAssertEqual(segments[2], HealthConnectorSegment(from: CGPoint(x: x1, y: 10), to: CGPoint(x: x1, y: 110), isLive: true))
        XCTAssertEqual(segments[3], HealthConnectorSegment(from: CGPoint(x: x1, y: 60), to: CGPoint(x: x2, y: 60), isLive: true))
        XCTAssertEqual(segments[4], HealthConnectorSegment(from: CGPoint(x: x2, y: 20), to: CGPoint(x: x2, y: 120), isLive: true))
        XCTAssertEqual(segments[5], HealthConnectorSegment(from: CGPoint(x: x2, y: 20), to: CGPoint(x: 284, y: 20), isLive: true))
        XCTAssertEqual(segments[6], HealthConnectorSegment(from: CGPoint(x: x2, y: 120), to: CGPoint(x: 284, y: 120), isLive: true))
        XCTAssertGreaterThanOrEqual(segments[3].to.x - segments[3].from.x, WorkbenchSize.Health.connectorWidth / 3 - 0.001)
        XCTAssertGreaterThan(x2, x1)
    }

    func testOneRowVerticalAtTheSplitSpansTheTrunkWhenItIsOutsideTheOutputs() {
        let rects = icons(rows: [10, 110, 70, 80], columns: [12, 12, 300, 300])
        let segments = HealthConnectorPlan.segments(mode: .oneRow, links: links(ready), icons: rects, slot: oneRowSlot)
        XCTAssertEqual(segments[4].from.y, 60)
        XCTAssertEqual(segments[4].to.y, 80)
        let high = icons(rows: [10, 110, 130, 140], columns: [12, 12, 300, 300])
        let above = HealthConnectorPlan.segments(mode: .oneRow, links: links(ready), icons: high, slot: oneRowSlot)
        XCTAssertEqual(above[4].from.y, 60)
        XCTAssertEqual(above[4].to.y, 140)
    }

    func testOneRowLiveness() {
        XCTAssertEqual(oneRow(ready).map(\.isLive), [true, true, true, true, true, true, true])
        XCTAssertEqual(oneRow(agentBroken).map(\.isLive), [false, true, false, false, false, false, false])
        XCTAssertEqual(oneRow(pythonBroken).map(\.isLive), [true, false, false, false, false, false, false])
    }

    func testTwoRowSharesOneBusBetweenBothFoundationsAndBothCapabilities() {
        let segments = twoRow(ready)
        let bus = twoRowSlot.midY
        XCTAssertEqual(segments.count, 5)
        XCTAssertEqual(segments[0], HealthConnectorSegment(from: CGPoint(x: 12, y: 18), to: CGPoint(x: 12, y: bus), isLive: true))
        XCTAssertEqual(segments[1], HealthConnectorSegment(from: CGPoint(x: 300, y: 18), to: CGPoint(x: 300, y: bus), isLive: true))
        XCTAssertEqual(segments[2], HealthConnectorSegment(from: CGPoint(x: 12, y: bus), to: CGPoint(x: 300, y: bus), isLive: true))
        XCTAssertEqual(segments[3], HealthConnectorSegment(from: CGPoint(x: 12, y: bus), to: CGPoint(x: 12, y: 192), isLive: true))
        XCTAssertEqual(segments[4], HealthConnectorSegment(from: CGPoint(x: 300, y: bus), to: CGPoint(x: 300, y: 192), isLive: true))
        for segment in segments {
            let joinsFoundationToCapability = segment.from.y <= 18 && segment.to.y >= 192
            XCTAssertFalse(joinsFoundationToCapability)
        }
    }

    func testTwoRowLiveness() {
        XCTAssertEqual(twoRow(ready).map(\.isLive), [true, true, true, true, true])
        XCTAssertEqual(twoRow(agentBroken).map(\.isLive), [false, true, false, false, false])
        XCTAssertEqual(twoRow(pythonBroken).map(\.isLive), [true, false, false, false, false])
    }

    func testStackedIsATreeUnderPythonWithNoPrepareToRunSegment() {
        let segments = stacked(ready)
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0], HealthConnectorSegment(from: CGPoint(x: 12, y: 18), to: CGPoint(x: 12, y: 92), isLive: true))
        XCTAssertEqual(segments[1], HealthConnectorSegment(from: CGPoint(x: 12, y: 108), to: CGPoint(x: 12, y: 300), isLive: true))
        XCTAssertEqual(segments[2], HealthConnectorSegment(from: CGPoint(x: 12, y: 200), to: CGPoint(x: 34, y: 200), isLive: true))
        XCTAssertEqual(segments[3], HealthConnectorSegment(from: CGPoint(x: 12, y: 300), to: CGPoint(x: 34, y: 300), isLive: true))
        XCTAssertFalse(segments.contains { $0.from.x == 46 || $0.to.x == 46 }, "nothing leaves the Prepare or Run icon column")
    }

    func testStackedLiveness() {
        XCTAssertEqual(stacked(ready).map(\.isLive), [true, true, true, true])
        XCTAssertEqual(stacked(agentBroken).map(\.isLive), [false, false, false, false])
        XCTAssertEqual(stacked(pythonBroken).map(\.isLive), [true, false, false, false])
    }

    func testMissingIconsYieldNoSegments() {
        let all = links([.positive, .positive, .positive, .positive])
        XCTAssertTrue(HealthConnectorPlan.segments(mode: .stacked, links: all, icons: [:], slot: nil).isEmpty)
        XCTAssertTrue(HealthConnectorPlan.segments(mode: .oneRow, links: all, icons: icons(rows: [0, 0, 0, 0], columns: [0, 0, 0, 0]), slot: nil).isEmpty)
    }
}

// MARK: - Source contracts

final class HealthSourceContractTests: XCTestCase {
    func testRuntimeReportRunsEveryProbeUnderOneResolvedInterpreter() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/mlx-health-python")
        let report = RuntimeChecker.report(python: missing)
        XCTAssertEqual(report.python, missing.path)
        XCTAssertTrue(report.convert.modules.values.allSatisfy { !$0 })
        XCTAssertFalse(report.convert.ok)
        let checker = try Fixture.source("Services/RuntimeChecker.swift")
        XCTAssertEqual(checker.components(separatedBy: "pythonPath()").count - 1, 2, "one call in report(), one definition")
    }

    func testDoctorRunningStateHasOneIndicatorAndKeepsItsLabel() throws {
        let doctor = try Fixture.source("UI/Views/DoctorView.swift")
        XCTAssertFalse(doctor.contains("ProgressView"))
        XCTAssertTrue(doctor.contains(#".accessibilityLabel("Checking inventory")"#))
        XCTAssertEqual(doctor.components(separatedBy: ".livePulse(").count - 1, 1)
        let views = try Fixture.source("UI/Views/HealthViews.swift")
        XCTAssertFalse(views.contains("connectorStroke"))
        XCTAssertEqual(views.components(separatedBy: ".numericText()").count - 1, 1, "only the evidence numerals")
    }

    func testHeroHasOneProminentControlAndTheNewButtonsAreBorderless() throws {
        let views = try Fixture.source("UI/Views/HealthViews.swift")
        XCTAssertEqual(views.components(separatedBy: ".borderedProminent").count - 1, 1, "healthProminence only")
        XCTAssertNotNil(views.range(of: #"Button\(EnvironmentEvidence\.reviewTitle, action: onReview\)\s+\.buttonStyle\(\.borderless\)"#, options: .regularExpression))
        XCTAssertTrue(views.contains(#"Button("Copy command")"#))
        let doctor = try Fixture.source("UI/Views/DoctorView.swift")
        XCTAssertEqual(doctor.components(separatedBy: ".borderedProminent").count - 1, 1, "Run doctor")
        XCTAssertTrue(doctor.contains("onRouteSelection(.overview)"))
    }

    func testForkSemanticsAreContainedForVoiceOver() throws {
        let views = try Fixture.source("UI/Views/HealthViews.swift")
        XCTAssertGreaterThanOrEqual(views.components(separatedBy: ".accessibilityElement(children: .contain)").count - 1, 3)
        XCTAssertTrue(views.contains("WorkbenchTypography.display"))
    }

    func testHealthSourcesNeverCallProbeLifecycle() throws {
        let tests = try Fixture.source("../mlx-macTests/HealthRemodelTests.swift")
        let lifecycle = ["invalidate", "prewarm"].map { $0 + "EnvironmentProbe" }
        for call in lifecycle { XCTAssertFalse(tests.contains(call + "()"), "\(call) is not called in tests") }
    }
}
