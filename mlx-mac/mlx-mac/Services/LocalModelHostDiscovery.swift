import CryptoKit
import Darwin
import Foundation

struct LocalModelHost: Equatable, Sendable {
    let host: ModelHost
    let processID: Int
}

/// Read-only listener identification. Model identity and residency still come from the provider.
enum LocalModelHostDiscovery {
    static func discover() async throws -> [LocalModelHost] {
        async let listeners = BoundedProcessCapture.runAsync(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "-Fpcnt"], timeout: 3)
        async let processes = BoundedProcessCapture.runAsync(executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ww", "-axo", "pid=,command="], timeout: 3)
        let (ports, commands) = try await (listeners, processes)
        guard commands.status == 0, ports.status == 0 || (ports.status == 1 && ports.stdout.isEmpty) else {
            throw WorkflowEvidenceError.invalid("Local server listeners could not be read. Refresh to try again.")
        }
        return candidates(listeners: ports.stdout, processes: commands.stdout)
    }

    static func candidates(listeners: String, processes: String) -> [LocalModelHost] {
        var commands: [Int: String] = [:]
        for line in processes.split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if fields.count == 2, let pid = Int(fields[0]) { commands[pid] = String(fields[1]) }
        }
        var pid: Int?
        var family: String?
        var seen = Set<String>()
        var result: [LocalModelHost] = []
        for line in listeners.split(separator: "\n") {
            if line.first == "p" { pid = Int(line.dropFirst()); family = nil; continue }
            if line.first == "t" { family = String(line.dropFirst()); continue }
            guard line.first == "n", let pid, let command = commands[pid]?.lowercased(),
                  let portText = line.split(separator: ":").last, let port = Int(portText), (1...65535).contains(port),
                  let provider = provider(command) else { continue }
            let address = String(line.dropFirst()).dropLast(portText.count + 1)
            guard ["127.0.0.1", "[::1]", "::1", "*", "0.0.0.0"].contains(String(address)) else { continue }
            let ipv6 = address == "[::1]" || address == "::1" || address == "*" && family == "IPv6"
            let base = "http://\(ipv6 ? "[::1]" : "127.0.0.1"):\(port)"
            guard seen.insert(base).inserted else { continue }
            let digest = SHA256.hash(data: Data((provider.rawValue + base).utf8)).map { String(format: "%02x", $0) }.joined()
            let uuid = String(digest.prefix(8)) + "-" + String(digest.dropFirst(8).prefix(4)) + "-" +
                String(digest.dropFirst(12).prefix(4)) + "-" + String(digest.dropFirst(16).prefix(4)) + "-" + String(digest.dropFirst(20).prefix(12))
            guard let id = UUID(uuidString: uuid) else { continue }
            let name: String
            switch provider {
            case .ollama: name = "Ollama"
            case .lmStudio: name = "LM Studio"
            case .comfyUI: name = "ComfyUI"
            case .llamaCpp: name = "llama.cpp"
            default: name = command.contains("strata") ? "Strata" : "Local model server"
            }
            result.append(LocalModelHost(host: ModelHost(id: id, name: name + " · :\(port)", provider: provider, baseURL: base), processID: pid))
            if result.count == 16 { break }
        }
        return result
    }

    private static func provider(_ command: String) -> ModelHostProvider? {
        if command.contains("/ollama") { return .ollama }
        if command.contains("/lm studio.app/") || command.contains("/.lmstudio/") { return .lmStudio }
        if command.contains("comfyui") { return .comfyUI }
        if command.contains("llama-server") || command.contains("llama_cpp.server") { return .llamaCpp }
        if ["mlx_lm.server", "mlx_vlm.server", "/mlx_agent/jit_serve.py", "strata_runtime.py", "vllm", "litellm"].contains(where: command.contains) {
            return .openAICompatible
        }
        return nil
    }
}
