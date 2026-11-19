import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class FrontDoorTests: XCTestCase {
    private let token = "mlxw_" + String(repeating: "f", count: 64)
    private var digest: String { EndpointCredentialStore.digest(token) }

    func testRunBindsPortAndKeyDigestAndStopsWithTheApp() async throws {
        let calls = FrontDoorCalls()
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, timeout in
            calls.record(argv.joined(separator: " ") + " timeout=\(timeout.map { String($0) } ?? "none")")
            return ["state": "listening"]
        })
        try await api.frontDoorRun(port: 8939, keySHA256: digest)
        XCTAssertEqual(calls.values, ["serve front-door --port 8939 --api-key-sha256 \(digest) --json --watch-parent timeout=inf"])
    }

    func testStartPublishesRoutedModelsAndStopEndsTheChild() async throws {
        let calls = FrontDoorCalls()
        let coordinator = FrontDoorCoordinator(api: Self.unusedAPI(), token: { [token] hash in
            calls.record("token \(hash)"); return token
        }, run: { port, key in
            calls.record("run \(port) \(key)")
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) } catch { calls.record("ended"); throw error }
        }, models: { port, presented in
            calls.record("models \(port) \(presented)")
            guard calls.count("models") > 1 else { throw HostHTTPError.requestFailed }
            return ["gemma-3", "org/coder"]
        }, portInUse: { _ in false })

        await coordinator.start(FrontDoorSettings(port: 8939, apiKeySHA256: digest))
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(coordinator.listening?.models, ["gemma-3", "org/coder"])
        XCTAssertEqual(coordinator.endpoint, WireEndpoint(baseURL: "http://127.0.0.1:8939/v1", modelName: "gemma-3",
                                                          apiKeySHA256: digest, models: ["gemma-3", "org/coder"]))
        XCTAssertEqual(calls.values.first, "token \(digest)")
        XCTAssertEqual(calls.values.filter { $0.hasPrefix("run") }, ["run 8939 \(digest)"])
        XCTAssertEqual(Set(calls.values.filter { $0.hasPrefix("models") }), ["models 8939 \(token)"])

        await coordinator.stop()
        XCTAssertNil(coordinator.listening)
        XCTAssertNil(coordinator.endpoint)
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(calls.values.last, "ended")
    }

    func testStartRefusesAPortInUseAndReportsAChildThatExits() async {
        let calls = FrontDoorCalls()
        func make(portInUse: Bool) -> FrontDoorCoordinator {
            FrontDoorCoordinator(api: Self.unusedAPI(), token: { [token] _ in token }, run: { port, _ in
                calls.record("run \(port)")
                throw BridgeError.remote(code: "front_door_port_unavailable", message: "Port \(port) is unavailable on 127.0.0.1.",
                                         remediation: "Choose another port or stop the process using it.")
            }, models: { _, _ in throw HostHTTPError.requestFailed }, portInUse: { _ in portInUse })
        }
        let busy = make(portInUse: true)
        await busy.start(FrontDoorSettings(port: 8939, apiKeySHA256: digest))
        XCTAssertTrue(busy.error?.contains("8939") == true, busy.error ?? "")
        XCTAssertTrue(calls.values.isEmpty)

        let coordinator = make(portInUse: false)
        await coordinator.start(FrontDoorSettings(port: 8939, apiKeySHA256: digest))
        XCTAssertEqual(calls.values, ["run 8939"])
        XCTAssertNil(coordinator.listening)
        XCTAssertTrue(coordinator.error?.contains("Choose another port") == true, coordinator.error ?? "")
        XCTAssertFalse(coordinator.busy)
    }

    private static func unusedAPI() -> WorkbenchAPI {
        WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, _ in
            XCTFail("Unexpected engine call: \(argv)"); return [:]
        })
    }
}

private final class FrontDoorCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func record(_ value: String) { lock.withLock { recorded.append(value) } }
    func count(_ prefix: String) -> Int { lock.withLock { recorded.filter { $0.hasPrefix(prefix) }.count } }
}
