import Foundation

// MARK: - Stream Event (Top-Level)

public enum StreamEvent: Sendable {
    case system(SystemEvent)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case result(ResultEvent)
    case rateLimitEvent(RateLimitInfo)
    case unknown(String)
}

// MARK: - System Event

public struct SystemEvent: Sendable {
    public let subtype: String
    public let sessionId: String?
    public let tools: [String]?
    public let model: String?
    public let claudeCodeVersion: String?
    /// MCP servers reported by the `init` event (`mcp_servers`). `nil` when absent or malformed.
    public let mcpServers: [McpServerStatus]?
    /// MCP server entries rejected by validation (`mcp_server_errors`). `nil` when absent or malformed.
    public let mcpServerErrors: [McpServerError]?

    public init(subtype: String, sessionId: String?, tools: [String]?, model: String?, claudeCodeVersion: String?,
                mcpServers: [McpServerStatus]? = nil, mcpServerErrors: [McpServerError]? = nil) {
        self.subtype = subtype
        self.sessionId = sessionId
        self.tools = tools
        self.model = model
        self.claudeCodeVersion = claudeCodeVersion
        self.mcpServers = mcpServers
        self.mcpServerErrors = mcpServerErrors
    }

    /// Connectors in the order the CLI reported them, followed by rejected entries as failed.
    /// `nil` when the event carries no connector information at all.
    public var connectors: [SessionConnector]? {
        guard mcpServers != nil || mcpServerErrors != nil else { return nil }
        let servers = (mcpServers ?? []).map {
            SessionConnector(name: $0.name, state: SessionConnector.State(status: $0.status))
        }
        let errors = (mcpServerErrors ?? []).map {
            SessionConnector(name: $0.name, state: .failed, message: $0.message)
        }
        return servers + errors
    }
}

// MARK: - MCP Server Status

public struct McpServerStatus: Sendable, Equatable {
    public let name: String
    public let status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

public struct McpServerError: Sendable, Equatable {
    public let name: String
    public let type: String?
    public let message: String?

    public init(name: String, type: String?, message: String?) {
        self.name = name
        self.type = type
        self.message = message
    }
}

// MARK: - Session Connector

/// An MCP server (connector) of a session as last reported by the CLI.
public struct SessionConnector: Sendable, Equatable, Hashable {
    public enum State: Sendable, Equatable, Hashable {
        case connected
        case failed
        case needsAuth
        /// Still connecting when the reply started. The CLI sends no later update.
        case pending
        case unknown(String)

        public init(status: String) {
            switch status {
            case "connected": self = .connected
            case "failed": self = .failed
            case "needs-auth": self = .needsAuth
            case "pending": self = .pending
            default: self = .unknown(status)
            }
        }
    }

    public let name: String
    public let state: State
    /// Error text for entries from `mcp_server_errors`.
    public let message: String?

    public init(name: String, state: State, message: String? = nil) {
        self.name = name
        self.state = state
        self.message = message
    }
}

// MARK: - Assistant Message

public struct AssistantMessage: Sendable {
    public let role: String
    public let content: [ContentBlock]

    public init(role: String, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }
}

// MARK: - Content Block

public enum ContentBlock: Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    case thinking(String)
}

// MARK: - User Message (Tool Result)

public struct UserMessage: Sendable {
    public let toolUseId: String?
    public let content: String
    public let isError: Bool

    public init(toolUseId: String?, content: String, isError: Bool) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}

// MARK: - Usage Info

public struct UsageInfo: Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheCreationInputTokens: Int, cacheReadInputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

// MARK: - Context Window Info

public struct ContextWindowInfo: Sendable {
    public let usedPercentage: Double
    public let remainingPercentage: Double

    public init(usedPercentage: Double, remainingPercentage: Double) {
        self.usedPercentage = usedPercentage
        self.remainingPercentage = remainingPercentage
    }
}

// MARK: - Result Event

public struct ResultEvent: Sendable {
    public let durationMs: Double?
    public let totalCostUsd: Double?
    public let sessionId: String
    public let isError: Bool
    public let totalTurns: Int?
    public let usage: UsageInfo?
    public let contextWindow: ContextWindowInfo?

    public init(durationMs: Double?, totalCostUsd: Double?, sessionId: String, isError: Bool,
                totalTurns: Int?, usage: UsageInfo?, contextWindow: ContextWindowInfo?) {
        self.durationMs = durationMs
        self.totalCostUsd = totalCostUsd
        self.sessionId = sessionId
        self.isError = isError
        self.totalTurns = totalTurns
        self.usage = usage
        self.contextWindow = contextWindow
    }
}

// MARK: - Rate Limit Info

public struct RateLimitInfo: Sendable {
    public let status: String
    public let retrySec: Double?

    public init(status: String, retrySec: Double?) {
        self.status = status
        self.retrySec = retrySec
    }
}
