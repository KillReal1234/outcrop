import Foundation
import SwiftUI

// MARK: - InspectorTab

public enum InspectorTab: String, CaseIterable {
    case session = "Session"
    case terminal = "Terminal"
    case files = "Files"
    case memo = "Memo"

    public var icon: String {
        switch self {
        case .session: "info.circle"
        case .terminal: "apple.terminal"
        case .files: "folder"
        case .memo: "note.text"
        }
    }
}

// MARK: - PendingFilePreview

/// What the user asked the file preview to do while it had unsaved edits.
/// Held back until the edits are saved or discarded.
public enum PendingFilePreview: Sendable {
    case open(PreviewFile)
    case close
}

// MARK: - InspectorPosition

/// Where the inspector panel is docked relative to the chat.
public enum InspectorPosition: String, CaseIterable {
    case right = "Right"
    case bottom = "Bottom"
}

// MARK: - QueuedMessage

public struct QueuedMessage: Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var attachments: [Attachment]

    public init(text: String, attachments: [Attachment]) {
        self.id = UUID()
        self.text = text
        self.attachments = attachments
    }
}

/// Per-window independent UI/session state. Does not own services or shared data.
@Observable
@MainActor
public final class WindowState {

    // MARK: - Window Identity

    public let id = UUID()
    public var newSessionKey: String { "__new_\(id.uuidString)__" }

    // MARK: - Project / Session Selection

    public var selectedProject: Project?
    public var currentSessionId: String?

    // MARK: - Placeholder Tracking

    public private(set) var pendingPlaceholderIds: Set<String> = []

    // MARK: - Input

    public var inputText = ""
    public var attachments: [Attachment] = []
    public var draftTexts: [String: String] = [:]
    public var draftQueues: [String: [QueuedMessage]] = [:]

    // MARK: - Message Queue

    public var messageQueue: [QueuedMessage] = []

    public func enqueueMessage(text: String, attachments: [Attachment]) {
        messageQueue.append(QueuedMessage(text: text, attachments: attachments))
    }

    public func dequeueMessage(id: UUID) {
        messageQueue.removeAll { $0.id == id }
    }

    public func dequeueNext() -> QueuedMessage? {
        guard !messageQueue.isEmpty else { return nil }
        return messageQueue.removeFirst()
    }

    // MARK: - Permission Queue

    public var pendingPermissions: [PermissionRequest] = []

    // MARK: - AskUserQuestion Response Handler

    /// Invoked by chat UI when the user answers an `AskUserQuestion` tool prompt.
    /// Parameters: (toolUseId, optionLabel). Set by `AppState` at window init.
    public var answerQuestionHandler: (@MainActor @Sendable (String, String) -> Void)?

    // MARK: - UI State

    public var interactiveTerminal: InteractiveTerminalState?
    public var showInspector: Bool = false
    public var inspectorTab: InspectorTab = .session
    /// File shown in the inspector's Files tab. Change it through `openFilePreview(_:)`
    /// and `closeFilePreview()` so unsaved edits are not dropped.
    public var inspectorFile: PreviewFile?
    /// Mirrored by the file preview: true while it has unsaved edits.
    public var filePreviewIsDirty = false
    /// A file switch or close held back by unsaved edits; the preview asks what to do.
    public var pendingFilePreview: PendingFilePreview?
    /// Counts requests to focus the file search. The tree is created lazily, so it
    /// serves a request both when the counter changes and when it first appears.
    public private(set) var fileSearchTrigger = 0
    @ObservationIgnored private var servedFileSearchTrigger = 0
    public var diffFile: PreviewFile?
    public var showMarketplace = false
    public var showModelPicker = false
    public var showEffortPicker = false
    /// Per-session model override. When set, this model is used instead of the global default.
    /// Cleared when a new chat is started or a different session is selected.
    public var sessionModel: String?
    /// Per-session effort override. When set, passed as --effort to the CLI.
    /// Cleared when a new chat is started or a different session is selected.
    public var sessionEffort: String?
    /// Per-session permission mode override. When set, overrides the global permissionMode.
    /// Cleared when a new chat is started or a different session is selected.
    public var sessionPermissionMode: PermissionMode?
    public var requestInputFocus = false
    public var isInitialized = false
    public var errorMessage: String?
    public var showError = false

    // MARK: - Window Kind

    public var isProjectWindow = false

    // MARK: - Focus Mode

    public var focusMode: Bool = false

    // MARK: - Session Switch Task

    private var sessionSwitchTask: Task<Void, Never>?

    public init() {}

    // MARK: - Internal Helpers

    public func insertPendingPlaceholder(_ id: String) {
        pendingPlaceholderIds.insert(id)
    }

    public func removePendingPlaceholder(_ id: String) {
        pendingPlaceholderIds.remove(id)
    }

    public func cancelSessionSwitchTask() {
        sessionSwitchTask?.cancel()
    }

    public func setSessionSwitchTask(_ task: Task<Void, Never>) {
        sessionSwitchTask = task
    }

    // MARK: - Inspector Helpers

    /// Shows the inspector on the given tab.
    public func showInspectorTab(_ tab: InspectorTab) {
        inspectorTab = tab
        showInspector = true
    }

    /// Opens a file in the Files tab. With unsaved edits in the current preview the
    /// switch is held back in `pendingFilePreview`; the panel is shown either way.
    public func openFilePreview(_ file: PreviewFile) {
        showInspectorTab(.files)
        if filePreviewIsDirty {
            if inspectorFile?.path == file.path { return }
            pendingFilePreview = .open(file)
        } else {
            inspectorFile = file
        }
    }

    /// Closes the file preview, or holds the close back while there are unsaved edits.
    public func closeFilePreview() {
        if filePreviewIsDirty {
            pendingFilePreview = .close
        } else {
            inspectorFile = nil
        }
    }

    /// Closes the preview unless it has unsaved edits (used when the project changes).
    public func closeFilePreviewIfClean() {
        guard !filePreviewIsDirty else { return }
        inspectorFile = nil
    }

    /// Carries out a held-back intent once the edits were saved or discarded.
    public func performFilePreviewIntent(_ intent: PendingFilePreview) {
        pendingFilePreview = nil
        filePreviewIsDirty = false
        switch intent {
        case .open(let file): inspectorFile = file
        case .close: inspectorFile = nil
        }
    }

    /// Discards the unsaved edits and carries out the pending intent.
    public func resolvePendingFilePreview() {
        guard let intent = pendingFilePreview else { return }
        performFilePreviewIntent(intent)
    }

    /// Keeps the current file and its edits.
    public func cancelPendingFilePreview() {
        pendingFilePreview = nil
    }

    /// Opens the Files tab and asks the file tree to focus its search field.
    public func requestFileSearch() {
        showInspectorTab(.files)
        fileSearchTrigger &+= 1
    }

    /// Returns true once per file search request that has not been served yet.
    public func takeFileSearchRequest() -> Bool {
        guard servedFileSearchTrigger != fileSearchTrigger else { return false }
        servedFileSearchTrigger = fileSearchTrigger
        return true
    }

    // MARK: - Attachment Helpers

    public func addAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
    }

    public func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }
}
