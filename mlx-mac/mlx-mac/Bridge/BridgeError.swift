import Foundation

// MARK: - BridgeError

enum BridgeError: Error, LocalizedError {
    case agentNotConfigured
    case agentNotFound
    case skillTimeout
    case skillUnavailable
    case skillOutputTooLarge
    case skillOutputUnreadable
    case skillFailed
    case remote(code: String, message: String, remediation: String)

    var code: String {
        switch self {
        case .agentNotConfigured: return "agent_not_configured"
        case .agentNotFound: return "agent_not_found"
        case .skillTimeout: return "skill_timeout"
        case .skillUnavailable: return "skill_unavailable"
        case .skillOutputTooLarge: return "skill_output_too_large"
        case .skillOutputUnreadable: return "skill_output_unreadable"
        case .skillFailed: return "skill_failed"
        case .remote(let code, _, _): return code
        }
    }

    var message: String {
        switch self {
        case .agentNotConfigured: return "No mlx-agent checkout is configured."
        case .agentNotFound: return "No mlx-agent CLI found."
        case .skillTimeout: return "The agent did not finish within the timeout."
        case .skillUnavailable: return "The agent could not be started."
        case .skillOutputTooLarge: return "The agent returned more output than this app will buffer."
        case .skillOutputUnreadable: return "The agent did not return valid JSON."
        case .skillFailed: return "The agent reported an error."
        case .remote(_, let message, _): return message
        }
    }

    var remediation: String {
        switch self {
        case .agentNotConfigured: return "Clone with --recurse-submodules, or set mlx_agent_path / MLX_AGENT_HOME."
        case .agentNotFound: return "Run `git submodule update --init --recursive`, or point mlx_agent_path at an mlx-agent checkout that contains scripts/mlx-agent."
        case .skillTimeout: return "Narrow the request (for example discover --fast), or raise the timeout."
        case .skillUnavailable: return "Check that python3 and the mlx-agent checkout are both readable."
        case .skillOutputTooLarge: return "Narrow roots, lower --limit, or use --fast for discovery."
        case .skillOutputUnreadable: return "Run the same command by hand in the mlx-agent checkout to see the failure."
        case .skillFailed: return "Inspect the agent output and retry."
        case .remote(_, _, let remediation): return remediation
        }
    }

    var errorDescription: String? {
        if remediation.isEmpty {
            return message
        }
        return "\(message)\n\(remediation)"
    }
}