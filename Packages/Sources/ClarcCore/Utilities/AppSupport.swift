import Foundation

/// Application Support directory scoped by the running bundle identifier.
/// Production (`com.idealapp.Clarc`) keeps the historical `Clarc` directory.
/// The Outcrop fork (`io.github.killreal1234.outcrop`) uses its own `Outcrop` directory.
/// Any other bundle id (e.g. a dev build at `com.idealapp.Clarc.dev`) maps to
/// `Clarc.<suffix>` so alternate builds never share state with production.
public enum AppSupport {
    public static let bundleScopedURL: URL = {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return root.appendingPathComponent(directoryName, isDirectory: true)
    }()

    private static var directoryName: String {
        directoryName(forBundleID: Bundle.main.bundleIdentifier ?? "com.idealapp.Clarc")
    }

    static func directoryName(forBundleID bundleID: String) -> String {
        if bundleID == "com.idealapp.Clarc" { return "Clarc" }
        if bundleID == "io.github.killreal1234.outcrop" { return "Outcrop" }
        let suffix = bundleID.split(separator: ".").last.map(String.init) ?? "dev"
        return "Clarc.\(suffix)"
    }
}
