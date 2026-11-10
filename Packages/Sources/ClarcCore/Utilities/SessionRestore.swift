import Foundation

/// Which session to reopen when a window enters a project.
public enum SessionRestore {

    /// The project's last-used session, when the window shows a new chat and
    /// restoring is wanted. `nil` means stay in the new chat.
    public static func sessionToRestore(
        project: Project,
        currentSessionId: String?,
        summaries: [ChatSession.Summary],
        restoreLastSession: Bool
    ) -> ChatSession.Summary? {
        guard restoreLastSession,
              currentSessionId == nil,
              let lastId = project.lastSessionId else { return nil }
        return summaries.first(where: { $0.id == lastId && $0.projectId == project.id })
    }
}
