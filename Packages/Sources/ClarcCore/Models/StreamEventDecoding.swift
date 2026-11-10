import Foundation

// MARK: - StreamEvent Decodable

extension StreamEvent: Decodable {
    private enum RootCodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RootCodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "system":
            let event = try SystemEvent(from: decoder)
            self = .system(event)
        case "assistant":
            let message = try AssistantMessage(from: decoder)
            self = .assistant(message)
        case "user":
            let message = try UserMessage(from: decoder)
            self = .user(message)
        case "result":
            let event = try ResultEvent(from: decoder)
            self = .result(event)
        case "rate_limit_event":
            let info = try RateLimitInfo(from: decoder)
            self = .rateLimitEvent(info)
        default:
            let rawData = try JSONEncoder().encode(JSONValue(from: decoder))
            let rawString = String(data: rawData, encoding: .utf8) ?? "{\"type\": \"\(type)\"}"
            self = .unknown(rawString)
        }
    }
}

// MARK: - SystemEvent Decodable

extension SystemEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case subtype
        case sessionId = "session_id"
        case tools
        case model
        case claudeCodeVersion = "claude_code_version"
        case mcpServers = "mcp_servers"
        case mcpServerErrors = "mcp_server_errors"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.subtype = try container.decodeIfPresent(String.self, forKey: .subtype) ?? "unknown"
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.tools = try container.decodeIfPresent([String].self, forKey: .tools)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.claudeCodeVersion = try container.decodeIfPresent(String.self, forKey: .claudeCodeVersion)
        // Connector fields are not documented as stable: a missing or malformed list must not fail the event.
        self.mcpServers = (try? container.decodeIfPresent([McpServerStatus].self, forKey: .mcpServers)) ?? nil
        self.mcpServerErrors = (try? container.decodeIfPresent([McpServerError].self, forKey: .mcpServerErrors)) ?? nil
    }
}

// MARK: - MCP Server Decodable

extension McpServerStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    }
}

extension McpServerError: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name, type, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

// MARK: - AssistantMessage Decodable

extension AssistantMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case message
    }

    private enum MessageCodingKeys: String, CodingKey {
        case role
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let messageContainer = try container.nestedContainer(
            keyedBy: MessageCodingKeys.self,
            forKey: .message
        )
        self.role = try messageContainer.decode(String.self, forKey: .role)
        self.content = try messageContainer.decode([ContentBlock].self, forKey: .content)
    }
}

// MARK: - ContentBlock Decodable

extension ContentBlock: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case thinking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decodeIfPresent([String: JSONValue].self, forKey: .input) ?? [:]
            self = .toolUse(id: id, name: name, input: input)
        case "thinking":
            let thinking = try container.decode(String.self, forKey: .thinking)
            self = .thinking(thinking)
        default:
            let text = try container.decodeIfPresent(String.self, forKey: .text)
                ?? "[Unknown content block: \(type)]"
            self = .text(text)
        }
    }
}

// MARK: - UserMessage Decodable

extension UserMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case message
    }

    private enum MessageCodingKeys: String, CodingKey {
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }

    private struct ContentBlockItem: Decodable {
        let type: String?
        let text: String?
        let content: String?
        let toolUseId: String?
        let isError: Bool?

        private enum CodingKeys: String, CodingKey {
            case type, text, content
            case toolUseId = "tool_use_id"
            case isError = "is_error"
        }

        /// A part of a list-shaped `content` (e.g. `{"type":"text","text":…}` or an image).
        private struct ContentPart: Decodable {
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try container.decodeIfPresent(String.self, forKey: .type)
            self.text = try container.decodeIfPresent(String.self, forKey: .text)
            self.toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
            self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError)

            // `content` is either a plain string or a list of parts (MCP tool results).
            // Parts without text, such as images, are skipped.
            if let string = try? container.decodeIfPresent(String.self, forKey: .content) {
                self.content = string
            } else if let parts = try? container.decodeIfPresent([ContentPart].self, forKey: .content) {
                self.content = parts.compactMap(\.text).joined(separator: "\n")
            } else {
                self.content = nil
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let messageContainer = try container.nestedContainer(
            keyedBy: MessageCodingKeys.self,
            forKey: .message
        )
        let messageIsError = try messageContainer.decodeIfPresent(Bool.self, forKey: .isError)

        var blockToolUseId: String?
        var blockIsError: Bool?
        if let stringContent = try? messageContainer.decode(String.self, forKey: .content) {
            self.content = stringContent
        } else if let blocks = try? messageContainer.decode([ContentBlockItem].self, forKey: .content) {
            let texts = blocks.compactMap { $0.type == "tool_result" ? $0.content : ($0.text ?? $0.content) }
            self.content = texts.joined(separator: "\n")
            blockToolUseId = blocks.first(where: { $0.toolUseId != nil })?.toolUseId
            blockIsError = blocks.first(where: { $0.type == "tool_result" })?.isError
        } else {
            self.content = ""
        }
        self.isError = messageIsError ?? blockIsError ?? false
        self.toolUseId = try messageContainer.decodeIfPresent(String.self, forKey: .toolUseId) ?? blockToolUseId
    }
}

// MARK: - UsageInfo Decodable

extension UsageInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        self.cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        self.cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    }
}

// MARK: - ContextWindowInfo Decodable

extension ContextWindowInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case remainingPercentage = "remaining_percentage"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercentage = try container.decodeIfPresent(Double.self, forKey: .usedPercentage) ?? 0
        self.remainingPercentage = try container.decodeIfPresent(Double.self, forKey: .remainingPercentage) ?? 0
    }
}

// MARK: - ResultEvent Decodable

extension ResultEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms"
        case totalCostUsd = "total_cost_usd"
        case sessionId = "session_id"
        case isError = "is_error"
        case totalTurns = "total_turns"
        case usage
        case contextWindow = "context_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        self.totalCostUsd = try container.decodeIfPresent(Double.self, forKey: .totalCostUsd)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        self.totalTurns = try container.decodeIfPresent(Int.self, forKey: .totalTurns)
        self.usage = try container.decodeIfPresent(UsageInfo.self, forKey: .usage)
        self.contextWindow = try container.decodeIfPresent(ContextWindowInfo.self, forKey: .contextWindow)
    }
}

// MARK: - RateLimitInfo Decodable

extension RateLimitInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case rateLimitInfo = "rate_limit_info"
        case status
        case retrySec = "retry_sec"
    }

    private enum NestedCodingKeys: String, CodingKey {
        case status
        case retrySec = "retry_sec"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.nestedContainer(keyedBy: NestedCodingKeys.self, forKey: .rateLimitInfo) {
            self.status = try nested.decode(String.self, forKey: .status)
            self.retrySec = try nested.decodeIfPresent(Double.self, forKey: .retrySec)
        } else {
            self.status = try container.decode(String.self, forKey: .status)
            self.retrySec = try container.decodeIfPresent(Double.self, forKey: .retrySec)
        }
    }
}
