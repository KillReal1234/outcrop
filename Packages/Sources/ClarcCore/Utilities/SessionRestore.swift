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

    /// A session restored when the project was entered is opened from the
    /// summaries already in memory, before they are re-read. True when that
    /// restored session is still the current one but is no longer among the
    /// project's re-read summaries (its file was deleted), so the window
    /// should fall back to a new chat. A session the user picked or started
    /// afterwards is never affected.
    public static func restoredSessionIsGone(
        restoredSessionId: String?,
        currentSessionId: String?,
        projectId: UUID,
        summaries: [ChatSession.Summary]
    ) -> Bool {
        guard let restoredSessionId, currentSessionId == restoredSessionId else { return false }
        return !summaries.contains(where: { $0.id == restoredSessionId && $0.projectId == projectId })
    }
}
