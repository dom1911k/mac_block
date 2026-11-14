import Foundation

/// An app a mode allows. `team_id` pins the code signature: "apple" for Apple-signed apps,
/// a 10-character Developer Team ID otherwise (find it with `intentmode inspect-app`).
/// Without `team_id` only the bundle ID is checked.
public struct AppRule: Codable, Hashable {
    public var bundleId: String
    public var teamId: String?
    public var note: String?

    public init(bundleId: String, teamId: String? = nil, note: String? = nil) {
        self.bundleId = bundleId; self.teamId = teamId; self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id", teamId = "team_id", note
    }
}

/// An app the intent screen opens when a session starts.
public struct LaunchItem: Codable, Hashable {
    public var bundleId: String
    public var args: [String]?

    public init(bundleId: String, args: [String]? = nil) { self.bundleId = bundleId; self.args = args }

    enum CodingKeys: String, CodingKey { case bundleId = "bundle_id", args }
}

public struct ConditionalDomains: Codable {
    public var flag: String
    public var domains: [String]
}

/// A nightly window in which only some modes can be used, e.g. 23:00–06:00 with only Journal.
public struct Bedtime: Codable, Equatable {
    public var start: String          // "HH:mm", local time
    public var end: String            // "HH:mm"; may be earlier than start (crosses midnight)
    public var allowedModes: [String]

    enum CodingKeys: String, CodingKey { case start, end, allowedModes = "allowed_modes" }

    public init(start: String, end: String, allowedModes: [String]) {
        self.start = start; self.end = end; self.allowedModes = allowedModes
    }

    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
    public var isValid: Bool { Self.minutes(start) != nil && Self.minutes(end) != nil && start != end }

    /// If `date` is inside the window, the time it ends.
    public func endIfActive(at date: Date, calendar cal: Calendar = .current) -> Date? {
        guard let s = Self.minutes(start), let e = Self.minutes(end) else { return nil }
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let active = s < e ? (now >= s && now < e) : (now >= s || now < e)
        guard active else { return nil }
        let startOfDay = cal.startOfDay(for: date)
        var end = cal.date(byAdding: .minute, value: e, to: startOfDay)!
        if end <= date { end = cal.date(byAdding: .day, value: 1, to: end)! }
        return end
    }

    /// The next time the window starts, strictly after `date`.
    public func nextStart(after date: Date, calendar cal: Calendar = .current) -> Date? {
        guard let s = Self.minutes(start) else { return nil }
        var t = cal.date(byAdding: .minute, value: s, to: cal.startOfDay(for: date))!
        if t <= date { t = cal.date(byAdding: .day, value: 1, to: t)! }
        return t
    }
}

public struct BlocklistSource: Codable, Equatable {
    public var url: String
    /// The local file it is merged into (relative to the IntentMode folder), e.g. "blocklists/oisd-nsfw.txt".
    public var file: String
}

public struct ModeConfig: Codable {
    public var id: String
    public var name: String
    public var description: String?
    public var apps: [AppRule]
    public var launch: [LaunchItem]?
    public var domains: [String]
    public var conditionalDomains: [ConditionalDomains]?
    public var minutes: Int
    public var dailyLimit: Int?
    /// Sessions per week (Monday 00:00 to Sunday 23:59, local time).
    public var weeklyLimit: Int?
    public var allowExtension: Bool?
    /// Open web: everything is allowed except the adult blocklist and `blocked_domains`.
    public var openWeb: Bool?
    /// Only used with open_web: names that stay blocked (e.g. "@distraction").
    public var blockedDomains: [String]?
    /// Overrides the global intent_min_words for this mode.
    public var intentMinWords: Int?
    /// A pause between pressing Start and the session opening (can be cancelled).
    public var startDelaySeconds: Int?
    /// After a session of this mode ends, it can't be started again for this many minutes.
    public var cooldownMinutes: Int?
    /// Overrides the global idle_end_minutes for this mode.
    public var idleEndMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, description, apps, launch, minutes
        case domains
        case conditionalDomains = "conditional_domains"
        case dailyLimit = "daily_limit"
        case weeklyLimit = "weekly_limit"
        case allowExtension = "allow_extension"
        case openWeb = "open_web"
        case blockedDomains = "blocked_domains"
        case intentMinWords = "intent_min_words"
        case startDelaySeconds = "start_delay_seconds"
        case cooldownMinutes = "cooldown_minutes"
        case idleEndMinutes = "idle_end_minutes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        apps = try c.decode([AppRule].self, forKey: .apps)
        launch = try c.decodeIfPresent([LaunchItem].self, forKey: .launch)
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        conditionalDomains = try c.decodeIfPresent([ConditionalDomains].self, forKey: .conditionalDomains)
        minutes = try c.decode(Int.self, forKey: .minutes)
        dailyLimit = try c.decodeIfPresent(Int.self, forKey: .dailyLimit)
        weeklyLimit = try c.decodeIfPresent(Int.self, forKey: .weeklyLimit)
        allowExtension = try c.decodeIfPresent(Bool.self, forKey: .allowExtension)
        openWeb = try c.decodeIfPresent(Bool.self, forKey: .openWeb)
        blockedDomains = try c.decodeIfPresent([String].self, forKey: .blockedDomains)
        intentMinWords = try c.decodeIfPresent(Int.self, forKey: .intentMinWords)
        startDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .startDelaySeconds)
        cooldownMinutes = try c.decodeIfPresent(Int.self, forKey: .cooldownMinutes)
        idleEndMinutes = try c.decodeIfPresent(Int.self, forKey: .idleEndMinutes)
    }

    public var isOpenWeb: Bool { openWeb == true }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// config.json. Every key is optional except `modes`; missing keys take the defaults below.
