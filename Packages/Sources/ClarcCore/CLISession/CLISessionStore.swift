import Foundation
import os

/// Reads CLI-owned session jsonl files under `~/.claude/projects/{enc(cwd)}/`.
/// All disk I/O is done off the main actor; the public API returns Sendable
/// values so callers can hop back to MainActor as needed.
public actor CLISessionStore {

    private let metaStore: SessionMetaStore
    /// Root of the CLI projects tree (`~/.claude/projects` by default).
    /// Injectable so tests can point the store at a temporary directory.
    private let projectsRoot: URL
    private let logger = Logger(subsystem: "com.claudework", category: "CLISessionStore")

    private static let titleSniffLineLimit = 400
    private static let cwdProbeLineLimit = 5
    private static let cwdIndexTTL: TimeInterval = 60
    private static let lastTimestampTailBytes: Int = 16 * 1024

    /// In-memory map: standardized cwd → CLI projects sub-directory URL. Built
    /// from real jsonl content (not from forward encoding), so it survives the
    /// slash/dot collision in the directory-name encoding.
    private var cwdIndex: [String: URL] = [:]
    private var cwdIndexBuiltAt: Date?

    /// Per-sid cache of jsonl sniff results, keyed by sid and invalidated by
    /// file mtime. Avoids re-reading the first ~400 lines of every jsonl every
    /// time the FS watcher fires (which happens on every assistant turn since
    /// our own CLI subprocess is what's writing).
    private struct SniffCacheEntry {
        let mtime: Date
        let result: SniffResult
    }
    private var sniffCache: [String: SniffCacheEntry] = [:]

    private lazy var decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = Self.dateStrategy
        return d
    }()

    /// CLI emits ISO8601 timestamps with fractional seconds (e.g. `2026-04-28T04:55:53.779Z`).
    /// Foundation's `.iso8601` strategy doesn't accept fractional seconds, so we
    /// install a custom strategy that tries with-then-without.
    private static let dateStrategy: JSONDecoder.DateDecodingStrategy = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = withFractional.date(from: s) { return d }
            if let d = plain.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date: \(s)")
        }
    }()

    public init(metaStore: SessionMetaStore, projectsRoot: URL = CLIProjectsDirectory.url) {
        self.metaStore = metaStore
        self.projectsRoot = projectsRoot
    }

    // MARK: - Discovery

    /// Resolve the on-disk projects directory for a Clarc-known cwd. Prefers
    /// the cwd-index (built by reading jsonl content, so it sees through the
    /// lossy slash/dot encoding) and falls back to forward encoding when no
    /// index entry exists yet.
    public func directory(forCwd cwd: String) async -> URL {
        await ensureCwdIndex()
        if let url = cwdIndex[cwd.standardizedCwd()] { return url }
        return projectsRoot.appendingPathComponent(cwd.cliProjectDirName(), isDirectory: true)
    }

    public func sessionFiles(forCwd cwd: String) async -> [URL] {
        let dir = await directory(forCwd: cwd)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { (mtime(of: $0) ?? .distantPast) > (mtime(of: $1) ?? .distantPast) }
    }

    private func ensureCwdIndex() async {
        if let builtAt = cwdIndexBuiltAt,
           Date().timeIntervalSince(builtAt) < Self.cwdIndexTTL {
            return
        }
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            cwdIndex = [:]
            cwdIndexBuiltAt = Date()
            return
        }

        let candidates = dirs.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        let pairs: [(cwd: String, url: URL)] = await withTaskGroup(of: (String, URL)?.self) { group in
            for dir in candidates {
                group.addTask { [self] in
                    guard let cwd = await self.sniffCwd(in: dir) else { return nil }
                    return (cwd.standardizedCwd(), dir)
                }
            }
            var results: [(String, URL)] = []
            for await pair in group {
                if let pair { results.append(pair) }
            }
            return results
        }

        cwdIndex = Dictionary(pairs.map { ($0.cwd, $0.url) }, uniquingKeysWith: { first, _ in first })
        cwdIndexBuiltAt = Date()
        logger.debug("Built CLI cwd index: \(self.cwdIndex.count, privacy: .public) entries")
    }

    private struct CwdProbe: Decodable { let cwd: String? }

    /// Read the most recently touched jsonl in a directory and pluck out the
    /// `cwd` field. Only the first ~5 valid lines are inspected — user/
    /// assistant/system lines all carry cwd, but the very first line is often
    /// a `file-history-snapshot` that doesn't.
    private func sniffCwd(in directory: URL) async -> String? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }
        let sorted = urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { (mtime(of: $0) ?? .distantPast) > (mtime(of: $1) ?? .distantPast) }

        for url in sorted {
            var seen = 0
            do {
                for try await rawLine in url.lines {
                    if seen >= Self.cwdProbeLineLimit { break }
                    seen += 1
                    guard !rawLine.isEmpty,
                          let data = rawLine.data(using: .utf8),
                          let probe = try? decoder.decode(CwdProbe.self, from: data),
                          let cwd = probe.cwd, !cwd.isEmpty else { continue }
                    return cwd
                }
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Project discovery

    /// Working directory recorded in one CLI projects sub-directory, with the
    /// modification date of its newest session file.
    public struct DiscoveredCwd: Sendable, Equatable {
        public let cwd: String
        public let lastActivity: Date
    }

    private static let discoveryHeadBytes = 64 * 1024

    /// Per-directory discovery cache. A directory's cwd never changes, so a
    /// read cwd is kept for the store's lifetime; a directory whose newest file
    /// had no readable cwd is re-read only once a newer session file appears.
    private enum DiscoveryCacheEntry {
        case cwd(String)
        case unreadable(newestFile: URL)
    }
    private var discoveryCache: [URL: DiscoveryCacheEntry] = [:]

    /// The `cwd` of every sub-directory of `~/.claude/projects`, newest
    /// activity first. Only the head of each directory's newest jsonl is read,
    /// and only its `cwd` field is decoded (see `ProjectDiscovery`).
    public func discoveredCwds() -> [DiscoveredCwd] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var result: [DiscoveredCwd] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }
            let newest = files
                .filter { $0.pathExtension == "jsonl" }
                .map { (url: $0, date: mtime(of: $0) ?? .distantPast) }
                .max { $0.date < $1.date }
            guard let newest else { continue }

            let cwd: String?
            switch discoveryCache[dir] {
            case .cwd(let cached):
                cwd = cached
            case .unreadable(let file) where file == newest.url:
                cwd = nil
            default:
                cwd = Self.readCwd(fromHeadOf: newest.url)
                discoveryCache[dir] = cwd.map { .cwd($0) } ?? .unreadable(newestFile: newest.url)
            }
            if let cwd {
                result.append(DiscoveredCwd(cwd: cwd, lastActivity: newest.date))
            }
        }
        return result.sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func readCwd(fromHeadOf file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: discoveryHeadBytes) else { return nil }
        return ProjectDiscovery.cwd(fromSessionFileHead: data)
    }

    // MARK: - Summaries

    /// Fast, sniff-only summary list for a project's CLI sessions. Pass
    /// `metaCache` if you've already loaded the sidecar map for this batch
    /// (avoids N × directory scans when merging summaries across projects).
    public func loadSummaries(
        cwd: String,
        projectId: UUID,
        metaCache: [String: SessionMetaStore.Meta]? = nil
    ) async -> [ChatSession.Summary] {
        let files = await sessionFiles(forCwd: cwd)
        guard !files.isEmpty else { return [] }
        let metaByID: [String: SessionMetaStore.Meta]
        if let metaCache {
            metaByID = metaCache
        } else {
            metaByID = await metaStore.loadAll()
        }

        var summaries: [ChatSession.Summary] = []
        summaries.reserveCapacity(files.count)
        let liveSids = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        sniffCache = sniffCache.filter { liveSids.contains($0.key) }

        for url in files {
            let sid = url.deletingPathExtension().lastPathComponent
            let meta = metaByID[sid] ?? SessionMetaStore.Meta()
            let mtimeDate = mtime(of: url) ?? Date()
            var snippet: SniffResult
            if let cached = sniffCache[sid], cached.mtime == mtimeDate {
                snippet = cached.result
            } else {
                snippet = await sniffSummary(url: url)
                snippet.lastTimestamp = lastTimestamp(in: url)
                sniffCache[sid] = SniffCacheEntry(mtime: mtimeDate, result: snippet)
            }
            let title: String = {
                if let t = meta.title, !t.isEmpty { return t }
                if let t = snippet.latestAITitle, !t.isEmpty { return Self.shortTitle(from: t) }
                if let t = snippet.firstUserText, !t.isEmpty { return Self.shortTitle(from: t) }
                return ChatSession.defaultTitle
            }()
            summaries.append(ChatSession.Summary(
                id: sid,
                projectId: projectId,
                title: title,
                createdAt: snippet.firstTimestamp ?? mtimeDate,
                updatedAt: snippet.lastTimestamp ?? mtimeDate,
                isPinned: meta.isPinned,
                isCompleted: meta.isCompleted,
                model: meta.model,
                effort: meta.effort,
                permissionMode: meta.permissionMode,
                origin: .cliBacked,
                contextPercent: meta.contextPercent,
                totalDurationMs: meta.totalDurationMs
            ))
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Lets a caller pre-load the sidecar map once for a batch of `loadSummaries`
    /// calls (e.g. across all projects on app start).
    public func loadMetaCache() async -> [String: SessionMetaStore.Meta] {
        await metaStore.loadAll()
    }

    private struct SniffResult {
        var firstUserText: String?
        var firstTimestamp: Date?
        var latestAITitle: String?
        var lastTimestamp: Date?
    }

    /// Schema-light decoder for the CLI's `ai-title` jsonl line. Sidesteps
    /// `CLISessionLine` so the renderer doesn't have to grow a case it never
    /// shows. `timestamp` is also decoded here to serve `lastTimestamp(in:)`.
    private struct AITitleLine: Decodable {
        let type: String?
        let aiTitle: String?
        let timestamp: Date?
    }

    private func sniffSummary(url: URL) async -> SniffResult {
        var result = SniffResult()
        var seen = 0
        do {
            for try await rawLine in url.lines {
                if seen >= Self.titleSniffLineLimit { break }
                seen += 1
                guard !rawLine.isEmpty, let data = rawLine.data(using: .utf8) else { continue }

                // ai-title sniff: cheap substring guard avoids paying the JSON
                // decode cost on every line. Multiple ai-title lines may appear
                // as the CLI rewrites the title — keep the most recent.
                if rawLine.contains("\"type\":\"ai-title\""),
                   let title = try? decoder.decode(AITitleLine.self, from: data).aiTitle,
                   !title.isEmpty {
                    result.latestAITitle = title
                    continue
                }

                guard let decoded = try? decoder.decode(CLISessionLine.self, from: data) else { continue }

                switch decoded {
                case .user(let user):
                    if result.firstTimestamp == nil { result.firstTimestamp = user.timestamp }
                    if user.isMeta || user.isSidechain { continue }
                    if result.firstUserText == nil,
                       let text = firstHumanText(from: user.message.content) {
                        result.firstUserText = text
                    }
                case .assistant(let assistant):
                    if result.firstTimestamp == nil { result.firstTimestamp = assistant.timestamp }
                case .skip:
                    continue
                }
            }
        } catch {
            logger.debug("sniffSummary error for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return result
    }

    private func firstHumanText(from content: UserContent) -> String? {
        switch content {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if CLIMetaEnvelope.isEnvelope(trimmed) { return nil }
            return trimmed
        case .parts(let parts):
            for part in parts {
                if case .text(let t) = part, !t.isEmpty { return t }
            }
            return nil
        }
    }

    /// Read the last ~16KB of a jsonl and return the largest `timestamp` field
    /// found. Survives Clarc-side rewrites (PickerExposer, LegacyMigrator) that
    /// would otherwise bump file mtime to "now". Returns nil for files whose
    /// tail contains no timestamped lines (e.g. only metadata) — caller falls
    /// back to mtime.
    private func lastTimestamp(in url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let endOffset: UInt64
        do {
            endOffset = try handle.seekToEnd()
        } catch {
            return nil
        }
        guard endOffset > 0 else { return nil }
        let window = UInt64(Self.lastTimestampTailBytes)
        let startOffset = endOffset > window ? endOffset - window : 0
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else { return nil }
        if startOffset > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        var maxDate: Date?
        for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard sub.contains("\"timestamp\":\"") else { continue }
            let lineData = Data(sub.utf8)
            guard let ts = (try? decoder.decode(AITitleLine.self, from: lineData))?.timestamp
            else { continue }
            maxDate = maxDate.map { max($0, ts) } ?? ts
        }
        return maxDate
    }

    private nonisolated static func shortTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        return String(firstLine.prefix(80))
    }

    // MARK: - Full session load

    private static let loadLogger = Logger(subsystem: "com.claudework", category: "CLISessionStore")

    /// Transcript read from a session jsonl, before Clarc's sidecar metadata
    /// (title, pin, model…) is applied.
    struct ParsedTranscript: Sendable {
        var messages: [ChatMessage]
        var firstTimestamp: Date?
        var latestAITitle: String?
    }

    /// Recently parsed transcripts, keyed by sid and the file's size and
    /// modification date. Sidecar metadata is applied on every load, so a
    /// rename or pin never comes back stale from here.
    private var parsedCache = ParsedSessionCache<ParsedTranscript>()

    /// Parse the full jsonl into a `ChatSession`. Memory footprint is roughly
    /// proportional to rendered content (thinking signatures dropped at decode
    /// time). `projectId` is supplied by the caller because the session jsonl
    /// itself doesn't carry the Clarc project UUID.
    ///
    /// Reading and parsing run off the actor (`readTranscript`), so a large
    /// file doesn't hold up summaries, project discovery or path lookups. An
    /// unchanged file is served from `parsedCache` without reading it.
    public func loadFullSession(
        sid: String,
        cwd: String,
        projectId: UUID
    ) async -> ChatSession? {
        let url = await jsonlURL(sid: sid, cwd: cwd)
        // Stamp the file before reading it: if it grows during the read, the
        // cached transcript holds more than the stamp says and the next load
        // sees a new stamp and parses again — never the other way round.
        let stamp = Self.fileStamp(of: url)
        let transcript: ParsedTranscript
        if let stamp, let cached = parsedCache.value(for: sid, stamp: stamp) {
            transcript = cached
        } else {
            guard let parsed = await Self.readTranscript(at: url) else {
                parsedCache.removeValue(for: sid)
                return nil
            }
            if let stamp {
                parsedCache.insert(parsed, for: sid, stamp: stamp)
            }
            transcript = parsed
        }
        let meta = await metaStore.load(sessionId: sid)
        return Self.makeSession(
            sid: sid,
            projectId: projectId,
            transcript: transcript,
            updatedAt: stamp?.modificationDate ?? mtime(of: url) ?? Date(),
            meta: meta
        )
    }

    // MARK: - Tail load

    /// Parse only the end of the jsonl: at least `minMessages` transcript
    /// messages, or the whole file if it has fewer. Lets a large session show
    /// its latest messages before `loadFullSession` has parsed everything.
    ///
    /// Reads the last `initialWindow` bytes and doubles the window until it
    /// holds enough messages or reaches the start of the file. The partial
    /// first line of a window is dropped; a tool result whose call lies before
    /// the window is dropped by the mapper. Message ids match the full load,
    /// so the tail is exactly the end of the full transcript. Runs off the
    /// actor like the full load, and is never cached.
    public func loadSessionTail(
        sid: String,
        cwd: String,
        projectId: UUID,
        minMessages: Int = 40,
        initialWindow: Int = 512 * 1024
    ) async -> ChatSession? {
        let url = await jsonlURL(sid: sid, cwd: cwd)
        guard let transcript = await Self.readTranscriptTail(
            at: url,
            minMessages: minMessages,
            initialWindow: initialWindow
        ) else { return nil }
        let meta = await metaStore.load(sessionId: sid)
        return Self.makeSession(
            sid: sid,
            projectId: projectId,
            transcript: transcript,
            updatedAt: mtime(of: url) ?? Date(),
            meta: meta
        )
    }

    @concurrent
    nonisolated static func readTranscriptTail(
        at url: URL,
        minMessages: Int,
        initialWindow: Int
    ) async -> ParsedTranscript? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Fix the end once: bytes appended while reading belong to the full load.
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }

        var window = UInt64(max(initialWindow, 1))
        while true {
            let start = end > window ? end - window : 0
            // Read one byte before the window so a window that starts exactly
            // at a line boundary keeps that line.
            let readFrom = start > 0 ? start - 1 : 0
            guard (try? handle.seek(toOffset: readFrom)) != nil,
                  let data = try? handle.read(upToCount: Int(end - readFrom)) else { return nil }

            var body = data[...]
            if start > 0 {
                // Drop the cut first line. It may end inside a UTF-8 sequence,
                // but `\n` never occurs inside one, so the rest is intact.
                guard let newline = body.firstIndex(of: 0x0A) else {
                    window *= 2
                    continue
                }
                body = body[body.index(after: newline)...]
            }

            let transcript = parseTranscript(body)
            if start == 0 || (transcript?.messages.count ?? 0) >= minMessages {
                return transcript
            }
            window *= 2
        }
    }

    /// Size and modification date of a file, or nil if it can't be read.
    nonisolated static func fileStamp(of url: URL) -> ParsedSessionCache<ParsedTranscript>.Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let date = attrs[.modificationDate] as? Date else { return nil }
        return .init(size: size, modificationDate: date)
    }

    /// Bulk-read the whole jsonl and parse it. `@concurrent` keeps the work on
    /// the global executor instead of the store actor.
    ///
    /// The file is read in one shot: the earlier `for try await rawLine in
    /// url.lines` walked it via AsyncBytes, a userland byte-by-byte pipeline
    /// roughly an order of magnitude slower than mmap+split for a finished
    /// session.
    @concurrent
    nonisolated static func readTranscript(at url: URL) async -> ParsedTranscript? {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            loadLogger.debug("loadFullSession read error for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return parseTranscript(data)
    }

    /// Parse jsonl bytes into a transcript. Lines the transcript never shows
    /// are dropped before JSON decoding (`CLISessionLineFilter`). A trailing
    /// partial line (in-flight append) or any other undecodable line is
    /// skipped on its own; the rest of the file still loads. Returns nil when
    /// the data holds no session record at all.
    nonisolated static func parseTranscript(_ data: Data) -> ParsedTranscript? {
        let decoder = makeDecoder()
        var lines: [CLISessionLine] = []
        var sawRecord = false
        var firstTimestamp: Date?
        var latestAITitle: String?

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            forEachLine(in: buffer) { line in
                guard CLISessionLineFilter.needsDecoding(line) else {
                    // Dropped service lines used to decode as `.skip`; keep
                    // counting them so a file of only such lines still loads
                    // as an empty session rather than as a missing one.
                    if looksLikeRecord(line) { sawRecord = true }
                    return
                }
                let lineData = Data(line)

                if CLISessionLineFilter.contains(line, aiTitleMarker),
                   let title = try? decoder.decode(AITitleLine.self, from: lineData).aiTitle,
                   !title.isEmpty {
                    latestAITitle = title
                    return
                }

                guard let decoded = try? decoder.decode(CLISessionLine.self, from: lineData) else { return }
                if firstTimestamp == nil {
                    switch decoded {
                    case .user(let u): firstTimestamp = u.timestamp
                    case .assistant(let a): firstTimestamp = a.timestamp
                    case .skip: break
                    }
                }
                sawRecord = true
                lines.append(decoded)
            }
        }
        guard sawRecord else { return nil }

        return ParsedTranscript(
            messages: CLILineToBlocksMapper.map(lines: lines),
            firstTimestamp: firstTimestamp,
            latestAITitle: latestAITitle
        )
    }

    private static let aiTitleMarker: [UInt8] = Array(#""type":"ai-title""#.utf8)

    /// Calls `body` with each non-empty `\n`-separated line of `buffer`.
    private nonisolated static func forEachLine(
        in buffer: UnsafeRawBufferPointer,
        _ body: (UnsafeRawBufferPointer) -> Void
    ) {
        guard let base = buffer.baseAddress else { return }
        var start = 0
        let count = buffer.count
        while start < count {
            let end: Int
            if let nl = memchr(base + start, 0x0A, count - start) {
                end = base.distance(to: UnsafeRawPointer(nl))
            } else {
                end = count
            }
            if end > start {
                body(UnsafeRawBufferPointer(start: base + start, count: end - start))
            }
            start = end + 1
        }
    }

    /// True if the bytes look like one JSON object (`{…}` up to whitespace).
    private nonisolated static func looksLikeRecord(_ line: UnsafeRawBufferPointer) -> Bool {
        let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
        guard let first = line.first(where: { !isSpace($0) }),
              let last = line.last(where: { !isSpace($0) }) else { return false }
        return first == UInt8(ascii: "{") && last == UInt8(ascii: "}")
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateStrategy
        return decoder
    }

    private nonisolated static func makeSession(
        sid: String,
        projectId: UUID,
        transcript: ParsedTranscript,
        updatedAt: Date,
        meta: SessionMetaStore.Meta
    ) -> ChatSession {
        let messages = transcript.messages
        let title: String = {
            if let t = meta.title, !t.isEmpty { return t }
            if let t = transcript.latestAITitle, !t.isEmpty { return shortTitle(from: t) }
            if let firstUser = messages.first(where: { $0.role == .user })?.content,
               !firstUser.isEmpty {
                return shortTitle(from: firstUser)
            }
            return "New Session"
        }()

        return ChatSession(
            id: sid,
            projectId: projectId,
            title: title,
            messages: messages,
            createdAt: transcript.firstTimestamp ?? updatedAt,
            updatedAt: updatedAt,
            isPinned: meta.isPinned,
            model: meta.model,
            effort: meta.effort,
            permissionMode: meta.permissionMode,
            origin: .cliBacked
        )
    }

    // MARK: - Picker exposure

    /// Rewrite the session's jsonl so it appears in the `claude --resume` picker.
    /// Delegates to ``PickerExposer``; uses the cwd index for accurate URL resolution.
    public func exposeToPicker(sid: String, cwd: String) async {
        await PickerExposer.normalize(jsonlAt: await jsonlURL(sid: sid, cwd: cwd))
    }

    // MARK: - Fork

    /// Branch a session at the line matching `messageTimestamp`/`role`. Copies the
    /// originating jsonl up to that line (plus any immediately-following tool_result
    /// lines that resolve tool_use blocks in the kept assistant turn), rewrites every
    /// `sessionId` field to a fresh UUID, and writes the result as a new jsonl in the
    /// same projects directory. The CLI then accepts the new sid via `--resume`,
    /// preserving full prior context for the fork.
    ///
    /// Returns the new session id, or nil if the source jsonl is unreadable or no
    /// matching line is found.
    public func forkSession(
        fromSid sid: String,
        cwd: String,
        atMessageTimestamp messageTimestamp: Date,
        role: Role
    ) async -> String? {
        let originalURL = await jsonlURL(sid: sid, cwd: cwd)
        let directory = originalURL.deletingLastPathComponent()

        let data: Data
        do {
            data = try Data(contentsOf: originalURL, options: .mappedIfSafe)
        } catch {
            logger.error("forkSession read failed for \(sid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let rawLines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var decoded: [CLISessionLine?] = Array(repeating: nil, count: rawLines.count)
        for (i, raw) in rawLines.enumerated() {
            guard let lineData = raw.data(using: .utf8) else { continue }
            decoded[i] = try? decoder.decode(CLISessionLine.self, from: lineData)
        }

        // Match the last line of the requested role whose timestamp == messageTimestamp.
        // CLI emits sub-second precision timestamps, so collisions across visible turns
        // are vanishingly rare.
        var truncIndex: Int?
        for (i, line) in decoded.enumerated() {
            switch (line, role) {
            case (.user(let u)?, .user):
                if u.isMeta || u.isSidechain { continue }
                if let ts = u.timestamp, ts == messageTimestamp {
                    truncIndex = i
                }
            case (.assistant(let a)?, .assistant):
                if a.isSidechain { continue }
                if let ts = a.timestamp, ts == messageTimestamp {
                    truncIndex = i
                }
            default:
                continue
            }
        }
        guard let truncIndex else {
            logger.error("forkSession: no line matched timestamp for sid \(sid, privacy: .public)")
            return nil
        }

        var endIndex = truncIndex

        // For assistant turns with tool_use blocks, extend through the immediately
        // following tool_result user lines so the resumed conversation has all
        // tool_uses resolved. Stop as soon as we hit fresh user text or another
        // assistant turn — those belong to the post-fork timeline.
        if case .assistant(let assistantLine)? = decoded[truncIndex] {
            var pendingToolIds: Set<String> = []
            for part in assistantLine.message.content {
                if case .toolUse(let id, _, _) = part { pendingToolIds.insert(id) }
            }
            if !pendingToolIds.isEmpty {
                var i = truncIndex + 1
                while i < decoded.count {
                    guard let next = decoded[i] else { i += 1; continue }
                    switch next {
                    case .user(let u):
                        if u.isMeta || u.isSidechain { i += 1; continue }
                        guard case .parts(let parts) = u.message.content else {
                            i = decoded.count  // string content = fresh user input
                            continue
                        }
                        var hasText = false
                        var resolvedAny = false
                        for p in parts {
                            switch p {
                            case .text(let t):
                                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                   !CLIMetaEnvelope.isEnvelope(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    hasText = true
                                }
                            case .toolResult(let id, _, _):
                                if pendingToolIds.contains(id) { resolvedAny = true }
                            case .unknown:
                                continue
                            }
                        }
                        if hasText { i = decoded.count; continue }
                        if resolvedAny { endIndex = i }
                        i += 1
                    case .assistant:
                        i = decoded.count
                    case .skip:
                        i += 1
                    }
                }
            }
        }

        let newSid = UUID().uuidString.lowercased()
        let kept = rawLines[0...endIndex].map { Self.rewriteSessionId(in: $0, to: newSid) }
        let newContent = kept.joined(separator: "\n") + "\n"

        let newURL = directory.appendingPathComponent("\(newSid).jsonl")
        do {
            try newContent.data(using: .utf8)?.write(to: newURL, options: .atomic)
            logger.debug("Forked session \(sid, privacy: .public) → \(newSid, privacy: .public) (\(kept.count, privacy: .public) lines)")
            return newSid
        } catch {
            logger.error("forkSession write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func rewriteSessionId(in line: String, to newSid: String) -> String {
        line.replacingOccurrences(
            of: #""sessionId"\s*:\s*"[^"]*""#,
            with: "\"sessionId\":\"\(newSid)\"",
            options: .regularExpression
        )
    }

    // MARK: - Deletion

    /// Remove the CLI-owned jsonl for a session.
    public func deleteSession(sid: String, cwd: String) async {
        let url = await jsonlURL(sid: sid, cwd: cwd)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
            logger.debug("Deleted CLI session jsonl \(sid, privacy: .public)")
        } catch {
            logger.error("Failed to delete CLI session jsonl \(sid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func jsonlURL(sid: String, cwd: String) async -> URL {
        await directory(forCwd: cwd).appendingPathComponent("\(sid).jsonl")
    }

    // MARK: - External activity detection (S2)

    /// True if the session's jsonl was modified within the given window — a
    /// loose proxy for "another claude process is writing to it right now".
    /// nonisolated for fast `send()`-time checks. Forward-encoding only; the
    /// cwd index is reachable but would require an actor hop, and this is a
    /// best-effort warning anyway.
    public nonisolated func detectExternalActivity(
        sid: String,
        cwd: String,
        withinSeconds window: TimeInterval
    ) -> Bool {
        let url = projectsRoot.appendingPathComponent(cwd.cliProjectDirName(), isDirectory: true)
            .appendingPathComponent("\(sid).jsonl")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(mtime) < window
    }

    // MARK: - Helpers

    private nonisolated func mtime(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Common envelope detection for CLI-internal text wrapped in `<...>` tags
/// (system reminders, slash-command echoes, local-command caveats, background
/// task notifications, custom slash-command expansions). Used by both jsonl
/// summary sniffing and full mapping.
public enum CLIMetaEnvelope {
    public static func isEnvelope(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("<local-command-caveat>")
            || trimmed.hasPrefix("<local-command-stdout>")
            || trimmed.hasPrefix("<command-name>")
            || trimmed.hasPrefix("<command-message>")
            || trimmed.hasPrefix("<command-args>")
            || trimmed.hasPrefix("<system-reminder>")
            || trimmed.hasPrefix("<task-notification>") {
            return true
        }
        // Custom slash-command expansions: CLI wraps a user-defined command's
        // template in <{name}-command>...</{name}-command> when the user runs
        // it. The tag name varies per command, so pattern-match on the suffix.
        if trimmed.hasPrefix("<"),
           let endIdx = trimmed.firstIndex(of: ">") {
            let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<endIdx]
            if !tag.contains(" ") && tag.hasSuffix("-command") {
                return true
            }
        }
        return false
    }

    /// Detect the model's no-op-turn marker — emitted when a turn arrived
    /// without a user prompt (e.g. ScheduleWakeup, hook-driven re-entry).
    /// Renders as a noisy empty bubble in the chat UI; callers strip it.
    public static func isNoResponseRequested(_ trimmed: String) -> Bool {
        trimmed == "No response requested." || trimmed == "No response requested"
    }
}
