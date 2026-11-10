import Foundation

/// One project heading in the session sidebar and the sessions listed under it.
/// `projectId == nil` marks the trailing group for sessions whose project is
/// not in the project list.
public struct SessionGroup: Identifiable, Equatable, Sendable {
    public let projectId: UUID?
    public let name: String
    public let sessions: [ChatSession.Summary]

    public var id: String { projectId?.uuidString ?? "other" }

    public init(projectId: UUID?, name: String, sessions: [ChatSession.Summary]) {
        self.projectId = projectId
        self.name = name
        self.sessions = sessions
    }
}

/// Pure grouping of session summaries under project headings for the sidebar.
public enum SessionGrouping {

    /// Pinned sessions first, then the most recently updated.
    public static func isOrderedBefore(_ a: ChatSession.Summary, _ b: ChatSession.Summary) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        return a.updatedAt > b.updatedAt
    }

    /// Groups `sessions` under `projects`, in project order.
    ///
    /// - Every project gets a group, even an empty one.
    /// - Sessions whose project is unknown go to a last group named
    ///   `otherGroupName` without a project id; that group exists only when
    ///   it is non-empty.
    /// - Duplicate session ids are dropped, keeping the first in sort order.
    /// - With `hideCompleted`, completed sessions are dropped unless their id
    ///   is in `pendingHideIds` (rows kept briefly for the completion animation).
    public static func groups(
        projects: [Project],
        sessions: [ChatSession.Summary],
        hideCompleted: Bool = false,
        pendingHideIds: Set<String> = [],
        otherGroupName: String = "Other"
    ) -> [SessionGroup] {
        let knownIds = Set(projects.map(\.id))
        var seen = Set<String>()
        var byProject: [UUID: [ChatSession.Summary]] = [:]
        var orphans: [ChatSession.Summary] = []

        for summary in sessions.sorted(by: isOrderedBefore) {
            guard seen.insert(summary.id).inserted else { continue }
            if hideCompleted && summary.isCompleted && !pendingHideIds.contains(summary.id) {
                continue
            }
            if knownIds.contains(summary.projectId) {
                byProject[summary.projectId, default: []].append(summary)
            } else {
                orphans.append(summary)
            }
        }

        var seenProjects = Set<UUID>()
        var result: [SessionGroup] = []
        for project in projects where seenProjects.insert(project.id).inserted {
            result.append(SessionGroup(
                projectId: project.id,
                name: project.name,
                sessions: byProject[project.id] ?? []
            ))
        }
        if !orphans.isEmpty {
            result.append(SessionGroup(projectId: nil, name: otherGroupName, sessions: orphans))
        }
        return result
    }

    /// Flat order of the sessions actually shown: group after group, skipping
    /// collapsed groups. Shift-click range selection runs over this order.
    /// The group without a project id is never collapsed.
    public static func visibleSessions(
        in groups: [SessionGroup],
        collapsed: Set<UUID>
    ) -> [ChatSession.Summary] {
        groups.flatMap { group -> [ChatSession.Summary] in
            if let projectId = group.projectId, collapsed.contains(projectId) { return [] }
            return group.sessions
        }
    }
}

/// Persists which sidebar project groups are collapsed. Collapsed (not
/// expanded) ids are stored so that a newly added project starts expanded.
/// Stored as an array of UUID strings; reading tolerates garbage.
public struct CollapsedProjectsStore {
    public static let key = "sidebarCollapsedProjectIds"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Collapsed project ids, limited to `existingProjectIds`. Entries that are
    /// not UUID strings, or that belong to deleted projects, are ignored.
    public func load(existingProjectIds: Set<UUID>) -> Set<UUID> {
        guard let raw = defaults.array(forKey: Self.key) else { return [] }
        let ids = raw.compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }
        return Set(ids).intersection(existingProjectIds)
    }

    public func save(_ ids: Set<UUID>) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: Self.key)
    }
}
