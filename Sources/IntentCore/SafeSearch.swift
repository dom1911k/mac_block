import Foundation

/// Forces SafeSearch at the DNS level: the search engines' official "safe" hostnames are returned
/// in place of the normal ones. This works in every browser and can't be switched off in settings.
///   Google     → forcesafesearch.google.com
///   YouTube    → restrict.youtube.com (strict Restricted Mode)
///   Bing       → strict.bing.com
///   DuckDuckGo → safe.duckduckgo.com
public enum SafeSearch {
    private static let youtube: Set<String> = [
        "www.youtube.com", "m.youtube.com", "youtube.com", "youtubei.googleapis.com",
        "youtube.googleapis.com", "www.youtube-nocookie.com",
    ]

    public static func target(for rawName: String) -> String? {
        let name = DomainMatcher.normalize(rawName)
        if youtube.contains(name) { return "restrict.youtube.com" }
        if name == "bing.com" || name == "www.bing.com" { return "strict.bing.com" }
        if name == "duckduckgo.com" || name == "www.duckduckgo.com" { return "safe.duckduckgo.com" }
        // google.<tld> and www.google.<tld> (google.com, google.de, google.co.uk …), but not docs.google.com etc.
        var labels = name.split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        if labels.count >= 2, labels.count <= 3, labels[0] == "google",
           labels.dropFirst().allSatisfy({ $0.count <= 3 && $0.allSatisfy { $0.isLetter } }) {
            return "forcesafesearch.google.com"
        }
        return nil
    }
}
