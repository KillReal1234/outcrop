import Foundation

/// Cheap pre-check that tells which session jsonl lines are worth decoding.
///
/// Most bytes of a CLI session file belong to lines the transcript never shows
/// (API request blobs, attachments, file-history snapshots, progress records).
/// Decoding them only to turn them into `.skip` dominates load time, so lines
/// are dropped up front unless their raw text contains an unescaped
/// `"type":"…"` naming a line kind the loader uses.
///
/// This is an allow-list: new service line types the CLI adds are dropped
/// without changes here. The CLI writes compact JSON (`JSON.stringify`), so a
/// chat line always contains its own top-level `"type":"user"` (etc.), while
/// quotes inside string values are escaped (`\"type\":\"user\"`) and never
/// match. A service line that happens to contain a matching nested object is
/// simply decoded and skipped, exactly as before.
public enum CLISessionLineFilter {

    private static let typeKey: [UInt8] = Array(#""type":""#.utf8)

    /// Values (with the closing quote) of the line types the loader decodes:
    /// chat turns (`user`, `assistant`, and the `message` alias that
    /// `CLISessionLine` also maps to an assistant turn) and `ai-title`.
    private static let decodedTypes: [[UInt8]] = ["user", "assistant", "message", "ai-title"]
        .map { Array("\($0)\"".utf8) }

    /// True if the line may be a transcript line (or an `ai-title` line) and
    /// has to be decoded; false if it can be dropped without decoding.
    public static func needsDecoding(_ line: Substring) -> Bool {
        if let result = line.utf8.withContiguousStorageIfAvailable({ buffer in
            needsDecoding(UnsafeRawBufferPointer(buffer))
        }) {
            return result
        }
        return Array(line.utf8).withUnsafeBytes { needsDecoding($0) }
    }

    /// Byte-level variant used when lines are sliced straight out of the file.
    public static func needsDecoding(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        let count = bytes.count
        var offset = 0
        while offset < count {
            guard let hit = typeKey.withUnsafeBytes({ key in
                memmem(base + offset, count - offset, key.baseAddress, key.count)
            }) else { return false }
            let valueStart = base.distance(to: UnsafeRawPointer(hit)) + typeKey.count
            for value in decodedTypes where valueStart + value.count <= count {
                let matches = value.withUnsafeBytes { v in
                    memcmp(base + valueStart, v.baseAddress, v.count) == 0
                }
                if matches { return true }
            }
            offset = valueStart
        }
        return false
    }

    /// Plain byte-substring search over a raw line.
    static func contains(_ bytes: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = bytes.baseAddress, !needle.isEmpty else { return false }
        return needle.withUnsafeBytes { n in
            memmem(base, bytes.count, n.baseAddress, n.count) != nil
        }
    }
}
