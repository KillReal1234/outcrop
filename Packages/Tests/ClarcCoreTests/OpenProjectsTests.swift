import Foundation
import Testing
@testable import ClarcCore

// The project tab strip shows only open projects. Opening, closing with the
// neighbour selection, pruning and the stored form are pure logic checked here.

private let a = UUID()
private let b = UUID()
private let c = UUID()

@Suite("OpenProjects")
struct OpenProjectsTests {

    @Test func openAppendsWithoutDuplicates() {
        var open = OpenProjects()
        open.open(a)
        open.open(b)
        open.open(a)
        #expect(open.ids == [a, b])
        #expect(open.contains(a))
        #expect(!open.contains(c))
    }

    @Test func closeSelectedMiddle_selectsRight() {
        var open = OpenProjects(ids: [a, b, c])
        #expect(open.close(b, selected: b) == c)
        #expect(open.ids == [a, c])
    }

    @Test func closeSelectedLast_selectsLeft() {
        var open = OpenProjects(ids: [a, b, c])
        #expect(open.close(c, selected: c) == b)
        #expect(open.ids == [a, b])
    }

    @Test func closeSelectedOnly_selectsNothing() {
        var open = OpenProjects(ids: [a])
        #expect(open.close(a, selected: a) == nil)
        #expect(open.ids.isEmpty)
    }

    @Test func closeUnselected_keepsSelection() {
        var open = OpenProjects(ids: [a, b, c])
        #expect(open.close(a, selected: b) == b)
        #expect(open.ids == [b, c])
    }

    @Test func closeNotOpen_keepsSelectionAndList() {
        var open = OpenProjects(ids: [a, b])
        #expect(open.close(c, selected: a) == a)
        #expect(open.ids == [a, b])
    }

    @Test func pruneDropsMissingProjects() {
        var open = OpenProjects(ids: [a, b, c])
        open.prune(existing: [c, a])
        #expect(open.ids == [a, c])
    }

    @Test func storedValueRoundTrip() {
        let open = OpenProjects(ids: [b, a])
        #expect(open.storedValue == [b.uuidString, a.uuidString])
        let restored = OpenProjects(storedValue: open.storedValue, existing: [a, b, c])
        #expect(restored.ids == [b, a])
    }

    @Test func storedValueDropsInvalidAndUnknownIds() {
        let restored = OpenProjects(
            storedValue: ["not-a-uuid", c.uuidString, UUID().uuidString, a.uuidString, a.uuidString],
            existing: [a, b, c]
        )
        #expect(restored.ids == [c, a])
    }

    @Test func noStoredValue_opensAllExisting() {
        let restored = OpenProjects(storedValue: nil, existing: [a, b, c])
        #expect(restored.ids == [a, b, c])
    }

    @Test func emptyStoredValue_opensNothing() {
        let restored = OpenProjects(storedValue: [], existing: [a, b])
        #expect(restored.ids.isEmpty)
    }
}
