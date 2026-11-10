import Foundation
import Testing
@testable import ClarcCore

// The CLI `init` event lists the MCP servers (connectors) of the session with
// their status. The app shows them as they were reported; a missing or
// malformed list must never break decoding of the rest of the event.

@Suite("SystemEvent connectors decoding")
struct SystemEventConnectorsTests {

    /// A real `init` event (CLI 2.1.311) with connector names replaced.
    private let sampleInit = """
    {"type":"system","subtype":"init","cwd":"/tmp/x","session_id":"6b4a257e-7ecc-4163-bd5a-0d02d181190d","tools":["Bash","Read"],"mcp_servers":[{"name":"server-a","status":"connected","source":"user"},{"name":"plugin:x:server-b","status":"failed","source":"plugin"},{"name":"server-c","status":"pending","source":"user"},{"name":"claude.ai Server D","status":"needs-auth","source":"claudeai"}],"model":"claude-opus-5-5","permissionMode":"default","claude_code_version":"2.1.311"}
    """

    private func decodeSystem(_ json: String) throws -> SystemEvent {
        let event = try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
        guard case .system(let system) = event else {
            Issue.record("Expected a system event, got \(event)")
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a system event"))
        }
        return system
    }

    @Test("The sample init event yields its connectors in CLI order")
    func sampleEvent() throws {
        let event = try decodeSystem(sampleInit)
        #expect(event.subtype == "init")
        #expect(event.sessionId == "6b4a257e-7ecc-4163-bd5a-0d02d181190d")
        #expect(event.model == "claude-opus-5-5")
        #expect(event.claudeCodeVersion == "2.1.311")
        #expect(event.mcpServers?.count == 4)

        let connectors = try #require(event.connectors)
        #expect(connectors.map(\.name) == ["server-a", "plugin:x:server-b", "server-c", "claude.ai Server D"])
        #expect(connectors.map(\.state) == [.connected, .failed, .pending, .needsAuth])
    }

    @Test("An event with two connectors decodes into two items")
    func twoConnectors() throws {
        let event = try decodeSystem("""
        {"type":"system","subtype":"init","session_id":"s1","mcp_servers":[{"name":"one","status":"connected"},{"name":"two","status":"connected"}]}
        """)
        let connectors = try #require(event.connectors)
        #expect(connectors.count == 2)
        #expect(connectors.map(\.name) == ["one", "two"])
        #expect(connectors.allSatisfy { $0.state == .connected })
    }

    @Test("An empty list stays an empty list")
    func emptyList() throws {
        let event = try decodeSystem("""
        {"type":"system","subtype":"init","session_id":"s1","mcp_servers":[]}
        """)
        #expect(event.connectors == [])
    }

    @Test("An event without mcp_servers gives nil and keeps the other fields")
    func missingField() throws {
        let event = try decodeSystem("""
        {"type":"system","subtype":"init","session_id":"s1","tools":["Bash"],"model":"m","claude_code_version":"1.0"}
        """)
        #expect(event.mcpServers == nil)
        #expect(event.mcpServerErrors == nil)
        #expect(event.connectors == nil)
        #expect(event.sessionId == "s1")
        #expect(event.tools == ["Bash"])
        #expect(event.model == "m")
        #expect(event.claudeCodeVersion == "1.0")
    }

    @Test("mcp_servers of the wrong type does not break decoding")
    func wrongType() throws {
        let event = try decodeSystem("""
        {"type":"system","subtype":"init","session_id":"s1","model":"m","mcp_servers":"oops","mcp_server_errors":{"a":1}}
        """)
        #expect(event.mcpServers == nil)
        #expect(event.mcpServerErrors == nil)
        #expect(event.connectors == nil)
        #expect(event.sessionId == "s1")
        #expect(event.model == "m")
    }

    @Test("Known status strings map to their states, others to unknown")
    func statusMapping() {
        #expect(SessionConnector.State(status: "connected") == .connected)
        #expect(SessionConnector.State(status: "failed") == .failed)
        #expect(SessionConnector.State(status: "needs-auth") == .needsAuth)
        #expect(SessionConnector.State(status: "pending") == .pending)
        #expect(SessionConnector.State(status: "disabled") == .unknown("disabled"))
    }

    @Test("An unknown status is kept with its text")
    func unknownStatusInEvent() throws {
        let event = try decodeSystem("""
        {"type":"system","subtype":"init","session_id":"s1","mcp_servers":[{"name":"x","status":"sleeping"}]}
        """)
        let connectors = try #require(event.connectors)
        #expect(connectors.first?.state == .unknown("sleeping"))
    }

    @Test("A record from mcp_server_errors becomes a failed connector with its message")
    func serverErrors() throws {
        let event = try decodeSystem("""
        {"type":"system","subtype":"init","session_id":"s1","mcp_servers":[{"name":"ok","status":"connected"}],"mcp_server_errors":[{"name":"broken","type":"stdio","message":"command not found"}]}
        """)
        let connectors = try #require(event.connectors)
        #expect(connectors.map(\.name) == ["ok", "broken"])
        #expect(connectors[0].state == .connected)
        #expect(connectors[0].message == nil)
        #expect(connectors[1].state == .failed)
        #expect(connectors[1].message == "command not found")
    }

    @Test("Errors alone still produce a list")
    func errorsWithoutServers() throws {
        let event = try decodeSystem("""
        {"type":"system","subtype":"init","session_id":"s1","mcp_server_errors":[{"name":"broken","message":"bad config"}]}
        """)
        let connectors = try #require(event.connectors)
        #expect(connectors.count == 1)
        #expect(connectors[0].state == .failed)
        #expect(connectors[0].message == "bad config")
    }

    @Test("The existing initializer still works without connector arguments")
    func compatibleInitializer() {
        let event = SystemEvent(subtype: "init", sessionId: "s1", tools: nil, model: nil, claudeCodeVersion: nil)
        #expect(event.mcpServers == nil)
        #expect(event.connectors == nil)
    }
}
