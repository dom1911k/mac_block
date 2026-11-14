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
    public var allowExtension: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, description, apps, launch, domains, minutes
        case conditionalDomains = "conditional_domains"
        case dailyLimit = "daily_limit"
        case allowExtension = "allow_extension"
    }
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

    public func validate() -> [String] {
        var errs: [String] = []
        if upstreamDns.isEmpty { errs.append("upstream_dns is empty") }
        for ip in upstreamDns + dohBlockIps where !IntentConfig.looksLikeIP(ip) {
            errs.append("'\(ip)' is not an IP address")
        }
        if intentMinWords < 1 { errs.append("intent_min_words must be at least 1") }
        if extensionMinutes < 0 || extensionWaitSeconds < 0 { errs.append("extension values must not be negative") }
        var ids = Set<String>()
        for m in modes {
            if m.id.isEmpty || m.id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                errs.append("mode id '\(m.id)' may only contain letters, digits, _ and -")
            }
            if !ids.insert(m.id).inserted { errs.append("duplicate mode id '\(m.id)'") }
            if m.minutes < 1 || m.minutes > 24 * 60 { errs.append("mode '\(m.id)': minutes must be 1–1440") }
            if let l = m.dailyLimit, l < 0 { errs.append("mode '\(m.id)': daily_limit must not be negative") }
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
