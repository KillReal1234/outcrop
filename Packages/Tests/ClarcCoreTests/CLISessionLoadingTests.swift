import Foundation
import Testing
@testable import ClarcCore

// Loading a session file must yield the same transcript no matter how the
// loader gets there (line filtering, parsing off the store actor). The store
// is pointed at a temporary projects directory, never at ~/.claude/projects.

/// A temporary CLI projects tree with one project directory.
private struct SessionFixture {
    let root: URL
    let cwd = "/Users/test/Projects/Sample"
    let projectId = UUID()
    let store: CLISessionStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLISessionLoadingTests-\(UUID().uuidString)", isDirectory: true)
        store = CLISessionStore(metaStore: SessionMetaStore(), projectsRoot: root)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    var projectDir: URL {
        root.appendingPathComponent(cwd.cliProjectDirName(), isDirectory: true)
    }

    func fileURL(sid: String) -> URL {
        projectDir.appendingPathComponent("\(sid).jsonl")
    }

    func write(_ text: String, sid: String) throws {
        try Data(text.utf8).write(to: fileURL(sid: sid))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Decodes every line without any filtering — the reference transcript.
private func referenceMessages(_ text: String) -> [ChatMessage] {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { d in
        let c = try d.singleValueContainer()
        let s = try c.decode(String.self)
        guard let date = withFractional.date(from: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: s)
        }
        return date
    }
    let lines = text.split(separator: "\n").compactMap {
        try? decoder.decode(CLISessionLine.self, from: Data($0.utf8))
    }
    return CLILineToBlocksMapper.map(lines: lines)
}

/// A user turn, a tool call with its result, an `ai-title`, several service
/// lines and an unfinished last line (a write in progress).
private let sampleSession = [
    #"{"type":"file-history-snapshot","messageId":"10000000-0000-0000-0000-000000000000","snapshot":{"trackedFileBackups":{}},"isSnapshotUpdate":false}"#,
    #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Привет! List the files, please."},"uuid":"10000000-0000-0000-0000-000000000001","timestamp":"2026-11-10T10:00:00.000Z","cwd":"/Users/test/Projects/Sample","sessionId":"s"}"#,
    #"{"type":"attachment","attachment":{"type":"file","path":"/tmp/a.png"},"uuid":"10000000-0000-0000-0000-000000000002","timestamp":"2026-11-10T10:00:00.100Z"}"#,
    #"{"type":"api-request","requestId":"req_1","uuid":"10000000-0000-0000-0000-000000000003","timestamp":"2026-11-10T10:00:00.200Z"}"#,
    #"{"parentUuid":"10000000-0000-0000-0000-000000000001","isSidechain":false,"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Sure, listing them."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},"uuid":"10000000-0000-0000-0000-000000000004","timestamp":"2026-11-10T10:00:01.000Z","cwd":"/Users/test/Projects/Sample"}"#,
    #"{"type":"progress","data":{"type":"hook_progress","hookName":"PreToolUse"},"uuid":"10000000-0000-0000-0000-000000000005","timestamp":"2026-11-10T10:00:01.100Z"}"#,
    #"{"parentUuid":"10000000-0000-0000-0000-000000000004","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"a.txt\n{\"type\":\"attachment\",\"name\":\"b.png\"}","is_error":false}]},"uuid":"10000000-0000-0000-0000-000000000006","timestamp":"2026-11-10T10:00:02.000Z"}"#,
    #"{"type":"api-request-blob","blob":"{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}","uuid":"10000000-0000-0000-0000-000000000007","timestamp":"2026-11-10T10:00:02.100Z"}"#,
    #"{"parentUuid":"10000000-0000-0000-0000-000000000006","isSidechain":false,"type":"assistant","message":{"id":"msg_2","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"There are two files."}]},"uuid":"10000000-0000-0000-0000-000000000008","timestamp":"2026-11-10T10:00:03.000Z"}"#,
    #"{"type":"ai-title","aiTitle":"List project files","sessionId":"s"}"#,
    #"{"type":"queue-operation","operation":"enqueue","content":"{\"type\":\"user\"}","timestamp":"2026-11-10T10:00:03.500Z"}"#,
    #"{"parentUuid":"10000000-0000-0000-0000-000000000008","isSidechain":false,"isMeta":true,"type":"user","message":{"role":"user","content":"<local-command-caveat>ignore</local-command-caveat>"},"uuid":"10000000-0000-0000-0000-000000000009","timestamp":"2026-11-10T10:00:04.000Z"}"#,
    #"{"parentUuid":"10000000-0000-0000-0000-000000000009","isSidechain":false,"type":"user","message":{"role":"user","content":"Спасибо"},"uuid":"10000000-0000-0000-0000-00000000000a","timestamp":"2026-11-10T10:00:05.000Z"}"#,
    #"{"parentUuid":"10000000-0000-0000-0000-00000000000a","isSidechain":false,"type":"assistant","message":{"id":"msg_3","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"You're welcome."}]},"uuid":"10000000-0000-0000-0000-00000000000b","timestamp":"2026-11-10T10:00:06.000Z"}"#,
    #"{"type":"system","subtype":"turn_duration","durationMs":1200,"uuid":"10000000-0000-0000-0000-00000000000c","timestamp":"2026-11-10T10:00:06.100Z"}"#,
    #"{"parentUuid":"10000000-0000-0000-0000-00000000000b","type":"user","message":{"role":"user","content":"unfinis"#,
].joined(separator: "\n")

@Suite("CLISessionStore.loadFullSession")
struct CLISessionLoadingTests {

