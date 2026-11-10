import SwiftUI
import ClarcCore
import ClarcChatKit

// MARK: - FocusedValues

private struct StartNewChatKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// The active window's inspector state and actions, for the View menu.
struct InspectorCommands {
    let isInspectorShown: Bool
    let toggleInspector: () -> Void
    let showFiles: () -> Void
}

private struct InspectorCommandsKey: FocusedValueKey {
    typealias Value = InspectorCommands
}

extension FocusedValues {
    var startNewChat: (() -> Void)? {
        get { self[StartNewChatKey.self] }
        set { self[StartNewChatKey.self] = newValue }
    }

    var inspectorCommands: InspectorCommands? {
        get { self[InspectorCommandsKey.self] }
        set { self[InspectorCommandsKey.self] = newValue }
    }
}

// MARK: - ProjectWindowValue

struct ProjectWindowValue: Codable, Hashable {
    let projectId: UUID
    let instanceId: UUID
}

// MARK: - App

@main
struct ClarcApp: App {
    @State private var appState = AppState()
    @FocusedValue(\.startNewChat) private var startNewChat
    @FocusedValue(\.inspectorCommands) private var inspectorCommands
    private let updateService = UpdateService.shared

    var body: some Scene {
        WindowGroup {
            MainWindowRoot(appState: appState)
                .focusable(false)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    startNewChat?()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button {
                    inspectorCommands?.toggleInspector()
                } label: {
                    if inspectorCommands?.isInspectorShown == true {
                        Text("Hide Inspector")
                    } else {
                        Text("Show Inspector")
                    }
                }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(inspectorCommands == nil)

                Button("Files") {
                    inspectorCommands?.showFiles()
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(inspectorCommands == nil)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updateService.checkForUpdates()
                }
            }
            CommandMenu("Theme") {
                ForEach(AppTheme.allCases) { theme in
                    Button(theme.displayName) {
                        appState.selectedTheme = theme
                    }
                    .disabled(appState.selectedTheme == theme)
                }
            }
        }

        // Dedicated project window — opened on double-click
        WindowGroup(id: "project-window", for: ProjectWindowValue.self) { $value in
            if let id = value?.projectId {
                ProjectWindowRoot(appState: appState, projectId: id)
                    .focusable(false)
            }
        }
        .defaultSize(width: 1000, height: 700)

        Settings {
            SettingsWindowRoot(appState: appState)
        }
    }
}

// MARK: - Main Window Root

struct MainWindowRoot: View {
    let appState: AppState
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    var body: some View {
        MainView()
            .environment(appState)
            .environment(windowState)
            .environment(chatBridge)
            .environment(\.openURL, OpenURLAction { url in
                var finalURL = url
                if url.scheme == nil || url.scheme!.isEmpty {
                    finalURL = URL(string: "https://\(url.absoluteString)") ?? url
                }
                NSWorkspace.shared.open(finalURL)
                return .handled
            })
            .task {
                await appState.initialize()
                appState.setupChatBridge(chatBridge, for: windowState)
                await appState.initializeWindow(windowState)
                await NotificationService.shared.requestAuthorizationIfNeeded()
                NotificationService.shared.onNotificationTapped = { projectId, sessionId in
                    appState.handleNotificationTap(projectId: projectId, sessionId: sessionId, mainWindow: windowState)
                }
            }
    }
}

// MARK: - Settings Window Root

struct SettingsWindowRoot: View {
    let appState: AppState
    @State private var windowState = WindowState()

    var body: some View {
        SettingsView()
            .environment(appState)
            .environment(windowState)
    }
}

// MARK: - Project Window Root

struct ProjectWindowRoot: View {
    let appState: AppState
    let projectId: UUID
    @State private var windowState = WindowState()
    @State private var chatBridge = ChatBridge()

    var body: some View {
        ProjectWindowView()
            .environment(appState)
            .environment(windowState)
            .environment(chatBridge)
            .environment(\.openURL, OpenURLAction { url in
                var finalURL = url
                if url.scheme == nil || url.scheme!.isEmpty {
                    finalURL = URL(string: "https://\(url.absoluteString)") ?? url
                }
                NSWorkspace.shared.open(finalURL)
                return .handled
            })
            .task {
                // AppState is already initialized at this point
                appState.setupChatBridge(chatBridge, for: windowState)
                await appState.initializeWindow(windowState, selectingProjectId: projectId)
                // Apply pending notification navigation (new window case)
                if let sessionId = appState.pendingNotificationSession.removeValue(forKey: projectId) {
                    windowState.currentSessionId = sessionId
                }
            }
            .onAppear { appState.registerOpenProjectWindow(projectId) }
            .onDisappear { appState.unregisterOpenProjectWindow(projectId) }
            // Apply pending notification navigation (already-open window case)
            .onChange(of: appState.pendingNotificationSession[projectId]) { _, sessionId in
                guard let sessionId else { return }
                windowState.currentSessionId = sessionId
                appState.pendingNotificationSession.removeValue(forKey: projectId)
            }
    }
}
