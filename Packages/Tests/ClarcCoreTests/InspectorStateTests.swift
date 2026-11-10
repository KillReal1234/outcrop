import Foundation
import Testing
@testable import ClarcCore

// The inspector panel shows file previews. Every way of opening a file goes
// through WindowState, which also holds back a file switch or a close while
// the preview has unsaved edits.

private func file(_ name: String) -> PreviewFile {
    PreviewFile(path: "/tmp/project/\(name)", name: name)
}

@MainActor
struct InspectorStateTests {

    @Test func tabsAreOrderedSessionTerminalFilesMemo() {
        #expect(InspectorTab.allCases == [.session, .terminal, .files, .memo])
    }

    @Test func defaultTabIsSession() {
        #expect(WindowState().inspectorTab == .session)
    }

    @Test func openingAFileShowsItInTheFilesTab() {
        let state = WindowState()
        state.inspectorTab = .memo

        state.openFilePreview(file("a.swift"))

        #expect(state.inspectorFile?.path == "/tmp/project/a.swift")
        #expect(state.inspectorTab == .files)
        #expect(state.showInspector)
    }

    @Test func openingAnotherFileReplacesThePreview() {
        let state = WindowState()
        state.openFilePreview(file("a.swift"))

        state.openFilePreview(file("b.swift"))

        #expect(state.inspectorFile?.path == "/tmp/project/b.swift")
        #expect(state.showInspector)
        #expect(state.pendingFilePreview == nil)
    }

    @Test func unsavedEditsHoldBackAFileSwitch() {
        let state = WindowState()
        state.openFilePreview(file("a.swift"))
        state.filePreviewIsDirty = true
        state.inspectorTab = .terminal
        state.showInspector = false

        state.openFilePreview(file("b.swift"))

        #expect(state.inspectorFile?.path == "/tmp/project/a.swift")
        guard case .open(let pending) = state.pendingFilePreview else {
            Issue.record("expected a pending open, got \(String(describing: state.pendingFilePreview))")
            return
        }
        #expect(pending.path == "/tmp/project/b.swift")
        #expect(state.inspectorTab == .files)
        #expect(state.showInspector)
    }

    @Test func reopeningTheSameFileWithUnsavedEditsAsksNothing() {
        let state = WindowState()
        state.openFilePreview(file("a.swift"))
        state.filePreviewIsDirty = true

        state.openFilePreview(file("a.swift"))

        #expect(state.pendingFilePreview == nil)
        #expect(state.inspectorFile?.path == "/tmp/project/a.swift")
    }

    @Test func closingWithoutUnsavedEditsClearsThePreview() {
        let state = WindowState()
        state.openFilePreview(file("a.swift"))

        state.closeFilePreview()

        #expect(state.inspectorFile == nil)
        #expect(state.pendingFilePreview == nil)
    }

    @Test func closingWithUnsavedEditsIsHeldBack() {
        let state = WindowState()
        state.openFilePreview(file("a.swift"))
        state.filePreviewIsDirty = true

        state.closeFilePreview()

        #expect(state.inspectorFile?.path == "/tmp/project/a.swift")
        guard case .close = state.pendingFilePreview else {
            Issue.record("expected a pending close, got \(String(describing: state.pendingFilePreview))")
            return
        }
    }

    @Test func discardingAppliesAPendingSwitch() {
        let state = WindowState()
        state.openFilePreview(file("a.swift"))
        state.filePreviewIsDirty = true
        state.openFilePreview(file("b.swift"))

        state.resolvePendingFilePreview()

        #expect(state.inspectorFile?.path == "/tmp/project/b.swift")
        #expect(state.pendingFilePreview == nil)
        #expect(!state.filePreviewIsDirty)
    }

    @Test func discardingAppliesAPendingClose() {
        let state = WindowState()
        state.openFilePreview(file("a.swift"))
        state.filePreviewIsDirty = true
        state.closeFilePreview()

        state.resolvePendingFilePreview()

        #expect(state.inspectorFile == nil)
        #expect(state.pendingFilePreview == nil)
        #expect(!state.filePreviewIsDirty)
    }

    @Test func performingACapturedIntentAppliesIt() {
        // Save captures the intent before the dialog closes, because closing
        // the dialog cancels the pending intent before the save finishes.
        let state = WindowState()
        state.openFilePreview(file("a.swift"))
        state.filePreviewIsDirty = true
        state.openFilePreview(file("b.swift"))
        let intent = state.pendingFilePreview
        state.cancelPendingFilePreview()

        state.performFilePreviewIntent(intent!)

        #expect(state.inspectorFile?.path == "/tmp/project/b.swift")
        #expect(state.pendingFilePreview == nil)
        #expect(!state.filePreviewIsDirty)
    }

    @Test func cancellingKeepsTheCurrentFile() {
        let state = WindowState()
        state.openFilePreview(file("a.swift"))
        state.filePreviewIsDirty = true
        state.openFilePreview(file("b.swift"))

        state.cancelPendingFilePreview()

        #expect(state.inspectorFile?.path == "/tmp/project/a.swift")
        #expect(state.pendingFilePreview == nil)
        #expect(state.filePreviewIsDirty)
    }

    @Test func projectSwitchClosesOnlyACleanPreview() {
        let clean = WindowState()
        clean.openFilePreview(file("a.swift"))
        clean.closeFilePreviewIfClean()
        #expect(clean.inspectorFile == nil)

        let dirty = WindowState()
        dirty.openFilePreview(file("a.swift"))
        dirty.filePreviewIsDirty = true
        dirty.closeFilePreviewIfClean()
        #expect(dirty.inspectorFile?.path == "/tmp/project/a.swift")
        #expect(dirty.pendingFilePreview == nil)
    }

    @Test func fileSearchRequestOpensFilesAndIsServedOnce() {
        let state = WindowState()
        state.inspectorTab = .memo
        #expect(!state.takeFileSearchRequest())

        state.requestFileSearch()

        #expect(state.inspectorTab == .files)
        #expect(state.showInspector)
        #expect(state.takeFileSearchRequest())
        #expect(!state.takeFileSearchRequest())

        let before = state.fileSearchTrigger
        state.requestFileSearch()
        #expect(state.fileSearchTrigger != before)
        #expect(state.takeFileSearchRequest())
    }

    @Test func showingATabRevealsThePanel() {
        let state = WindowState()
        state.inspectorTab = .memo

        state.showInspectorTab(.files)

        #expect(state.inspectorTab == .files)
        #expect(state.showInspector)
    }
}
