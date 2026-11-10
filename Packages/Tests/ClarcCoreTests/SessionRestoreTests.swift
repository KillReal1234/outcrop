import Foundation
import Testing
@testable import ClarcCore

// Entering a project in new-chat state reopens its last session. Starting a
// new session from the sidebar must not. The decision is a pure function so it
// can be checked without the disk reload and CLI calls around it in AppState.

private func summary(_ id: String, projectId: UUID) -> ChatSession.Summary {
    ChatSession.Summary(
        id: id,
        projectId: projectId,
        title: id,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        isPinned: false
    )
}

@Suite("SessionRestore.sessionToRestore")
struct SessionRestoreTests {

    @Test func restoresLastSessionWhenEnteringInNewChatState() {
        let project = Project(name: "a", path: "/tmp/a", lastSessionId: "last")
        let summaries = [summary("other", projectId: project.id), summary("last", projectId: project.id)]

        let result = SessionRestore.sessionToRestore(
            project: project,
            currentSessionId: nil,
            summaries: summaries,
            restoreLastSession: true
        )

        #expect(result?.id == "last")
        #expect(result?.projectId == project.id)
    }

    @Test func restoreDisabled_returnsNil() {
        let project = Project(name: "a", path: "/tmp/a", lastSessionId: "last")

        let result = SessionRestore.sessionToRestore(
            project: project,
            currentSessionId: nil,
            summaries: [summary("last", projectId: project.id)],
            restoreLastSession: false
        )

        #expect(result == nil)
    }

    @Test func sessionAlreadyOpen_returnsNil() {
        let project = Project(name: "a", path: "/tmp/a", lastSessionId: "last")

        let result = SessionRestore.sessionToRestore(
            project: project,
            currentSessionId: "open",
            summaries: [summary("last", projectId: project.id)],
            restoreLastSession: true
        )

        #expect(result == nil)
    }

    @Test func noLastSession_returnsNil() {
        let project = Project(name: "a", path: "/tmp/a", lastSessionId: nil)

        let result = SessionRestore.sessionToRestore(
            project: project,
            currentSessionId: nil,
            summaries: [summary("last", projectId: project.id)],
            restoreLastSession: true
        )

        #expect(result == nil)
    }

    @Test func lastSessionIdBelongsToAnotherProject_returnsNil() {
        let project = Project(name: "a", path: "/tmp/a", lastSessionId: "last")

        let result = SessionRestore.sessionToRestore(
            project: project,
            currentSessionId: nil,
            summaries: [summary("last", projectId: UUID())],
            restoreLastSession: true
        )

        #expect(result == nil)
    }
}
