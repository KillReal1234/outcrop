import Foundation
import Testing
@testable import ClarcCore

// Tool results from MCP servers arrive with `content` as a list of blocks
// (text, image, ...) instead of a plain string. The live stream must still
// surface their text in the tool card.

@Suite("UserMessage tool_result decoding")
struct ToolResultDecodingTests {

    private func decodeUser(_ json: String) throws -> UserMessage {
        let event = try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
        guard case .user(let message) = event else {
            Issue.record("Expected a user event, got \(event)")
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a user event"))
        }
        return message
    }

    @Test("Text blocks in a list are joined with newlines")
    func listOfTextBlocks() throws {
        let json = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"Navigated to https://example.com/"},{"type":"text","text":"Tab Context"}]}]}}
        """
        let message = try decodeUser(json)
        #expect(message.content == "Navigated to https://example.com/\nTab Context")
        #expect(message.toolUseId == "t1")
        #expect(message.isError == false)
    }

    @Test("Image blocks are skipped and the text stays")
    func listWithImageBlock() throws {
        let json = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"Navigated to https://example.com/"},{"type":"text","text":"Tab Context"},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"AAAA"}}]}]}}
        """
        let message = try decodeUser(json)
        #expect(message.content == "Navigated to https://example.com/\nTab Context")
        #expect(message.toolUseId == "t1")
    }

    @Test("is_error on the tool_result block marks the message as an error")
    func blockLevelError() throws {
        let json = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":[{"type":"text","text":"Something failed"}]}]}}
        """
        let message = try decodeUser(json)
        #expect(message.isError == true)
        #expect(message.content == "Something failed")
        #expect(message.toolUseId == "t2")
    }

    @Test("String content keeps working as before")
    func stringContent() throws {
        let json = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"file contents"}]}}
        """
        let message = try decodeUser(json)
        #expect(message.content == "file contents")
        #expect(message.toolUseId == "t3")
        #expect(message.isError == false)
    }
}
