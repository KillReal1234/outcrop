# Outcrop

Outcrop is a native macOS client for the [Claude Code](https://code.claude.com/docs/en/overview) CLI, written in Swift and SwiftUI. It runs the real `claude` command line tool underneath and shows its output in a project-based window with chat, sessions, a file tree, Git status and a terminal. Your `CLAUDE.md` files, skills, MCP servers and slash commands work the same way they do in the terminal.

Outcrop is a fork of [Clarc](https://github.com/ttnear/Clarc) by ttnear.

## Differences from Clarc

1. The approval hook honors the permission rules from Claude Code settings (`~/.claude/settings.json`, `.claude/settings.json` and `.claude/settings.local.json` in the project). A tool call that an allow rule clearly covers, and no deny or ask rule matches, runs without a prompt. Everything else still shows the approval dialog.
2. Plan usage (the 5-hour and 7-day limits) in the status line is off by default. Showing it reads Claude Code's sign-in token from the Keychain and calls Anthropic's usage API. You can turn it on in Settings → General → Plan usage.
3. Its own name, bundle identifier (`io.github.killreal1234.outcrop`) and icon.
4. Its own data folder: `~/Library/Application Support/Outcrop`.
5. Its own update feed (see [Updates](#updates)).

## Features

**Chat**

- Streaming responses with Markdown rendering, tool call results, file diffs and expandable thinking blocks. A stop button is shown while a response is streaming.
- Fork a conversation from any assistant message into a new session; the original session is left as it was.
- Per-session model, permission mode and effort level, chosen from the chat toolbar. Defaults are set in Settings.
- Permission modes Ask, Accept Edits, Plan, Auto and Bypass, matching Claude Code's `--permission-mode` values.
- Effort levels Low, Medium, High, XHigh and Max, plus Auto (the model's default level) and a session-only Ultracode option.
- Model aliases Opus, Sonnet and Haiku, including the 1M context and Opus Plan variants.
- Message queue: messages typed while Claude is responding are queued and can be removed before they are sent.
- Attachments by drag and drop. Paste detects images, file paths, URLs and long text; automatic preview can be turned off for each of these in Settings.
- Built-in and custom slash commands. Built-in commands can be edited or turned off; custom commands can be imported and exported as JSON. Commands that need an interactive terminal, such as `/config` and `/model`, open in a terminal sheet.
- Shortcut buttons for prompts or terminal commands you run often.
- Status line with the project path, model, context usage and total response time. Plan usage limits appear only when the Plan usage setting is on.

**Projects and sessions**

- Several local folders or cloned GitHub repositories, each with its own session history.
- Project tabs; double-click a tab to open the project in its own window. A response keeps streaming in the background when you switch projects.
- Sessions can be pinned, renamed, marked as completed and deleted. Completed sessions can be hidden, and several sessions can be selected for one action.

**Inspector and sidebar**

- File tree with search, a hidden-files toggle, syntax-highlighted preview, editing, and insertion of `@path` references into the message.
- Git status with changed-file counts and the current branch; switch to a local or remote branch from the sidebar.
- Embedded terminal based on SwiftTerm.
- A rich-text memo per project, with headings, lists, checkboxes and links.

**Other**

- GitHub sign-in with the OAuth device flow, token storage in the Keychain, SSH key setup, repository list and cloning. Sign-in uses the OAuth app registered by the Clarc author.
- Plugin marketplace that lists plugins from Anthropic's GitHub repositories, cached for five minutes.
- Six accent themes and separate font size controls for the interface and the messages.
- A focus mode for the chat layout, turned on in Settings.
- System notifications with a preview of the response when a response finishes while the app is in the background. They can be turned off in Settings.
- Interface in English, Korean, Simplified Chinese, Traditional Chinese, Japanese and Spanish.
- A user guide, opened from Settings → General.
- Updates with Sparkle.

## Requirements

- macOS 15.0 or later (the minimum deployment target).
- The [Claude Code CLI](https://code.claude.com/docs/en/overview), installed and signed in.
- To build from source: Xcode with a Swift 6.2 or later toolchain.

## Installation

1. Download `Outcrop-<version>.zip` for the latest version from [Releases](https://github.com/KillReal1234/outcrop/releases).
2. Unzip it and move `Outcrop.app` to the Applications folder.
3. Open `Outcrop.app`.

Releases are signed with an Apple Development certificate and are not notarized, so macOS blocks the first launch:

1. Close the dialog that says the app cannot be verified.
2. Open System Settings → Privacy & Security.
3. In the Security section, click Open Anyway next to Outcrop, then confirm with your password or Touch ID.

After that, Outcrop opens normally.

## Updates

Outcrop checks for updates with [Sparkle](https://sparkle-project.org). The feed is `appcast.xml` on the `fork` branch of this repository, and each update archive is signed with Outcrop's EdDSA key. Sparkle asks whether to check for updates automatically; you can also choose Check for Updates in the app menu.

## Building from source

The Xcode project, scheme and Swift module are still named `Clarc`, and so are the Swift packages `ClarcCore` and `ClarcChatKit` and the source folders. Only the built product is named Outcrop.

The project file carries the signing team of the Clarc author, so a local build needs ad-hoc signing overrides. Run the commands from the repository root.

Build:

```bash
xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

App tests (they launch the app for a moment):

```bash
xcodebuild test -project Clarc.xcodeproj -scheme Clarc -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Package tests:

```bash
swift test --package-path Packages
```

Releases are made with `scripts/release_outcrop.sh`:

```bash
OUTCROP_TEAM_ID=<team id> scripts/release_outcrop.sh <version> [--dry-run] [--build N]
```

The script builds and signs the app, signs the archive for Sparkle, adds an entry to `appcast.xml` and commits the version change. It does not publish anything. It needs the Sparkle tools resolved in `../.derived` (build once with `-derivedDataPath ../.derived`) and Outcrop's update signing key in the login keychain. See the comment at the top of the script for details.

## Project structure

| Path | Purpose |
|------|---------|
| `Clarc/` | macOS app target: app entry point, views, services, resources. |
| `Packages/Sources/ClarcCore/` | Shared models, theme, utilities, Git helpers and Claude Code session storage. |
| `Packages/Sources/ClarcChatKit/` | Chat interface: messages, input bar, slash commands, shortcuts, diffs, status line. |
| `ClarcTests/` | App tests (XCTest). |
| `Packages/Tests/` | Package tests (Swift Testing). |
| `appcast.xml` | Outcrop's Sparkle update feed. |
| `scripts/release_outcrop.sh` | Outcrop's release script. The other scripts in `scripts/` are Clarc's own release tooling. |
| `release_notes/` | Release notes of Clarc versions. |

## License and credits

Outcrop is based on [Clarc](https://github.com/ttnear/Clarc) by ttnear and keeps its license, Apache License 2.0. See [LICENSE](LICENSE).

It uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal and [Sparkle](https://github.com/sparkle-project/Sparkle) for updates.
