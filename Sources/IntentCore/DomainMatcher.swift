import Foundation

/// Domain list matching.
///
/// Entry syntax (used everywhere in config.json):
///   "claude.ai"        → claude.ai and every subdomain (*.claude.ai)
///   "*.claude.ai"      → same as above
///   "=docs.google.com" → exactly docs.google.com, no subdomains
///   "*"                → everything (used internally for learn mode)
public struct DomainMatcher {
    private var suffixes = Set<String>()
    private var exact = Set<String>()
    public private(set) var matchesEverything = false

    public init(entries: [String]) {
        for raw in entries { add(raw) }
    }

    public init() {}

    public var isEmpty: Bool { suffixes.isEmpty && exact.isEmpty && !matchesEverything }
    public var count: Int { suffixes.count + exact.count }

    public mutating func add(_ raw: String) {
        var e = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if e.isEmpty || e.hasPrefix("#") { return }
        if e == "*" { matchesEverything = true; return }
        var isExact = false
        if e.hasPrefix("=") { isExact = true; e.removeFirst() }
        if e.hasPrefix("*.") { e.removeFirst(2) }
        e = DomainMatcher.normalize(e)
        guard !e.isEmpty else { return }
        if isExact { exact.insert(e) } else { suffixes.insert(e) }
    }

    public static func normalize(_ name: String) -> String {
        var n = name.lowercased()
        while n.hasSuffix(".") { n.removeLast() }
        return n
    }

    public func matches(_ name: String) -> Bool {
        if matchesEverything { return true }
        let n = DomainMatcher.normalize(name)
        if n.isEmpty { return false }
        if exact.contains(n) { return true }
        if suffixes.isEmpty { return false }
        var candidate = Substring(n)
        while true {
            if suffixes.contains(String(candidate)) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }

    /// Parses a hosts-format or plain domain list file ("0.0.0.0 example.com", "example.com", "# comment").
    public static func entries(fromListFile text: String) -> [String] {
        var out: [String] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var l = line
            if let hash = l.firstIndex(of: "#") { l = l[..<hash] }
            let parts = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let last = parts.last else { continue }
            let name = String(last)
            if parts.count >= 2 || name.contains(".") {
                if name == "localhost" || name.hasSuffix(".localdomain") || name == "0.0.0.0" { continue }
                out.append(name)
            }
        }
        return out
    }
}
