import Foundation
import Testing
@testable import ClarcCore

// Session files carry many lines the transcript never shows (API request
// blobs, attachments, file snapshots, progress). They are dropped before JSON
// decoding by looking for the top-level `"type":"…"` of chat lines in the raw
// text. The CLI writes compact JSON, and quotes inside string values are
// escaped, so a nested `\"type\":\"attachment\"` never looks like a top-level type.

@Suite("CLISessionLineFilter.needsDecoding")
struct CLISessionLineFilterTests {

    private func passes(_ line: String) -> Bool {
        CLISessionLineFilter.needsDecoding(Substring(line))
    }

    @Test func chatLinesPass() {
        #expect(passes(#"{"parentUuid":null,"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1"}"#))
        #expect(passes(#"{"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","content":[]},"uuid":"a1"}"#))
        #expect(passes(#"{"type":"ai-title","aiTitle":"Fix the build","sessionId":"s1"}"#))
    }

    @Test func serviceLinesAreDropped() {
        #expect(!passes(#"{"type":"api-request-blob","blob":"{}","uuid":"b1"}"#))
        #expect(!passes(#"{"type":"attachment","attachment":{"path":"/tmp/a.png"},"uuid":"t1"}"#))
        #expect(!passes(#"{"type":"file-history-snapshot","messageId":"m1","snapshot":{}}"#))
        #expect(!passes(#"{"type":"queue-operation","operation":"enqueue","content":"next"}"#))
        #expect(!passes(#"{"type":"progress","data":{"kind":"hook"},"uuid":"p1"}"#))
    }

    @Test func unknownTypeIsDropped() {
        #expect(!passes(#"{"type":"some-future-record","payload":{"x":1}}"#))
        #expect(!passes(#"{"no-type":true}"#))
        #expect(!passes(""))
    }

    @Test func userLineWithEscapedAttachmentTypeInToolResultPasses() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"{\"type\":\"attachment\",\"path\":\"/tmp/a\"}"}]},"uuid":"u2"}"#
        #expect(passes(line))
    }

    @Test func escapedChatTypeAloneDoesNotPass() {
        // A service line whose string payload mentions a chat type stays dropped.
        let line = #"{"type":"queue-operation","content":"{\"type\":\"user\"}"}"#
        #expect(!passes(line))
    }

    @Test func cyrillicLinePasses() {
        #expect(passes(#"{"type":"user","message":{"role":"user","content":"Привет, мир"},"uuid":"u3"}"#))
    }
}
