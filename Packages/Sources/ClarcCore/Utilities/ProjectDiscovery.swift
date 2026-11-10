import Foundation

/// Pure helpers for discovering projects from Claude Code session history.
///
/// Each sub-directory of `~/.claude/projects` holds the session files of one
/// working directory. The directory name is a lossy encoding of the path, so
/// the real path is taken from the `cwd` field near the top of a session file.
/// File reading and existence checks live with the callers.
public enum ProjectDiscovery {

    /// How many lines from the top of a session file are inspected for `cwd`.
    public static let headLineLimit = 50

    /// System temporary directories whose sessions never become projects.
    public static let systemTemporaryDirectories = ["/tmp", "/private/tmp", "/private/var/folders"]

    private struct CwdProbe: Decodable { let cwd: String? }

    /// The first non-empty `cwd` among the first `headLineLimit` lines of a
    /// session file. Lines that are not valid JSON (including a truncated last
    /// line) are skipped. Nothing else in the file is decoded.
    public static func cwd(fromSessionFileHead data: Data) -> String? {
        let decoder = JSONDecoder()
        var inspected = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            guard inspected < headLineLimit else { break }
            inspected += 1
            guard !line.isEmpty,
                  let probe = try? decoder.decode(CwdProbe.self, from: Data(line)),
                  let cwd = probe.cwd, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// Whether a session's working directory may become a project. Rejects
    /// temporary directories (system ones plus `temporaryDirectories`), Claude
    /// Desktop scratch workspaces under `home`, and `.claude/worktrees` checkouts.
    public static func isCandidate(path: String, home: String, temporaryDirectories: [String] = []) -> Bool {
        guard path.hasPrefix("/") else { return false }
        // `standardizingPath` drops a leading `/private` when the shorter path
        // exists, so compare both the literal and the standardized forms.
        let standardized = path.standardizedCwd()
        let forms = Set([trimmingTrailingSlashes(path), standardized])

        let scratch = (home as NSString).appendingPathComponent("Library/Application Support/Claude/scratch-workspaces")
        let excludedRoots = systemTemporaryDirectories + temporaryDirectories + [scratch]
        for root in excludedRoots where !root.isEmpty {
            let rootForms = Set([trimmingTrailingSlashes(root), root.standardizedCwd()])
            for form in forms {
                for rootForm in rootForms where isPath(form, inside: rootForm) { return false }
            }
        }

        let components = (standardized as NSString).pathComponents
        for index in components.indices.dropLast() where components[index] == ".claude" && components[index + 1] == "worktrees" {
            return false
        }
        return true
    }

    /// Standardized candidate paths, in their original order and without
    /// repeats, that are neither existing projects nor dismissed by the user.
    public static func newProjectPaths(candidates: [String], existing: [String], dismissed: [String]) -> [String] {
        var seen = Set(existing.map { $0.standardizedCwd() })
        seen.formUnion(dismissed.map { $0.standardizedCwd() })
        var result: [String] = []
        for candidate in candidates {
            let path = candidate.standardizedCwd()
            if seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var s = path
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
