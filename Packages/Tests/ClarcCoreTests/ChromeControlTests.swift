import Testing
@testable import ClarcCore

// Claude in Chrome is enabled with the CLI's `--chrome` flag; its tools are
// auto-approved while the setting is on, except in plan mode.

@Suite("ChromeControl")
struct ChromeControlTests {

    @Test("Enabled setting adds --chrome to the launch arguments")
    func launchArgumentsEnabled() {
        #expect(ChromeControl.launchArguments(enabled: true) == ["--chrome"])
    }

    @Test("Disabled setting adds nothing")
    func launchArgumentsDisabled() {
        #expect(ChromeControl.launchArguments(enabled: false).isEmpty)
    }

    @Test("Tools of the claude-in-chrome server are Chrome tools")
    func chromeToolNames() {
        #expect(ChromeControl.isChromeTool("mcp__claude-in-chrome__navigate"))
    }

    @Test("Other tools are not Chrome tools",
          arguments: ["mcp__claude-in-chromeX__a", "mcp__jira__get_issue", "Bash"])
    func otherToolNames(_ name: String) {
        #expect(!ChromeControl.isChromeTool(name))
    }

    @Test("Chrome tools are auto-approved in every mode except plan",
          arguments: [PermissionMode.default, .acceptEdits, .auto, .bypassPermissions])
    func autoApprovesOutsidePlan(_ mode: PermissionMode) {
        #expect(ChromeControl.autoApproves(toolName: "mcp__claude-in-chrome__computer", enabled: true, mode: mode))
    }

    @Test("Plan mode still asks")
    func planModeAsks() {
        #expect(!ChromeControl.autoApproves(toolName: "mcp__claude-in-chrome__computer", enabled: true, mode: .plan))
    }

    @Test("Disabled setting still asks")
    func disabledAsks() {
        #expect(!ChromeControl.autoApproves(toolName: "mcp__claude-in-chrome__computer", enabled: false, mode: .default))
    }

    @Test("Non-Chrome tools are not affected")
    func otherToolsAsk() {
        #expect(!ChromeControl.autoApproves(toolName: "mcp__jira__get_issue", enabled: true, mode: .default))
        #expect(!ChromeControl.autoApproves(toolName: "Bash", enabled: true, mode: .bypassPermissions))
    }
}
