import Foundation

/// In-memory cache of recently parsed session files.
///
/// An entry is valid only while the session file keeps the exact size and
/// modification date it had when parsed. The CLI only appends to session
/// files, so any change to a file changes its size and misses the cache.
///
/// Bounded by entry count and by the summed size of the cached files (a
/// proxy for the memory the parsed transcripts hold). When either limit is
/// exceeded, the least recently used entries are evicted. A file larger than
/// the size limit is never stored.
public struct ParsedSessionCache<Value> {

    /// Size and modification date of a session file.
    public struct Stamp: Equatable, Sendable {
        public let size: UInt64
        public let modificationDate: Date

        public init(size: UInt64, modificationDate: Date) {
            self.size = size
            self.modificationDate = modificationDate
        }
    }

    private struct Entry {
        let stamp: Stamp
        let value: Value
        var lastUse: UInt64
    }

    public let maxEntries: Int
    public let maxTotalBytes: UInt64

    private var entries: [String: Entry] = [:]
    private var useCounter: UInt64 = 0

    public init(maxEntries: Int = 8, maxTotalBytes: UInt64 = 256 * 1024 * 1024) {
        self.maxEntries = maxEntries
        self.maxTotalBytes = maxTotalBytes
    }

    public var count: Int { entries.count }

    /// Summed file size of all cached entries.
    public var totalBytes: UInt64 {
        entries.values.reduce(0) { $0 + $1.stamp.size }
    }

    public func contains(_ sid: String) -> Bool {
        entries[sid] != nil
    }

    /// The cached value for `sid` if the file still has `stamp`. A hit marks
    /// the entry as most recently used; an entry with a different stamp is
    /// stale and is dropped.
    public mutating func value(for sid: String, stamp: Stamp) -> Value? {
        guard var entry = entries[sid] else { return nil }
        guard entry.stamp == stamp else {
            entries.removeValue(forKey: sid)
            return nil
        }
        entry.lastUse = nextUse()
        entries[sid] = entry
        return entry.value
    }

    /// Store `value` for `sid` parsed from a file with `stamp`, replacing any
    /// previous entry, then evict least recently used entries over the limits.
    public mutating func insert(_ value: Value, for sid: String, stamp: Stamp) {
        entries.removeValue(forKey: sid)
        guard stamp.size <= maxTotalBytes, maxEntries > 0 else { return }
        entries[sid] = Entry(stamp: stamp, value: value, lastUse: nextUse())

        var total = totalBytes
        while entries.count > maxEntries || total > maxTotalBytes {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            entries.removeValue(forKey: oldest.key)
            total -= oldest.value.stamp.size
        }
    }

    public mutating func removeValue(for sid: String) {
        entries.removeValue(forKey: sid)
    }

    private mutating func nextUse() -> UInt64 {
        useCounter += 1
        return useCounter
    }
}