/// Unknown keys (like "_readme") are ignored.
public struct IntentConfig: Codable {
    public var schemaVersion: Int = 1
    public var upstreamDns: [String] = ["1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003"]
    public var dohBlockIps: [String] = []
    public var pfRestrictUpstreamToRoot: Bool = true
    /// Lets you SSH into this Mac (Remote Login) as an emergency way in. Phase 4 turns it off.
    public var pfAllowInboundSsh: Bool = true
    public var intentMinWords: Int = 8
    public var warningSeconds: Int = 120
    public var extensionMinutes: Int = 10
    public var extensionWaitSeconds: Int = 60
    public var extensionMinReasonWords: Int = 5
    public var learnMaxMinutes: Int = 30
    public var appKillGraceSeconds: Int = 5
    public var flags: [String: Bool] = [:]
    public var domainGroups: [String: [String]] = [:]
    public var lockedAllowedDomains: [String] = ["=time.apple.com"]
    public var sessionAllowedDomains: [String] = []
    public var blocklistFiles: [String] = []
    /// Blocked in every mode, including open-web modes and learn (e.g. "@adult_extra", "@bypass").
    public var alwaysBlockedDomains: [String] = []
    /// Exact names to let through even if a blocklist file contains them (false positives).
    public var blocklistExceptions: [String] = []
    /// Downloaded weekly (when reachable) and merged into the blocklist files — entries are only ever added.
    public var blocklistSources: [BlocklistSource] = []
    /// Force SafeSearch for Google, YouTube, Bing and DuckDuckGo at the DNS level.
    public var forceSafeSearch: Bool = true
    /// End a session after this many minutes without keyboard/mouse activity (0 = never).
    public var idleEndMinutes: Int = 5
    public var bedtime: Bedtime?
    public var systemPathPrefixes: [String] = ["/System/Library/", "/Library/Apple/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/"]
    public var alwaysAllowedBundleIds: [String] = []
    public var neverAllowedBundleIds: [String] = ["com.apple.Safari"]
    public var chromeBundleId: String = "com.google.Chrome"
    public var chromeForbiddenFlags: [String] = ["--host-resolver-rules", "--proxy-server", "--proxy-pac-url"]
    public var exemptUsers: [String] = []
    public var modes: [ModeConfig] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case upstreamDns = "upstream_dns"
        case dohBlockIps = "doh_block_ips"
        case pfRestrictUpstreamToRoot = "pf_restrict_upstream_to_root"
        case pfAllowInboundSsh = "pf_allow_inbound_ssh"
        case intentMinWords = "intent_min_words"
        case warningSeconds = "warning_seconds"
        case extensionMinutes = "extension_minutes"
        case extensionWaitSeconds = "extension_wait_seconds"
        case extensionMinReasonWords = "extension_min_reason_words"
        case learnMaxMinutes = "learn_max_minutes"
        case appKillGraceSeconds = "app_kill_grace_seconds"
        case flags
        case domainGroups = "domain_groups"
        case lockedAllowedDomains = "locked_allowed_domains"
        case sessionAllowedDomains = "session_allowed_domains"
        case blocklistFiles = "blocklist_files"
        case alwaysBlockedDomains = "always_blocked_domains"
        case blocklistExceptions = "blocklist_exceptions"
        case blocklistSources = "blocklist_sources"
        case forceSafeSearch = "force_safe_search"
        case idleEndMinutes = "idle_end_minutes"
        case bedtime
        case systemPathPrefixes = "system_path_prefixes"
        case alwaysAllowedBundleIds = "always_allowed_bundle_ids"
        case neverAllowedBundleIds = "never_allowed_bundle_ids"
        case chromeBundleId = "chrome_bundle_id"
        case chromeForbiddenFlags = "chrome_forbidden_flags"
        case exemptUsers = "exempt_users"
        case modes
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IntentConfig()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
        schemaVersion = try v(.schemaVersion, d.schemaVersion)
        upstreamDns = try v(.upstreamDns, d.upstreamDns)
        dohBlockIps = try v(.dohBlockIps, d.dohBlockIps)
        pfRestrictUpstreamToRoot = try v(.pfRestrictUpstreamToRoot, d.pfRestrictUpstreamToRoot)
        pfAllowInboundSsh = try v(.pfAllowInboundSsh, d.pfAllowInboundSsh)
        intentMinWords = try v(.intentMinWords, d.intentMinWords)
        warningSeconds = try v(.warningSeconds, d.warningSeconds)
        extensionMinutes = try v(.extensionMinutes, d.extensionMinutes)
        extensionWaitSeconds = try v(.extensionWaitSeconds, d.extensionWaitSeconds)
        extensionMinReasonWords = try v(.extensionMinReasonWords, d.extensionMinReasonWords)
        learnMaxMinutes = try v(.learnMaxMinutes, d.learnMaxMinutes)
        appKillGraceSeconds = try v(.appKillGraceSeconds, d.appKillGraceSeconds)
        flags = try v(.flags, d.flags)
        domainGroups = try v(.domainGroups, d.domainGroups)
        lockedAllowedDomains = try v(.lockedAllowedDomains, d.lockedAllowedDomains)
        sessionAllowedDomains = try v(.sessionAllowedDomains, d.sessionAllowedDomains)
        blocklistFiles = try v(.blocklistFiles, d.blocklistFiles)
        alwaysBlockedDomains = try v(.alwaysBlockedDomains, d.alwaysBlockedDomains)
        blocklistExceptions = try v(.blocklistExceptions, d.blocklistExceptions)
        blocklistSources = try v(.blocklistSources, d.blocklistSources)
        forceSafeSearch = try v(.forceSafeSearch, d.forceSafeSearch)
        idleEndMinutes = try v(.idleEndMinutes, d.idleEndMinutes)
        bedtime = try c.decodeIfPresent(Bedtime.self, forKey: .bedtime)
        systemPathPrefixes = try v(.systemPathPrefixes, d.systemPathPrefixes)
        alwaysAllowedBundleIds = try v(.alwaysAllowedBundleIds, d.alwaysAllowedBundleIds)
        neverAllowedBundleIds = try v(.neverAllowedBundleIds, d.neverAllowedBundleIds)
        chromeBundleId = try v(.chromeBundleId, d.chromeBundleId)
        chromeForbiddenFlags = try v(.chromeForbiddenFlags, d.chromeForbiddenFlags)
        exemptUsers = try v(.exemptUsers, d.exemptUsers)
        modes = try c.decode([ModeConfig].self, forKey: .modes)
    }

    public static func load(path: String) throws -> IntentConfig {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
            throw ConfigError("Cannot read \(path): \(error.localizedDescription)")
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> IntentConfig {
        let cfg: IntentConfig
        do { cfg = try JSONDecoder().decode(IntentConfig.self, from: data) } catch let e as DecodingError {
            throw ConfigError("config.json is not valid: \(describe(e))")
        }
        let errors = cfg.validate()
        if !errors.isEmpty { throw ConfigError("config.json problems:\n - " + errors.joined(separator: "\n - ")) }
        return cfg
    }

    static func describe(_ e: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch e {
        case .keyNotFound(let k, let ctx): return "missing key '\(k.stringValue)' at \(path(ctx))"
        case .typeMismatch(_, let ctx): return "wrong type at \(path(ctx)): \(ctx.debugDescription)"
        case .valueNotFound(_, let ctx): return "missing value at \(path(ctx))"
        case .dataCorrupted(let ctx): return "invalid JSON: \(ctx.debugDescription) \(ctx.underlyingError.map { "\($0)" } ?? "")"
        @unknown default: return "\(e)"
        }
    }

    public func mode(_ id: String) -> ModeConfig? { modes.first { $0.id == id } }

    /// Expands "@group" references (groups may reference other groups, up to 5 levels).
    public func expand(_ entries: [String], depth: Int = 0) -> [String] {
        var out: [String] = []
        for e in entries {
            let t = e.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("@") {
                guard depth < 5, let g = domainGroups[String(t.dropFirst())] else { continue }
                out.append(contentsOf: expand(g, depth: depth + 1))
            } else {
                out.append(t)
            }
        }
        return out
    }

    /// The full allowlist for a mode: its domains, flag-dependent domains and session-wide domains.
    public func domains(for mode: ModeConfig) -> [String] {
        var raw = mode.domains
        for cd in mode.conditionalDomains ?? [] where flags[cd.flag] == true {
            raw.append(contentsOf: cd.domains)
        }
        raw.append(contentsOf: sessionAllowedDomains)
        return expand(raw)
    }

    /// Names that stay blocked in an open-web mode (expanded).
    public func blockedDomains(for mode: ModeConfig) -> [String] {
        expand(mode.blockedDomains ?? [])
    }

    public func intentMinWords(for mode: ModeConfig) -> Int { mode.intentMinWords ?? intentMinWords }

    public func validate() -> [String] {
        var errs: [String] = []
        if upstreamDns.isEmpty { errs.append("upstream_dns is empty") }
        for ip in upstreamDns + dohBlockIps where !IntentConfig.looksLikeIP(ip) {
            errs.append("'\(ip)' is not an IP address")
        }
        if intentMinWords < 1 { errs.append("intent_min_words must be at least 1") }
        if extensionMinutes < 0 || extensionWaitSeconds < 0 { errs.append("extension values must not be negative") }
        for e in alwaysBlockedDomains where e.hasPrefix("@") && domainGroups[String(e.dropFirst())] == nil {
            errs.append("always_blocked_domains: unknown domain group '\(e)'")
        }
        if let b = bedtime {
            if !b.isValid { errs.append("bedtime: start and end must be different times like \"23:00\"") }
            for id in b.allowedModes where !modes.contains(where: { $0.id == id }) {
                errs.append("bedtime: allowed mode '\(id)' doesn't exist")
            }
        }
        var ids = Set<String>()
        for m in modes {
            if m.id.isEmpty || m.id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                errs.append("mode id '\(m.id)' may only contain letters, digits, _ and -")
            }
            if !ids.insert(m.id).inserted { errs.append("duplicate mode id '\(m.id)'") }
            if m.minutes < 1 || m.minutes > 24 * 60 { errs.append("mode '\(m.id)': minutes must be 1–1440") }
            if let l = m.dailyLimit, l < 0 { errs.append("mode '\(m.id)': daily_limit must not be negative") }
            if let l = m.weeklyLimit, l < 0 { errs.append("mode '\(m.id)': weekly_limit must not be negative") }
            if let d = m.startDelaySeconds, d < 0 || d > 3600 { errs.append("mode '\(m.id)': start_delay_seconds must be 0–3600") }
            if let w = m.intentMinWords, w < 1 { errs.append("mode '\(m.id)': intent_min_words must be at least 1") }
            if m.isOpenWeb && !m.domains.isEmpty { errs.append("mode '\(m.id)': an open_web mode doesn't use 'domains' (use blocked_domains)") }
            if !m.isOpenWeb && m.domains.isEmpty { errs.append("mode '\(m.id)': domains is empty (or set open_web: true)") }
            for e in m.blockedDomains ?? [] where e.hasPrefix("@") && domainGroups[String(e.dropFirst())] == nil {
                errs.append("mode '\(m.id)': unknown domain group '\(e)' in blocked_domains")
            }
            if m.apps.isEmpty { errs.append("mode '\(m.id)': apps is empty") }
            for e in m.domains + (m.conditionalDomains ?? []).flatMap({ $0.domains }) {
                if e.hasPrefix("@") && domainGroups[String(e.dropFirst())] == nil {
                    errs.append("mode '\(m.id)': unknown domain group '\(e)'")
                }
                if e.trimmingCharacters(in: .whitespaces) == "*" {
                    errs.append("mode '\(m.id)': '*' is not allowed in a mode's domains")
                }
            }
        }
        return errs
    }

    public static func looksLikeIP(_ s: String) -> Bool {
        let base = s.split(separator: "/").first.map(String.init) ?? s
        if base.contains(":") {
            return base.allSatisfy { $0.isHexDigit || $0 == ":" } && base.count >= 2
        }
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in Int(p).map { $0 >= 0 && $0 <= 255 } ?? false }
    }
}

/// Edits config.json as raw JSON (used by `learn stop --apply`), keeping unknown keys.
public enum ConfigEditor {
    public static func addDomains(_ domains: [String], toMode modeId: String, path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var modes = root["modes"] as? [[String: Any]],
              let idx = modes.firstIndex(where: { ($0["id"] as? String) == modeId }) else {
            throw ConfigError("mode '\(modeId)' not found in \(path)")
        }
        var list = modes[idx]["domains"] as? [String] ?? []
        for d in domains where !list.contains(d) { list.append(d) }
        modes[idx]["domains"] = list
        root["modes"] = modes
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.copyItem(atPath: path, toPath: path + ".bak-\(stamp)")
        try FileUtil.writeAtomically(out + Data("\n".utf8), to: path, mode: 0o644)
    }
}
