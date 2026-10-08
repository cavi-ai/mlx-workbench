import Foundation

@testable import mlx_workbench

/// Shared serve-world fakes for endpoint supervisor tests
/// (EndpointSupervisorTests, EndpointFleetTests).

/// A mutable fake serve world: start adds a running server (unless the run
/// is configured to crash), stop removes it, status reports the truth.
final class FakeServeWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [ServerInfo] = []
    var recorder: LifecycleRecorder?
    /// When false, started servers vanish immediately (crash-loop scenario).
    var survives = true
    var statusError: Error?

    func preload(repo: String, port: Int, jit: Bool = false, modelState: String? = nil, memoryPolicy: EndpointMemoryPolicy? = nil, activeRequests: Int? = nil) {
        lock.lock()
        servers.append(ServerInfo(repo: repo, runtime: "mlx", port: port, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: "r", jit: jit, modelState: modelState, activeRequests: activeRequests, memoryPolicy: memoryPolicy))
        lock.unlock()
    }

    func configureMemory(port: Int, policy: EndpointMemoryPolicy) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = servers.firstIndex(where: { $0.port == port }) else { return }
        let old = servers[index]
        servers[index] = ServerInfo(repo: old.repo, path: old.path, runtime: old.runtime, port: old.port,
            pid: old.pid, state: old.state, logPath: old.logPath, startedAt: old.startedAt, receipt: old.receipt,
            jit: old.jit, modelState: old.modelState, workerPid: old.workerPid, activeRequests: old.activeRequests, memoryPolicy: policy)
    }

    func unloadModel(port: Int) {
        lock.lock()
        defer { lock.unlock() }
        if let index = servers.firstIndex(where: { $0.port == port }) {
            let old = servers[index]
            servers[index] = ServerInfo(repo: old.repo, path: old.path, runtime: old.runtime, port: old.port,
                pid: old.pid, state: old.state, logPath: old.logPath, startedAt: old.startedAt, receipt: old.receipt,
                jit: true, modelState: "unloaded")
        }
    }

    /// Remove a server without a lifecycle event (an out-of-band crash).
    func kill(port: Int) {
        lock.lock()
        servers.removeAll { $0.port == port }
        lock.unlock()
    }

    func status() throws -> [ServerInfo] {
        if let statusError { throw statusError }
        lock.lock()
        defer { lock.unlock() }
        return servers
    }

    var lifecycle: ServeLifecycle {
        ServeLifecycle(
            preview: { modelPath, port in
                self.recorder?.record("preview:\(modelPath):\(port)")
                return "hash-1"
            },
            start: { modelPath, port, hash in
                self.recorder?.record("start:\(modelPath):\(port):\(hash)")
                self.lock.lock()
                if self.survives {
                    self.servers.append(ServerInfo(repo: modelPath, runtime: "mlx", port: port, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: "r"))
                }
                self.lock.unlock()
            },
            stop: { port in
                self.recorder?.record("stop:\(port)")
                self.lock.lock()
                self.servers.removeAll { $0.port == port }
                self.lock.unlock()
            }
        )
    }
}

final class LifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(_ event: String) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }
}
