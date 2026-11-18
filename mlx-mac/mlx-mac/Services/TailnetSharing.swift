import Foundation
import SwiftUI

struct TailnetStatus: Decodable, Equatable {
    let state: String
    let apiBase: String?
    let modelID: String?
    let endpointPort: Int?
    let httpsPort: Int?
    let previewHash: String?
    let shareID: String?
    enum CodingKeys: String, CodingKey {
        case state, apiBase = "api_base", modelID = "model_id", endpointPort = "endpoint_port"
        case httpsPort = "https_port", previewHash = "preview_hash", shareID = "share_id"
    }
}

extension WorkbenchAPI {
    func tailnetPreview(port: Int, httpsPort: Int, receipts: String?) async throws -> TailnetStatus {
        try await tailnetStart(port: port, httpsPort: httpsPort, receipts: receipts, hash: nil, shareID: nil)
    }
    func tailnetStart(port: Int, httpsPort: Int, receipts: String?, hash: String?, shareID: String?) async throws -> TailnetStatus {
        var args = ["serve", "tailnet", "start", "--port", String(port), "--https-port", String(httpsPort)]
        if let receipts { args += ["--receipts-dir", receipts] }
        if let hash, let shareID { args += ["--confirm", "--preview-hash", hash, "--share-id", shareID, "--watch-parent"] }
        let data = try await raw(args, timeout: hash == nil ? 15 : .infinity, cancellable: true)
        return try JSONDecoder().decode(TailnetStatus.self, from: JSONSerialization.data(withJSONObject: data))
    }
    func tailnetStop(shareID: String) async throws -> TailnetStatus {
        let data = try await raw(["serve", "tailnet", "stop", "--expected-share-id", shareID], timeout: 15, cancellable: true)
        return try JSONDecoder().decode(TailnetStatus.self, from: JSONSerialization.data(withJSONObject: data))
    }
    func tailnetStatus(timeout: TimeInterval = 10) async throws -> TailnetStatus {
        let data = try await raw(["serve", "tailnet", "status"], timeout: timeout, cancellable: true)
        return try JSONDecoder().decode(TailnetStatus.self, from: JSONSerialization.data(withJSONObject: data))
    }
}

@MainActor
final class TailnetSharingCoordinator: ObservableObject {
    @Published private(set) var status: TailnetStatus?
    @Published private(set) var error: String?
    @Published private(set) var errorCode: String?
    @Published private(set) var busy = false
    private let api: WorkbenchAPI
    private var session: Task<Void, Never>?
    private var ownedPort: Int?
    private var ownedShareID: String?
    private var generation = UUID()
    private var stopping = false
    init(api: WorkbenchAPI) { self.api = api }
    var ownsSession: Bool { session != nil && status?.shareID == ownedShareID && status?.endpointPort == ownedPort }

    /// The HTTPS address of the endpoint on `port` while this app's own session shares it.
    func sharedAddress(port: Int?) -> String? {
        guard let port, ownsSession, let status, status.state == "sharing", status.endpointPort == port else { return nil }
        return status.apiBase
    }

    private func fail(_ error: Error) {
        let bridge = error as? BridgeError
        errorCode = bridge?.code
        if let bridge, ["skill_failed", "skill_output_unreadable"].contains(bridge.code) {
            self.error = "The installed engine could not check Tailscale sharing. Update the engine and check again.\n\(bridge.message)"
        } else {
            self.error = bridge?.errorDescription ?? error.localizedDescription
        }
    }
    func check(server: ServerInfo, httpsPort: Int) async {
        guard !busy, let port = server.port else { return }
        busy = true; error = nil; errorCode = nil; status = nil
        defer { busy = false }
        do {
            let current = try await api.tailnetStatus()
            if current.state == "sharing" {
                status = current
                if current.endpointPort != port || ownedPort != port || session == nil || current.shareID != ownedShareID {
                    error = "A sharing session is already active. Stop it in the process that started it before sharing this endpoint."
                }
                return
            }
            guard current.state == "off" else { throw BridgeError.skillOutputUnreadable }
            guard session == nil else { status = current; return }
            guard server.apiKeySHA256 != nil else {
                status = nil
                error = "This endpoint does not require an API key. Choose an already protected endpoint, or use Endpoint setup to create an eligible protected endpoint. The running endpoint remains unchanged."
                return
            }
            guard (1...65535).contains(httpsPort) else { status = nil; error = "Enter a valid HTTPS port (1–65535)."; return }
            let preview = try await api.tailnetPreview(port: port, httpsPort: httpsPort, receipts: server.receiptsDirectory)
            guard preview.state == "ready", preview.endpointPort == port, preview.httpsPort == httpsPort,
                  preview.previewHash?.isEmpty == false, preview.apiBase?.isEmpty == false, preview.modelID?.isEmpty == false else {
                throw BridgeError.skillOutputUnreadable
            }
            status = preview
        } catch { status = nil; fail(error) }
    }
    func start(server: ServerInfo) async {
        guard !busy, session == nil, let preview = status, preview.state == "ready",
              let port = server.port, preview.endpointPort == port, let httpsPort = preview.httpsPort,
              let hash = preview.previewHash else { return }
        busy = true; error = nil; errorCode = nil
        let id = UUID(); let shareID = UUID().uuidString.lowercased(); generation = id; ownedPort = port; ownedShareID = shareID
        session = Task { [weak self, api] in
            do {
                _ = try await api.tailnetStart(port: port, httpsPort: httpsPort, receipts: server.receiptsDirectory, hash: hash, shareID: shareID)
                guard let self, self.generation == id else { return }
                self.session = nil; self.ownedPort = nil; self.ownedShareID = nil; self.status = nil
                if !self.stopping { self.error = "The sharing process ended. Check again before starting another session." }
            } catch {
                guard let self, self.generation == id else { return }
                self.session = nil; self.ownedPort = nil; self.ownedShareID = nil; self.status = nil
                if !(error is CancellationError) { self.fail(error) }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            if session == nil { break }
            do {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                let current = try await api.tailnetStatus(timeout: min(remaining, 3))
                if current.state == "sharing", current.endpointPort == port, current.httpsPort == httpsPort, current.shareID == shareID {
                    status = current; busy = false; return
                }
                if current.state == "sharing" { error = "Another sharing session is active."; break }
            } catch { fail(error); break }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(min(remaining, 0.5) * 1_000_000_000)) }
        }
        if session != nil {
            let running = session; generation = UUID(); session = nil; ownedPort = nil; ownedShareID = nil
            running?.cancel(); await running?.value
            if error == nil { error = "Sharing did not become active. Check again before retrying." }
        }
        status = nil; busy = false
    }
    func stop() async {
        guard !busy, let running = session, let shareID = ownedShareID else { return }
        busy = true; error = nil; stopping = true
        defer { stopping = false; busy = false }
        do {
            _ = try await api.tailnetStop(shareID: shareID)
            generation = UUID(); error = nil
            running.cancel(); await running.value
            session = nil; ownedPort = nil; ownedShareID = nil
            let current = try await api.tailnetStatus()
            status = current
            if current.state != "off" { error = "A sharing session is active. Check its status before starting again." }
            else { error = nil }
        } catch { fail(error) }
    }
}
