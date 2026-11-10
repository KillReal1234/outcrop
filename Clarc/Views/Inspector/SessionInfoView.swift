import SwiftUI
import AppKit
import ClarcCore
import ClarcChatKit

/// Inspector tab with a read-only summary of the session shown in this window:
/// where it runs, the project folder and Git branch, context usage, and the
/// connectors (MCP servers) the CLI reported when the last reply started.
struct SessionInfoView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    /// True while the tab is on screen. The Git branch is only queried then.
    let isVisible: Bool

    /// Branch of `branchPath`, so a branch of the previous project is never shown for the new one.
    @State private var branch: String?
    @State private var branchPath: String?
    /// Bumped when the app becomes active or a reply ends, to read the branch again.
    @State private var branchRefresh = 0

    // Same thresholds as the status line under the input field.
    private static let contextWarningPercent: Double = 70
    private static let contextErrorPercent: Double = 90

    var body: some View {
        Group {
            if let project = windowState.selectedProject {
                sections(for: project)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClaudeTheme.sidebarBackground)
        .task(id: BranchQuery(path: windowState.selectedProject?.path, isVisible: isVisible, refresh: branchRefresh)) {
            guard isVisible, let path = windowState.selectedProject?.path else { return }
            let current = await GitHelper.currentBranch(at: path)
            guard !Task.isCancelled else { return }
            branch = current
            branchPath = path
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isVisible { branchRefresh += 1 }
        }
        .onChange(of: chatBridge.isStreaming) { wasStreaming, isStreaming in
            if wasStreaming && !isStreaming && isVisible { branchRefresh += 1 }
        }
    }

    // MARK: - Sections

    private func sections(for project: Project) -> some View {
        Form {
            Section("Environment") {
                row(icon: "desktopcomputer") {
                    Text("This Mac")
                }
                row(icon: "folder") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: folderName(project.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: abbreviatePath(project.path))
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(project.path)
                }
                row(icon: "arrow.triangle.branch") {
                    branchText(projectPath: project.path)
                }
            }

            Section("Context") {
                contextRow
            }

            Section("Connectors") {
                connectorsContent
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func branchText(projectPath: String) -> some View {
        if branchPath == projectPath {
            if let branch {
                Text(verbatim: branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Not a Git repository")
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
        } else {
            // Not read yet for this project.
            Text(verbatim: "…")
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var contextRow: some View {
        if let pct = chatBridge.lastTurnContextUsedPercentage.map({ min($0, 100) }) {
            HStack(spacing: 10) {
                ProgressView(value: pct, total: 100)
                    .progressViewStyle(.linear)
                    .tint(contextColor(pct))
                    .accessibilityLabel(Text("Context"))
                Text(verbatim: "\(Int(pct))%")
                    .monospacedDigit()
                    .foregroundStyle(contextColor(pct))
            }
        } else {
            Text(verbatim: "--")
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var connectorsContent: some View {
        if let sessionId = windowState.currentSessionId, let connectors = appState.sessionConnectors[sessionId] {
            if connectors.isEmpty {
                Text("No connectors")
                    .foregroundStyle(ClaudeTheme.textSecondary)
            } else {
                ForEach(Array(connectors.enumerated()), id: \.offset) { _, connector in
                    connectorRow(connector)
                }
                Text("Status when the last reply started")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        } else {
            Text("Connectors appear after you send a message")
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
    }

    private func connectorRow(_ connector: SessionConnector) -> some View {
        let look = ConnectorLook(state: connector.state)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: look.icon)
                .foregroundStyle(look.color)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: connector.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let message = connector.message, !message.isEmpty {
                    Text(verbatim: message)
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            look.label
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .lineLimit(1)
        }
        .help(connector.message ?? connector.name)
        .accessibilityElement(children: .combine)
    }

    private func row(icon: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: ClaudeTheme.size(24)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("No session")
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
    }

    // MARK: - Helpers

    private func contextColor(_ pct: Double) -> Color {
        if pct >= Self.contextErrorPercent { return ClaudeTheme.statusError }
        if pct >= Self.contextWarningPercent { return ClaudeTheme.statusWarning }
        return ClaudeTheme.statusSuccess
    }

    private func folderName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

private struct BranchQuery: Equatable {
    let path: String?
    let isVisible: Bool
    let refresh: Int
}

/// Icon, color and text for a connector state. The state is always given as text too, not only by color.
private struct ConnectorLook {
    let icon: String
    let color: Color
    let label: Text

    init(state: SessionConnector.State) {
        switch state {
        case .connected:
            icon = "checkmark.circle.fill"; color = ClaudeTheme.statusSuccess; label = Text("Connected")
        case .failed:
            icon = "exclamationmark.triangle.fill"; color = ClaudeTheme.statusError; label = Text("Failed to connect")
        case .needsAuth:
            icon = "exclamationmark.triangle.fill"; color = ClaudeTheme.statusWarning; label = Text("Needs authentication")
        case .pending:
            // A snapshot from when the reply started: no spinner, the CLI sends no later update.
            icon = "clock"; color = ClaudeTheme.textTertiary; label = Text("Still connecting")
        case .unknown(let status):
            icon = "questionmark.circle"; color = ClaudeTheme.textTertiary; label = Text(verbatim: status)
        }
    }
}
