// The version line is rewritten by scripts/build.sh from the VERSION file.
public enum BuildInfo {
    public static let version = "0.4.1"

    /// Dev builds include `learn`, `emergency-off` and the emergency button on the intent screen.
    /// Release builds (Phase 4) are compiled with INTENTMODE_RELEASE and drop them.
    #if INTENTMODE_RELEASE
    public static let isDevBuild = false
    #else
    public static let isDevBuild = true
    #endif
}

public enum VersionCompare {
    /// Parses "1.2.3" (up to 4 numeric parts). Returns nil for anything else.
    public static func parse(_ s: String) -> [Int]? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        while out.count < 4 { out.append(0) }
        return out
    }

    /// True if `a` is strictly newer than `b`. Unparseable versions are never newer.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        for i in 0..<4 where x[i] != y[i] { return x[i] > y[i] }
        return false
    }
}

import Foundation

public enum TextUtil {
    /// Counts words that contain at least one letter or digit (so "- - -" doesn't count).
    public static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }
}
