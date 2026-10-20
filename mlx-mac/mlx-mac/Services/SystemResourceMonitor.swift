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
    @Published private(set) var processMemory: ProcessMemorySnapshot?
    @Published private(set) var processCapturedAt: Date?
    @Published private(set) var processError: String?
    @Published private(set) var refreshingProcesses = false
    @Published var contextTokens = FitAdvisor.defaultContextTokens
    /// The context sizes every fit control offers.
    nonisolated static let contextOptions = [2048, 4096, 8192, 16384, 32768, 65536]
    /// True once the first memory probe has finished, whether or not it succeeded.
    @Published private(set) var hasProbed = false

    private let probe: @Sendable () -> MemorySnapshot?
    private let processProbe: @Sendable () throws -> ProcessMemorySnapshot
    private let now: () -> Date
    private let statusProvider: @Sendable () async throws -> [ServerInfo]
    private var monitoring: Task<Void, Never>?
    private var refreshingMemory = false

    init(probe: @escaping @Sendable () -> MemorySnapshot? = MemorySnapshot.probe,
         now: @escaping () -> Date = Date.init,
         statusProvider: @escaping @Sendable () async throws -> [ServerInfo] = { [] },
         processProbe: @escaping @Sendable () throws -> ProcessMemorySnapshot = { try ProcessMemorySnapshot.probe() }) {
        self.probe = probe
        self.now = now
        self.statusProvider = statusProvider
        self.processProbe = processProbe
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
        hasProbed = true
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

    /// Only an explicit inspector open or refresh reads processes; no polling.
    func refreshProcesses() async {
        guard !refreshingProcesses else { return }
        refreshingProcesses = true
        defer { refreshingProcesses = false }
        let probe = processProbe
        do {
            let reading = try await Task.detached(priority: .utility) { try probe() }.value
            processMemory = reading
            processCapturedAt = now()
            processError = nil
        } catch {
            processError = processMemory == nil
                ? "Process memory could not be read. Try refreshing or open Activity Monitor."
                : "Refresh failed. The last reading is shown below."
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
