import Foundation

/// Which build is running, for checking a test device has the latest one.
/// The version comes from Info.plist; the commit, commit count and build
/// time come from BuildInfo.plist, written into the bundle by a build script
/// (see project.yml), so the label changes with every build.
nonisolated enum BuildInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    private struct Extra: Sendable {
        var commit = "unknown"
        var commitCount = 0
        var builtAt: Date?
    }

    private static let extra: Extra = {
        var e = Extra()
        guard let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return e }
        e.commit = dict["commit"] as? String ?? e.commit
        e.commitCount = dict["commitCount"] as? Int ?? 0
        e.builtAt = (dict["builtAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return e
    }()

    /// Short hash, with a trailing "+" when the tree had uncommitted changes.
    static var commit: String { extra.commit }
    static var commitCount: Int { extra.commitCount }
    static var builtAt: Date? { extra.builtAt }

    /// "0.1.0 (57) · a1b2c3d+ · 19 Sep, 17:02"
    static var summary: String {
        var parts = ["Surround \(version) (\(commitCount))", commit]
        if let builtAt {
            parts.append(builtAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
        }
        return parts.joined(separator: " · ")
    }
}
