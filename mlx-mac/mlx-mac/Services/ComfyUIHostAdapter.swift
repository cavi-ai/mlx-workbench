import CoreFoundation
import Foundation

/// ComfyUI: model files by category, device memory, queue activity and host-wide cached-model cleanup.
struct ComfyUIHostAdapter: ModelHostAdapter {
    let title = "ComfyUI"
    let defaultURL = "http://127.0.0.1:8188"
    var releaseScope: HostReleaseScope? { .host }
    var reportsDeviceMemory: Bool { true }
    var runsImageWorkflows: Bool { true }
    private static let maximumCategories = 32

    func inventory(from reader: HostReader) async throws -> HostInventory {
        let host = reader.host
        guard let categories = try HostReader.json(try await reader.data("models")) as? [String], categories.count <= Self.maximumCategories,
              Set(categories).count == categories.count else { throw HostHTTPError.invalidResponse }
        var models: [HostedModel] = []
        var warnings: [String] = []
        for category in categories {
            guard !category.isEmpty, category.utf8.count <= 128,
                  category.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
                throw HostHTTPError.invalidResponse
            }
            do {
                guard let files = try HostReader.json(try await reader.data("models/" + category)) as? [String], files.count <= HostReader.maximumModels,
                      Set(files).count == files.count else { throw HostHTTPError.invalidResponse }
                let entries = try files.map { filename in
                    _ = try HostReader.identifier(filename)
                    return HostedModel(hostID: host.id, modelID: category + "/" + filename, name: filename, category: category)
                }
                guard models.count + entries.count <= HostReader.maximumModels else { throw HostHTTPError.responseTooLarge }
                models.append(contentsOf: entries)
            } catch is CancellationError { throw CancellationError() }
            catch HostHTTPError.responseTooLarge { throw HostHTTPError.responseTooLarge }
            catch { warnings.append("A ComfyUI model category could not be listed; this inventory is partial.") }
        }
        try HostReader.validateIDs(models)
        var version: String?
        var devices: String?
        var deviceMemory: HostDeviceMemorySnapshot?
        do {
            let stats = try await reader.object("system_stats")
            version = HostReader.text((stats["system"] as? [String: Any])?["comfyui_version"])
            deviceMemory = try Self.deviceMemory(stats["devices"])
            if let reported = stats["devices"] as? [[String: Any]], reported.count <= 32 {
                let names = reported.compactMap { device -> String? in
                    guard let name = HostReader.text(device["name"]) else { return nil }
                    return HostReader.text(device["type"]).map { name + " (" + $0 + ")" } ?? name
                }
                if !names.isEmpty { devices = names.joined(separator: ", ") }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("ComfyUI runtime and device metadata is unavailable.") }
        return HostInventory(host: host, models: models, capturedAt: Date(), runtimeVersion: version, deviceSummary: devices,
            warnings: warnings, deviceMemory: deviceMemory)
    }

    func activity(from reader: HostReader) async throws -> HostActivity {
        do {
            let queue = try await reader.object("queue")
            let running = try Self.queuePromptIDs(queue["queue_running"])
            let pending = try Self.queuePromptIDs(queue["queue_pending"])
            guard running.count + pending.count <= HostReader.maximumModels,
                  Set(running + pending).count == running.count + pending.count else { throw HostHTTPError.invalidResponse }
            let state: HostActivityState = !running.isEmpty ? .busy : (!pending.isEmpty ? .queued : .idle)
            let detail: String
            switch state {
            case .idle: detail = "ComfyUI reports no running or queued workflows."
            case .busy: detail = "ComfyUI reports \(running.count) running and \(pending.count) queued workflows."
            case .queued: detail = "ComfyUI reports \(pending.count) queued workflows."
            case .unknown: detail = "ComfyUI activity is unknown."
            }
            return HostActivity(state: state, runningCount: running.count, pendingCount: pending.count, detail: detail)
        } catch is CancellationError { throw CancellationError() }
        catch {
            return HostActivity(state: .unknown, detail: "ComfyUI queue activity could not be read. Check the host address, credentials and queue API before releasing memory.")
        }
    }

    func releaseRequest(for preview: HostResourcePreview) throws -> HostReleaseRequest {
        guard preview.model == nil else { throw HostResourceError.invalidSelection }
        return try HostReleaseRequest(path: "free", payload: ["unload_models": true, "free_memory": true])
    }

    func releaseReadback(_ preview: HostResourcePreview, inventory: HostInventory) -> String {
        "ComfyUI does not report completion of memory cleanup; released memory could not be verified."
    }

    private static func deviceMemory(_ value: Any?) throws -> HostDeviceMemorySnapshot? {
        guard let value, !(value is NSNull) else { return nil }
        guard let devices = value as? [[String: Any]], devices.count <= 32 else { throw HostHTTPError.invalidResponse }
        let readings = devices.map { device in
            let reportedTotal = HostReader.integer(device["vram_total"])
            let total = reportedTotal.flatMap { $0 > 0 ? $0 : nil }
            var free = HostReader.integer(device["vram_free"])
            if let reportedTotal, let reportedFree = free, reportedFree > reportedTotal { free = nil }
            return HostDeviceMemory(name: HostReader.text(device["name"]), type: HostReader.text(device["type"]),
                index: HostReader.int(device["index"]), totalBytes: total, freeBytes: free)
        }
        return HostDeviceMemorySnapshot(capturedAt: Date(), devices: readings)
    }

    private static func queuePromptIDs(_ value: Any?) throws -> [String] {
        guard let entries = value as? [[Any]], entries.count <= HostReader.maximumModels else { throw HostHTTPError.invalidResponse }
        return try entries.map { entry in
            // Core queue entries contain position, prompt ID, graph, extra data and output nodes.
            guard (5...8).contains(entry.count), let priority = entry[0] as? NSNumber,
                  CFGetTypeID(priority) != CFBooleanGetTypeID(), priority.doubleValue.isFinite,
                  entry[2] is [String: Any], entry[3] is [String: Any], entry[4] is [String] else {
                throw HostHTTPError.invalidResponse
            }
            return try HostReader.identifier(entry[1])
        }
    }
}
