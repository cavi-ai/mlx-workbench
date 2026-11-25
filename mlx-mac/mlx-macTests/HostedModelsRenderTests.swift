import XCTest
@testable import mlx_workbench

@MainActor
final class HostedModelsRenderTests: XCTestCase {
    func testHostNavigationConsumesExactConnectionAndRejectsChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosts = ModelHostsCoordinator(store: JSONStore(fileURL: root.appendingPathComponent("hosts.json")),
            readToken: { _ in nil }, writeToken: { _, _ in })
        let first = ModelHost(name: "Same name", provider: .ollama, baseURL: "http://127.0.0.1:11434")
        var second = ModelHost(name: "Same name", provider: .ollama, baseURL: "http://127.0.0.1:11435")
        try hosts.save(first, token: nil, replaceToken: false)
        try hosts.save(second, token: nil, replaceToken: false)
        let host = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", configPath: root.appendingPathComponent("config.json").path,
            agentHealth: .notConfigured, runtimeReport: report(), modelHosts: hosts)
        host.handoffs.send(HostedModelsRequest(host: second), as: .openHostedModels)
        XCTAssertEqual(try host.takeHostedModelsHost(), second)
        XCTAssertNil(try host.takeHostedModelsHost())
        host.handoffs.send(HostedModelsRequest(host: second), as: .openHostedModels)
        second.baseURL = "http://127.0.0.1:11436"
        try hosts.save(second, token: nil, replaceToken: false)
        XCTAssertThrowsError(try host.takeHostedModelsHost())
        XCTAssertNil(host.handoffs[.openHostedModels])
        host.handoffs.send(HostedModelsRequest(host: first), as: .openHostedModels)
        try hosts.remove(first.id)
        XCTAssertThrowsError(try host.takeHostedModelsHost())
        XCTAssertNil(host.handoffs[.openHostedModels])
    }

    private func report() -> RuntimeReport {
        RuntimeReport(convert: ConvertStatus(ok: true, modules: [:], executables: [:], missingModules: [], missingExecutables: [], install: "make install", message: "Ready"),
            serve: ServeStatus(ok: true, executables: [:], missingExecutables: [], install: "make install", message: "Ready"), install: "make install", ok: true)
    }
}
