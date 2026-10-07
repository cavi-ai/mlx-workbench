import Foundation

/// Shared live readings. Mach probes run outside view evaluation; server
/// inventory is fetched only while the resource popover is open.
@MainActor
final class SystemResourceMonitor: ObservableObject {
    @Published private(set) var memory: MemorySnapshot?
    @Published private(set) var capturedAt: Date?
    @Published private(set) var servers: [ServerInfo]?
    @Published private(set) var serverError: String?
    @Published private(set) var refreshingServers = false
    @Published var contextTokens = FitAdvisor.defaultContextTokens

    private let probe: @Sendable () -> MemorySnapshot?
    private let now: () -> Date
    private let statusProvider: @Sendable () async throws -> [ServerInfo]
    private var monitoring: Task<Void, Never>?
    private var refreshingMemory = false

    init(probe: @escaping @Sendable () -> MemorySnapshot? = MemorySnapshot.probe,
         now: @escaping () -> Date = Date.init,
         statusProvider: @escaping @Sendable () async throws -> [ServerInfo] = { [] }) {
        self.probe = probe
        self.now = now
        self.statusProvider = statusProvider
    }

    func refreshMemory() async {
        guard !refreshingMemory else { return }
        refreshingMemory = true
        defer { refreshingMemory = false }
        let probe = self.probe
        let reading = await Task.detached(priority: .utility) { probe() }.value
        if let reading, reading.totalBytes > 0, (0...reading.totalBytes).contains(reading.availableBytes) {
            memory = reading
            capturedAt = now()
        } else {
            memory = nil
            capturedAt = nil
        }
    }

    func refreshServers() async {
        guard !refreshingServers else { return }
        refreshingServers = true
        defer { refreshingServers = false }
        do {
            servers = try await statusProvider().filter { $0.state?.lowercased() == "running" }
            serverError = nil
        } catch {
            servers = nil
            serverError = "Serving status unavailable: \(AppHost.render(error))"
        }
    }

    var isMonitoring: Bool { monitoring != nil }

    func startMonitoring() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMemory()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }

    deinit { monitoring?.cancel() }
}
