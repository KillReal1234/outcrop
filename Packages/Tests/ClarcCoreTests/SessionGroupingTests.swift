import Foundation
import Testing
@testable import ClarcCore

// The sidebar groups sessions under project headings. Grouping is a pure
// function so the ordering rules can be checked without running the app.

private func project(_ name: String) -> Project {
    Project(name: name, path: "/tmp/\(name)")
}

private func summary(
    _ id: String,
    in project: Project,
    updated: TimeInterval,
    pinned: Bool = false,
    completed: Bool = false
) -> ChatSession.Summary {
    summary(id, projectId: project.id, updated: updated, pinned: pinned, completed: completed)
}

private func summary(
    _ id: String,
    projectId: UUID,
    updated: TimeInterval,
    pinned: Bool = false,
    completed: Bool = false
) -> ChatSession.Summary {
    ChatSession.Summary(
        id: id,
        projectId: projectId,
        title: id,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: updated),
        isPinned: pinned,
        isCompleted: completed
    )
}

@Suite("SessionGrouping.groups")
struct SessionGroupingTests {

    @Test("Groups follow the project order, each holding only its own sessions")
    func groupOrderFollowsProjects() {
        let alpha = project("Alpha")
        let beta = project("Beta")
        let sessions = [
            summary("b1", in: beta, updated: 30),
            summary("a1", in: alpha, updated: 20),
            summary("b2", in: beta, updated: 10),
        ]

        let groups = SessionGrouping.groups(projects: [alpha, beta], sessions: sessions)

        #expect(groups.map(\.projectId) == [alpha.id, beta.id])
        #expect(groups.map(\.name) == ["Alpha", "Beta"])
        #expect(groups[0].sessions.map(\.id) == ["a1"])
        #expect(groups[1].sessions.map(\.id) == ["b1", "b2"])
    }

    @Test("Pinned sessions come first, then the rest by most recent update")
    func pinnedFirstThenNewest() {
        let alpha = project("Alpha")
        let sessions = [
            summary("old", in: alpha, updated: 10),
            summary("pinnedOld", in: alpha, updated: 1, pinned: true),
            summary("new", in: alpha, updated: 30),
            summary("pinnedNew", in: alpha, updated: 5, pinned: true),
        ]

        let groups = SessionGrouping.groups(projects: [alpha], sessions: sessions)

        #expect(groups.first?.sessions.map(\.id) == ["pinnedNew", "pinnedOld", "new", "old"])
    }

    @Test("A project without sessions yields an empty group")
    func emptyProjectKeepsItsGroup() {
        let alpha = project("Alpha")
        let empty = project("Empty")

        let groups = SessionGrouping.groups(
            projects: [alpha, empty],
            sessions: [summary("a1", in: alpha, updated: 1)]
        )

        #expect(groups.map(\.projectId) == [alpha.id, empty.id])
        #expect(groups[1].sessions.isEmpty)
    }

    @Test("No projects and no sessions yields no groups")
    func nothingYieldsNoGroups() {
        #expect(SessionGrouping.groups(projects: [], sessions: []).isEmpty)
    }

    @Test("A session of an unknown project lands in a last group without a project id")
    func unknownProjectGoesToOther() {
        let alpha = project("Alpha")
        let orphan = summary("orphan", projectId: UUID(), updated: 50)

        let groups = SessionGrouping.groups(
            projects: [alpha],
            sessions: [orphan, summary("a1", in: alpha, updated: 1)],
            otherGroupName: "Other"
        )

        #expect(groups.count == 2)
        #expect(groups.last?.projectId == nil)
        #expect(groups.last?.name == "Other")
        #expect(groups.last?.sessions.map(\.id) == ["orphan"])
    }

    @Test("There is no Other group when every session has a known project")
    func noOtherGroupWithoutOrphans() {
        let alpha = project("Alpha")

        let groups = SessionGrouping.groups(
            projects: [alpha],
            sessions: [summary("a1", in: alpha, updated: 1)]
        )

        #expect(groups.allSatisfy { $0.projectId != nil })
    }