    @Test func matchesUnfilteredMapping() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        let sid = UUID().uuidString.lowercased()
        try fixture.write(sampleSession, sid: sid)

        let session = await fixture.store.loadFullSession(sid: sid, cwd: fixture.cwd, projectId: fixture.projectId)
        let expected = referenceMessages(sampleSession)

        let messages = try #require(session?.messages)
        #expect(messages == expected)
        #expect(messages.map(\.role) == [.user, .assistant, .assistant, .user, .assistant])
        #expect(messages.first?.content == "Привет! List the files, please.")
        #expect(messages.last?.content == "You're welcome.")
        let call = try #require(messages[1].toolCalls.first)
        #expect(call.id == "toolu_1")
        #expect(call.result?.contains(#"{"type":"attachment","name":"b.png"}"#) == true)
        #expect(session?.title == "List project files")
        #expect(session?.projectId == fixture.projectId)
    }

    @Test func missingFile_returnsNil() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }

        let session = await fixture.store.loadFullSession(sid: "missing", cwd: fixture.cwd, projectId: fixture.projectId)
        #expect(session == nil)
    }

    // MARK: Cache

    @Test func secondLoadOfUnchangedFileReturnsSameTranscript() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        let sid = UUID().uuidString.lowercased()
        try fixture.write(sampleSession, sid: sid)

        let first = await fixture.store.loadFullSession(sid: sid, cwd: fixture.cwd, projectId: fixture.projectId)
        let second = await fixture.store.loadFullSession(sid: sid, cwd: fixture.cwd, projectId: fixture.projectId)
        #expect(first?.messages == second?.messages)
        #expect(first?.title == second?.title)
        #expect(first?.messages.isEmpty == false)
    }

    @Test func unchangedStampIsServedWithoutReadingTheFile() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        let sid = UUID().uuidString.lowercased()
        let url = fixture.fileURL(sid: sid)
        let original = sessionLines(count: 2, text: "a")
        try fixture.write(original, sid: sid)
        // A whole-second date survives setAttributes exactly (it rounds to µs).
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)

        let first = await fixture.store.loadFullSession(sid: sid, cwd: fixture.cwd, projectId: fixture.projectId)

        // Same size, same modification date, different content: only a cache
        // hit can still return the original text.
        let swapped = sessionLines(count: 2, text: "b")
        #expect(swapped.utf8.count == original.utf8.count)
        try fixture.write(swapped, sid: sid)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)

        let second = await fixture.store.loadFullSession(sid: sid, cwd: fixture.cwd, projectId: fixture.projectId)
        #expect(second?.messages == first?.messages)
        #expect(second?.messages.first?.content == "a0")
    }

    @Test func appendedLineIsPickedUp() async throws {
        let fixture = try SessionFixture()
        defer { fixture.cleanUp() }
        let sid = UUID().uuidString.lowercased()
        let complete = sampleSession.split(separator: "\n").dropLast().joined(separator: "\n") + "\n"
        try fixture.write(complete, sid: sid)

        let before = try #require(await fixture.store.loadFullSession(sid: sid, cwd: fixture.cwd, projectId: fixture.projectId))

        let appended = #"{"parentUuid":"10000000-0000-0000-0000-00000000000b","isSidechain":false,"type":"user","message":{"role":"user","content":"One more thing"},"uuid":"10000000-0000-0000-0000-00000000000d","timestamp":"2026-11-10T10:00:07.000Z"}"# + "\n"
        let handle = try FileHandle(forWritingTo: fixture.fileURL(sid: sid))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let after = try #require(await fixture.store.loadFullSession(sid: sid, cwd: fixture.cwd, projectId: fixture.projectId))
        #expect(after.messages.count == before.messages.count + 1)
        #expect(after.messages.last?.content == "One more thing")
        #expect(Array(after.messages.dropLast()) == before.messages)
    }
}

/// `count` user/assistant pairs with texts `"\(text)\(i)"`, uuid-stable.
private func sessionLines(count: Int, text: String) -> String {
    (0..<count).flatMap { i -> [String] in
        let u = String(format: "20000000-0000-0000-0000-%012d", 2 * i)
        let a = String(format: "20000000-0000-0000-0000-%012d", 2 * i + 1)
        return [
            #"{"type":"user","message":{"role":"user","content":"\#(text)\#(i)"},"uuid":"\#(u)","timestamp":"2026-11-10T11:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"id":"m\#(i)","type":"message","role":"assistant","content":[{"type":"text","text":"reply \#(text)\#(i)"}]},"uuid":"\#(a)","timestamp":"2026-11-10T11:00:01.000Z"}"#,
        ]
    }.joined(separator: "\n") + "\n"
}
