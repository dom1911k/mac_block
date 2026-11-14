import Foundation

/// Brings an existing config.json up to date with a new version's defaults, without touching your own edits:
///  - adds top-level keys and domain groups that don't exist yet,
///  - adds modes that are new in the defaults (a mode you deleted yourself is never re-added),
///  - applies one-time value changes only where the value is still the OLD default.
public enum ConfigUpgrader {
    public enum Op {
        /// modes[id][key] (or top-level key if mode is nil): change `old` → `new`, only if it's still `old` (nil = missing).
        case setIfEquals(mode: String?, key: String, old: AnyHashable?, new: Any)
        /// Append `value` to the array at top-level `key` if it isn't in there.
        case appendIfMissing(key: String, value: String)
    }

    public struct Migration {
        public let id: String
        public let op: Op
        public let note: String
    }

    public static let migrations: [Migration] = [
        Migration(id: "0.3.1-claude-minutes", op: .setIfEquals(mode: "claude", key: "minutes", old: 30, new: 10),
                  note: "Claude mode: 10 minutes"),
        Migration(id: "0.3.1-claude-daily", op: .setIfEquals(mode: "claude", key: "daily_limit", old: 3, new: 2),
                  note: "Claude mode: 2 per day"),
        Migration(id: "0.3.1-maintenance-corner", op: .setIfEquals(mode: "maintenance", key: "show_as", old: nil, new: "corner"),
                  note: "Maintenance shown as a corner button"),
        Migration(id: "0.3.1-swupdate-locked", op: .appendIfMissing(key: "locked_allowed_domains", value: "@apple_swupdate"),
                  note: "macOS can check for updates while locked"),
        Migration(id: "0.3.1-swupdate-session", op: .appendIfMissing(key: "session_allowed_domains", value: "@apple_swupdate"),
                  note: "macOS can check for updates during sessions"),
    ]

    /// Settings that existed before the upgrader did (0.3.1). If one of these is missing, you removed it on
    /// purpose, so it isn't added back. Only settings introduced later are added automatically.
    static let baselineKeys: Set<String> = ["_readme", "always_allowed_bundle_ids", "always_blocked_domains", "app_kill_grace_seconds", "bedtime", "blocklist_exceptions", "blocklist_files", "blocklist_sources", "chrome_bundle_id", "chrome_forbidden_flags", "doh_block_ips", "domain_groups", "escape_challenge_length", "escape_reason_min_words", "escape_wait_minutes", "exempt_users", "extension_min_reason_words", "extension_minutes", "extension_wait_seconds", "flags", "force_safe_search", "idle_end_minutes", "intent_min_words", "learn_max_minutes", "locked_allowed_domains", "modes", "never_allowed_bundle_ids", "pf_allow_inbound_ssh", "pf_restrict_upstream_to_root", "quiet_hours", "schema_version", "session_allowed_domains", "system_path_prefixes", "upstream_dns", "warning_seconds"]

    public struct State: Codable {
        public var applied: [String] = []
        public var knownDefaultModes: [String]?
        public init() {}
    }

    /// Returns the upgraded config, human-readable notes for each change, and the new upgrade state.
    public static func upgrade(user: [String: Any], defaults: [String: Any], state: State) -> ([String: Any], [String], State) {
        var cfg = user
        var notes: [String] = []
        var st = state

        for (k, v) in defaults where cfg[k] == nil && !baselineKeys.contains(k) {
            cfg[k] = v
            notes.append("added setting '\(k)'")
        }
        if let dg = defaults["_readme"] { cfg["_readme"] = dg }

        var groups = cfg["domain_groups"] as? [String: Any] ?? [:]
        for (k, v) in defaults["domain_groups"] as? [String: Any] ?? [:] where groups[k] == nil {
            groups[k] = v
            notes.append("added domain group '\(k)'")
        }
        cfg["domain_groups"] = groups

        var modes = cfg["modes"] as? [[String: Any]] ?? []
        let defaultModes = defaults["modes"] as? [[String: Any]] ?? []
        let userIds = Set(modes.compactMap { $0["id"] as? String })
        let known = Set(st.knownDefaultModes ?? Array(userIds))
        for m in defaultModes {
            guard let id = m["id"] as? String, !userIds.contains(id), !known.contains(id) else { continue }
            modes.append(m)
            notes.append("added mode '\(m["name"] as? String ?? id)'")
        }
        st.knownDefaultModes = Array(known.union(defaultModes.compactMap { $0["id"] as? String })).sorted()

        for mig in migrations where !st.applied.contains(mig.id) {
            st.applied.append(mig.id)
            switch mig.op {
            case .setIfEquals(let modeId, let key, let old, let new):
                if let modeId {
                    guard let i = modes.firstIndex(where: { ($0["id"] as? String) == modeId }) else { continue }
                    if matches(modes[i][key], old) { modes[i][key] = new; notes.append(mig.note) }
                } else if matches(cfg[key], old) {
                    cfg[key] = new; notes.append(mig.note)
                }
            case .appendIfMissing(let key, let value):
                var arr = cfg[key] as? [String] ?? []
                if !arr.contains(value) { arr.append(value); cfg[key] = arr; notes.append(mig.note) }
            }
        }
        cfg["modes"] = modes
        return (cfg, notes, st)
    }

    static func matches(_ current: Any?, _ old: AnyHashable?) -> Bool {
        guard let old else { return current == nil }
        if let c = current as? Int, let o = old as? Int { return c == o }
        if let c = current as? String, let o = old as? String { return c == o }
        if let c = current as? Bool, let o = old as? Bool { return c == o }
        return false
    }
}