    @Test("Hiding completed sessions drops them except the ids held back for animation")
    func hideCompletedKeepsPendingIds() {
        let alpha = project("Alpha")
        let sessions = [
            summary("open", in: alpha, updated: 30),
            summary("done", in: alpha, updated: 20, completed: true),
            summary("justDone", in: alpha, updated: 10, completed: true),
        ]

        let hidden = SessionGrouping.groups(
            projects: [alpha],
            sessions: sessions,
            hideCompleted: true,
            pendingHideIds: ["justDone"]
        )
        let shown = SessionGrouping.groups(projects: [alpha], sessions: sessions, hideCompleted: false)

        #expect(hidden.first?.sessions.map(\.id) == ["open", "justDone"])
        #expect(shown.first?.sessions.map(\.id) == ["open", "done", "justDone"])
    }

    @Test("Hiding completed sessions keeps the project heading")
    func hideCompletedKeepsHeadings() {
        let alpha = project("Alpha")

        let groups = SessionGrouping.groups(
            projects: [alpha],
            sessions: [summary("done", in: alpha, updated: 1, completed: true)],
            hideCompleted: true
        )

        #expect(groups.map(\.projectId) == [alpha.id])
        #expect(groups.first?.sessions.isEmpty == true)
    }

    @Test("Duplicate session ids are dropped")
    func duplicatesDropped() {
        let alpha = project("Alpha")
        let sessions = [
            summary("dup", in: alpha, updated: 10),
            summary("dup", in: alpha, updated: 5),
            summary("other", in: alpha, updated: 1),
        ]

        let groups = SessionGrouping.groups(projects: [alpha], sessions: sessions)

        #expect(groups.first?.sessions.map(\.id) == ["dup", "other"])
    }

    @Test("Flat visible order runs group after group and skips collapsed groups")
    func visibleOrderSkipsCollapsed() {
        let alpha = project("Alpha")
        let beta = project("Beta")
        let gamma = project("Gamma")
        let sessions = [
            summary("a1", in: alpha, updated: 30),
            summary("a2", in: alpha, updated: 20),
            summary("b1", in: beta, updated: 40),
            summary("c1", in: gamma, updated: 10),
            summary("orphan", projectId: UUID(), updated: 5),
        ]
        let groups = SessionGrouping.groups(projects: [alpha, beta, gamma], sessions: sessions)

        let all = SessionGrouping.visibleSessions(in: groups, collapsed: [])
        let withBetaCollapsed = SessionGrouping.visibleSessions(in: groups, collapsed: [beta.id])

        #expect(all.map(\.id) == ["a1", "a2", "b1", "c1", "orphan"])
        #expect(withBetaCollapsed.map(\.id) == ["a1", "a2", "c1", "orphan"])
    }
}

// Collapsed project groups persist across launches as an array of UUID strings.
// Each test runs on its own UserDefaults suite, never on `.standard`.

@Suite("CollapsedProjectsStore")
struct CollapsedProjectsStoreTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "CollapsedProjectsStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    @Test("Empty settings give an empty set")
    func emptySettings() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CollapsedProjectsStore(defaults: defaults)

        #expect(store.load(existingProjectIds: [UUID()]).isEmpty)
    }

    @Test("Garbage strings and ids of deleted projects are dropped on load")
    func garbageIsDropped() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let existing = UUID()
        let deleted = UUID()
        defaults.set(
            ["not-a-uuid", existing.uuidString, deleted.uuidString, 42] as [Any],
            forKey: CollapsedProjectsStore.key
        )

        let store = CollapsedProjectsStore(defaults: defaults)

        #expect(store.load(existingProjectIds: [existing]) == [existing])
    }

    @Test("A stored value that is not an array gives an empty set")
    func wrongTypeIsIgnored() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not-an-array", forKey: CollapsedProjectsStore.key)

        let store = CollapsedProjectsStore(defaults: defaults)

        #expect(store.load(existingProjectIds: [UUID()]).isEmpty)
    }

    @Test("Saving then loading gives back the same set")
    func roundTrip() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ids: Set<UUID> = [UUID(), UUID()]

        CollapsedProjectsStore(defaults: defaults).save(ids)
        let loaded = CollapsedProjectsStore(defaults: defaults).load(existingProjectIds: ids.union([UUID()]))

        #expect(loaded == ids)
    }

    @Test("The settings key matches the documented name")
    func keyName() {
        #expect(CollapsedProjectsStore.key == "sidebarCollapsedProjectIds")
    }
}
