import Foundation

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func percent(_ f: Double) -> String {
        f.formatted(.percent.precision(.fractionLength(0)))
    }
}

enum PathUtil {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Resolves symlinks (e.g. /var -> /private/var) so the same folder always has the same key.
    static func canonicalDirectory(_ url: URL) -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buf) != nil {
            return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
        }
        return url.standardizedFileURL
    }

    /// Replaces the home folder prefix with "~".
    static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// True when `path` is `ancestor` itself or lies inside it.
    static func isInside(_ path: String, _ ancestor: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    /// Folders that must never be moved away (copying them is still allowed).
    static func moveBlockReason(_ path: String) -> String? {
        let exact: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/usr", "/bin", "/sbin",
            "/private", "/var", "/etc", "/tmp", "/opt", "/cores", home, home + "/Library",
        ]
        if exact.contains(path) { return "\(abbreviate(path)) is a system or top-level folder" }
        for prefix in ["/System", "/usr", "/bin", "/sbin", "/private"] where isInside(path, prefix) {
            return "\(path) is part of macOS"
        }
        if let isVolume = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey]).isVolume, isVolume {
            return "\(path) is the root of a disk"
        }
        return nil
    }
}
