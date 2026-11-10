import Foundation

/// Claude in Chrome support: the CLI's `--chrome` flag connects Claude Code to the
/// user's Chrome through the Claude extension. The CLI owns the MCP server and the
/// bridge; the app only adds the flag and decides which tool calls skip approval.
public enum ChromeControl {

    /// UserDefaults key of the "Let Claude use Chrome" setting.
    public static let settingKey = "chromeControlEnabled"

    /// Name prefix of the tools exposed by the CLI's `claude-in-chrome` MCP server.
    public static let toolNamePrefix = "mcp__claude-in-chrome__"

    /// Extra CLI arguments for a launch. Nothing is added when the setting is off,
    /// so a Chrome default enabled inside the CLI itself is left untouched.
    public static func launchArguments(enabled: Bool) -> [String] {
        enabled ? ["--chrome"] : []
    }

    public static func isChromeTool(_ toolName: String) -> Bool {
        toolName.hasPrefix(toolNamePrefix)
    }

    /// Chrome tools run without an approval prompt while the setting is on,
    /// except in plan mode, where they are confirmed like any other tool.
    public static func autoApproves(toolName: String, enabled: Bool, mode: PermissionMode) -> Bool {
        enabled && mode != .plan && isChromeTool(toolName)
    }
}
