import Foundation

/// Ordered set of projects shown as tabs in the project tab strip. Closing a
/// tab hides it from the strip; the project itself stays in the project list.
public struct OpenProjects: Equatable, Sendable {

    /// UserDefaults key holding `storedValue`.
    public static let defaultsKey = "openProjectIds"

    public private(set) var ids: [UUID]

    public init(ids: [UUID] = []) {
        var seen = Set<UUID>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    /// Restores the stored list, dropping invalid and unknown ids. With no
    /// stored value (first launch with open tabs), every existing project is open.
    public init(storedValue: [String]?, existing: [UUID]) {
        guard let storedValue else {
            self.init(ids: existing)
            return
        }
        self.init(ids: storedValue.compactMap(UUID.init(uuidString:)))
        prune(existing: existing)
    }

    /// Form written to UserDefaults.
    public var storedValue: [String] { ids.map(\.uuidString) }

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Adds the project at the end of the strip unless it is already open.
    public mutating func open(_ id: UUID) {
        guard !ids.contains(id) else { return }
        ids.append(id)
    }

    /// Removes the project from the strip and returns the project to select
    /// afterwards: the right neighbour, else the left one, else `nil` when the
    /// closed tab was selected; the current selection otherwise.
    @discardableResult
    public mutating func close(_ id: UUID, selected: UUID?) -> UUID? {
        guard let index = ids.firstIndex(of: id) else { return selected }
        ids.remove(at: index)
        guard selected == id else { return selected }
        if index < ids.count { return ids[index] }
        return ids.last
    }

    /// Drops projects that no longer exist.
    public mutating func prune(existing: [UUID]) {
        let existingSet = Set(existing)
        ids.removeAll { !existingSet.contains($0) }
    }
}
