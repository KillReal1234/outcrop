import Foundation
import Testing
@testable import ClarcCore

// Projects are discovered from the `cwd` recorded in Claude Code session files.
// The pure parts — reading `cwd` from a file head, filtering candidate folders
// and dropping known or dismissed paths — are checked here without touching
// the real `~/.claude/projects`.

private func lines(_ items: [String]) -> Data {
    Data(items.joined(separator: "\n").utf8)
}

@Suite("ProjectDiscovery.cwd(fromSessionFileHead:)")
struct ProjectDiscoveryCwdTests {

    @Test func readsCwdFromSecondLine() {
        let data = lines([
            #"{"type":"file-history-snapshot","messageId":"m1"}"#,
            #"{"type":"user","cwd":"/Users/test/Projects/App","sessionId":"s1"}"#,
        ])
        #expect(ProjectDiscovery.cwd(fromSessionFileHead: data) == "/Users/test/Projects/App")
    }

    @Test func skipsCorruptedFirstLine() {
        let data = lines([
            #"{"type":"user","cwd":"/Users/te"#,
            #"{"type":"assistant","cwd":"/Users/test/Work"}"#,
        ])
        #expect(ProjectDiscovery.cwd(fromSessionFileHead: data) == "/Users/test/Work")
    }

    @Test func skipsEmptyCwd() {
        let data = lines([
            #"{"type":"user","cwd":""}"#,
            #"{"type":"user","cwd":"/Users/test/B"}"#,
        ])
        #expect(ProjectDiscovery.cwd(fromSessionFileHead: data) == "/Users/test/B")
    }

    @Test func noCwdField_returnsNil() {
        let data = lines([
            #"{"type":"file-history-snapshot"}"#,
            #"{"type":"summary","summary":"x"}"#,
        ])
        #expect(ProjectDiscovery.cwd(fromSessionFileHead: data) == nil)
    }

    @Test func garbage_returnsNil() {
        #expect(ProjectDiscovery.cwd(fromSessionFileHead: Data([0xFF, 0x00, 0x7B])) == nil)
        #expect(ProjectDiscovery.cwd(fromSessionFileHead: Data()) == nil)
    }

    @Test func cwdBeyondLineLimit_isIgnored() {
        let filler = Array(repeating: #"{"type":"progress"}"#, count: ProjectDiscovery.headLineLimit)
        let data = lines(filler + [#"{"type":"user","cwd":"/Users/test/Late"}"#])
        #expect(ProjectDiscovery.cwd(fromSessionFileHead: data) == nil)
    }
}

@Suite("ProjectDiscovery.isCandidate")
struct ProjectDiscoveryCandidateTests {

    let home = "/Users/test"

    @Test(arguments: [
        "/private/tmp/x",
        "/tmp/x",
        "/tmp",
        "/private/var/folders/v0/T/x",
        "/Users/test/Library/Application Support/Claude/scratch-workspaces/a/b",
        "/Users/test/p/.claude/worktrees/w",
        "/Users/test/p/.claude/worktrees/w/sub",
    ])
    func rejected(path: String) {
        #expect(!ProjectDiscovery.isCandidate(path: path, home: home))
    }

    @Test(arguments: [
        "/Users/test/Documents/Work_folder/Projects/Clarc",
        "/Users/test",
        "/Users/test/p/.claude",
        "/Users/test/tmp/x",
        "/Users/test/worktrees/x",
    ])
    func accepted(path: String) {
        #expect(ProjectDiscovery.isCandidate(path: path, home: home))
    }

    @Test func rejectsPassedTemporaryDirectory() {
        let tmp = "/Volumes/Scratch/T/"
        #expect(!ProjectDiscovery.isCandidate(path: "/Volumes/Scratch/T/run", home: home, temporaryDirectories: [tmp]))
        #expect(ProjectDiscovery.isCandidate(path: "/Volumes/Scratch/Tx", home: home, temporaryDirectories: [tmp]))
        #expect(ProjectDiscovery.isCandidate(path: "/Volumes/Scratch/T/run", home: home))
    }

    @Test func emptyOrRelativePath_isRejected() {
        #expect(!ProjectDiscovery.isCandidate(path: "", home: home))
        #expect(!ProjectDiscovery.isCandidate(path: "relative/dir", home: home))
    }
}

@Suite("ProjectDiscovery.newProjectPaths")
struct ProjectDiscoveryNewPathsTests {

    @Test func dropsDuplicatesExistingAndDismissed_keepsOrder() {
        let result = ProjectDiscovery.newProjectPaths(
            candidates: [
                "/Users/test/C",
                "/Users/test/A",
                "/Users/test/C/",
                "/Users/test/Existing/",
                "/Users/test/Dismissed",
                "/Users/test/B",
                "/Users/test/A",
            ],
            existing: ["/Users/test/Existing"],
            dismissed: ["/Users/test/Dismissed/"]
        )
        #expect(result == ["/Users/test/C", "/Users/test/A", "/Users/test/B"])
    }

    @Test func trailingSlashCandidate_isStandardized() {
        let result = ProjectDiscovery.newProjectPaths(candidates: ["/Users/test/X/"], existing: [], dismissed: [])
        #expect(result == ["/Users/test/X"])
    }

    @Test func nothingNew_returnsEmpty() {
        let result = ProjectDiscovery.newProjectPaths(
            candidates: ["/Users/test/A"],
            existing: ["/Users/test/A/"],
            dismissed: []
        )
        #expect(result.isEmpty)
    }
}
