import Foundation
import Testing
@testable import ClarcCore

// Recently parsed sessions are kept in memory keyed by the session file's size
// and modification date. Sizes here are plain numbers: no large files needed.

private let megabyte: UInt64 = 1024 * 1024
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func stamp(_ size: UInt64, _ date: Date = t0) -> ParsedSessionCache<String>.Stamp {
    .init(size: size, modificationDate: date)
}

@Suite("ParsedSessionCache")
struct ParsedSessionCacheTests {

    @Test func hitWithSameSizeAndDate() {
        var cache = ParsedSessionCache<String>()
        cache.insert("a", for: "s1", stamp: stamp(10))
        #expect(cache.value(for: "s1", stamp: stamp(10)) == "a")
    }

    @Test func missOnDifferentSize() {
        var cache = ParsedSessionCache<String>()
        cache.insert("a", for: "s1", stamp: stamp(10))
        #expect(cache.value(for: "s1", stamp: stamp(11)) == nil)
    }

    @Test func missOnDifferentModificationDate() {
        var cache = ParsedSessionCache<String>()
        cache.insert("a", for: "s1", stamp: stamp(10))
        #expect(cache.value(for: "s1", stamp: stamp(10, t0.addingTimeInterval(1))) == nil)
    }

    @Test func missOnUnknownSid() {
        var cache = ParsedSessionCache<String>()
        cache.insert("a", for: "s1", stamp: stamp(10))
        #expect(cache.value(for: "s2", stamp: stamp(10)) == nil)
    }

    @Test func ninthSessionEvictsLeastRecentlyUsed() {
        var cache = ParsedSessionCache<String>()
        for i in 1...9 {
            cache.insert("v\(i)", for: "s\(i)", stamp: stamp(1))
        }
        #expect(cache.count == 8)
        #expect(!cache.contains("s1"))
        for i in 2...9 {
            #expect(cache.contains("s\(i)"))
        }
    }

    @Test func totalSizeOverLimitEvictsLeastRecentlyUsed() {
        var cache = ParsedSessionCache<String>()
        cache.insert("a", for: "s1", stamp: stamp(100 * megabyte))
        cache.insert("b", for: "s2", stamp: stamp(100 * megabyte))
        cache.insert("c", for: "s3", stamp: stamp(100 * megabyte))
        #expect(!cache.contains("s1"))
        #expect(cache.contains("s2"))
        #expect(cache.contains("s3"))
        #expect(cache.totalBytes == 200 * megabyte)
    }

    @Test func fileLargerThanLimitIsNotStored() {
        var cache = ParsedSessionCache<String>()
        cache.insert("small", for: "s1", stamp: stamp(10))
        cache.insert("huge", for: "s2", stamp: stamp(256 * megabyte + 1))
        #expect(!cache.contains("s2"))
        #expect(cache.value(for: "s2", stamp: stamp(256 * megabyte + 1)) == nil)
        #expect(cache.contains("s1"))
    }

    @Test func accessRefreshesEntry() {
        var cache = ParsedSessionCache<String>()
        for i in 1...8 {
            cache.insert("v\(i)", for: "s\(i)", stamp: stamp(1))
        }
        #expect(cache.value(for: "s1", stamp: stamp(1)) == "v1")
        cache.insert("v9", for: "s9", stamp: stamp(1))
        #expect(cache.contains("s1"))
        #expect(!cache.contains("s2"))
    }

    @Test func reinsertReplacesEntryAndSize() {
        var cache = ParsedSessionCache<String>()
        cache.insert("old", for: "s1", stamp: stamp(10))
        cache.insert("new", for: "s1", stamp: stamp(20))
        #expect(cache.count == 1)
        #expect(cache.totalBytes == 20)
        #expect(cache.value(for: "s1", stamp: stamp(20)) == "new")
    }

    @Test func limitsAreParameters() {
        var cache = ParsedSessionCache<String>(maxEntries: 2, maxTotalBytes: 100)
        cache.insert("a", for: "s1", stamp: stamp(10))
        cache.insert("b", for: "s2", stamp: stamp(10))
        cache.insert("c", for: "s3", stamp: stamp(10))
        #expect(cache.count == 2)
        #expect(!cache.contains("s1"))
        cache.insert("d", for: "s4", stamp: stamp(101))
        #expect(!cache.contains("s4"))
    }
}
