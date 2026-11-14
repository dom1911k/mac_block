import Foundation

/// Classifies a config change as TIGHTENING (applies at once) or LOOSENING (waits for the delay).
/// Anything not clearly tightening counts as loosening, as the spec requires.
public enum ConfigDiff {
    public struct Result {
        public var loosening: [String] = []   // reasons; empty = pure tightening (or no change)
        public var rejected: [String] = []    // changes that are never allowed (lowering the delays)
        public var changed = false
        public var isTightening: Bool { loosening.isEmpty }
    }

    public static func classify(old: IntentConfig, new: IntentConfig) -> Result {
        var r = Result()
        func loose(_ s: String) { r.loosening.append(s) }
        func superset(_ a: [String], _ b: [String]) -> Bool { Set(b).isSubset(of: Set(a)) }   // a ⊇ b
        func limitLE(_ new: Int?, _ old: Int?) -> Bool {          // nil = unlimited
            guard let o = old else { return true }
            guard let n = new else { return false }
            return n <= o
        }

        // The delays themselves can only go up.
        if new.looseningDelayHours < old.looseningDelayHours { r.rejected.append("loosening_delay_hours can't be lowered") }
        if new.disableDelayHours < old.disableDelayHours { r.rejected.append("disable_delay_hours can't be lowered") }

        // Modes
        for m in new.modes {
            guard let o = old.mode(m.id) else { loose("new mode '\(m.name)'"); continue }
            let name = m.name
            if !superset(o.apps.map { $0.bundleId }, m.apps.map { $0.bundleId }) { loose("\(name): more apps") }
            for a in m.apps {
                if let oa = o.apps.first(where: { $0.bundleId == a.bundleId }), oa.teamId != nil, a.teamId != oa.teamId {
                    loose("\(name): app signature check changed")
                }
            }
            if m.isOpenWeb && !o.isOpenWeb { loose("\(name): now open web") }
            if !m.isOpenWeb && !superset(old.domains(for: o), new.domains(for: m)) { loose("\(name): more websites") }
            if !superset(new.blockedDomains(for: m), old.blockedDomains(for: o)) { loose("\(name): fewer blocked websites") }
            if m.minutes > o.minutes { loose("\(name): longer sessions") }
            if !limitLE(m.dailyLimit, o.dailyLimit) { loose("\(name): higher daily limit") }
            if !limitLE(m.weeklyLimit, o.weeklyLimit) { loose("\(name): higher weekly limit") }
            if (m.cooldownMinutes ?? 0) < (o.cooldownMinutes ?? 0) { loose("\(name): shorter cooldown") }
            if (m.startDelaySeconds ?? 0) < (o.startDelaySeconds ?? 0) { loose("\(name): shorter start pause") }
            if new.intentMinWords(for: m) < old.intentMinWords(for: o) { loose("\(name): shorter intent") }
            if m.allowExtension != false && o.allowExtension == false { loose("\(name): extension turned on") }
            if m.schedule != o.schedule { loose("\(name): schedule changed") }
            if o.isEscapeHatch && !m.isEscapeHatch { loose("\(name): escape-hatch steps removed") }
            let ni = m.idleEndMinutes ?? new.idleEndMinutes, oi = o.idleEndMinutes ?? old.idleEndMinutes
            if (oi > 0 && ni == 0) || (oi > 0 && ni > oi) { loose("\(name): longer idle time") }
        }

        // Global lists and switches
        if !superset(old.expand(old.lockedAllowedDomains), new.expand(new.lockedAllowedDomains)) { loose("more websites while locked") }
        if !superset(old.expand(old.sessionAllowedDomains), new.expand(new.sessionAllowedDomains)) { loose("more websites in every session") }
        if !superset(new.expand(new.alwaysBlockedDomains), old.expand(old.alwaysBlockedDomains)) { loose("fewer always-blocked websites") }
        if !superset(new.blocklistFiles, old.blocklistFiles) { loose("a blocklist file was removed") }
        if !superset(old.blocklistExceptions, new.blocklistExceptions) { loose("new blocklist exceptions") }
        if !superset(new.neverAllowedBundleIds, old.neverAllowedBundleIds) { loose("fewer never-allowed apps") }
        if !superset(old.alwaysAllowedBundleIds, new.alwaysAllowedBundleIds) { loose("more always-allowed apps") }
        if !superset(old.systemPathPrefixes, new.systemPathPrefixes) { loose("more system paths allowed") }
        if !superset(new.chromeForbiddenFlags, old.chromeForbiddenFlags) { loose("fewer forbidden Chrome flags") }
        if !superset(new.dohBlockIps, old.dohBlockIps) { loose("fewer blocked DNS servers") }
        if !superset(old.exemptUsers, new.exemptUsers) { loose("new exempt users") }
        if old.forceSafeSearch && !new.forceSafeSearch { loose("SafeSearch turned off") }
        if old.pfRestrictUpstreamToRoot && !new.pfRestrictUpstreamToRoot { loose("DNS restriction turned off") }
        if !old.pfAllowInboundSsh && new.pfAllowInboundSsh { loose("incoming SSH turned on") }
        if new.upstreamDns != old.upstreamDns { loose("different upstream DNS") }
        if (old.idleEndMinutes > 0 && new.idleEndMinutes == 0) || (old.idleEndMinutes > 0 && new.idleEndMinutes > old.idleEndMinutes) {
            loose("longer idle time")
        }
        if new.bedtime != old.bedtime {
            if let ob = old.bedtime, let nb = new.bedtime, ob.start == nb.start, ob.end == nb.end,
               Set(nb.allowedModes).isSubset(of: Set(ob.allowedModes)) {
                // fewer modes at bedtime: tightening
            } else {
                loose("bedtime changed")
            }
        }
        if !superset(new.quietHours.map { "\($0)" }, old.quietHours.map { "\($0)" }) { loose("fewer quiet hours") }
        if new.escapeReasonMinWords < old.escapeReasonMinWords || new.escapeChallengeLength < old.escapeChallengeLength
            || new.escapeWaitMinutes < old.escapeWaitMinutes { loose("easier open session") }
        if new.extensionMinutes > old.extensionMinutes || new.extensionWaitSeconds < old.extensionWaitSeconds
            || new.extensionMinReasonWords < old.extensionMinReasonWords { loose("easier extensions") }
        if new.intentMinWords < old.intentMinWords { loose("shorter intents") }
        for (k, v) in new.flags where v && old.flags[k] != true { loose("'\(k)' turned on") }

        // Everything else: any difference is "ambiguous" → loosening.
        var a = old, b = new
        let handledKeys: [WritableKeyPath<IntentConfig, [String]>] = [
            \.lockedAllowedDomains, \.sessionAllowedDomains, \.alwaysBlockedDomains, \.blocklistFiles, \.blocklistExceptions,
            \.neverAllowedBundleIds, \.alwaysAllowedBundleIds, \.systemPathPrefixes, \.chromeForbiddenFlags, \.dohBlockIps,
            \.exemptUsers, \.upstreamDns,
        ]
        for k in handledKeys { b[keyPath: k] = a[keyPath: k] }
        b.modes = a.modes; b.flags = a.flags; b.domainGroups = a.domainGroups; b.bedtime = a.bedtime; b.quietHours = a.quietHours
        b.forceSafeSearch = a.forceSafeSearch; b.pfRestrictUpstreamToRoot = a.pfRestrictUpstreamToRoot
        b.pfAllowInboundSsh = a.pfAllowInboundSsh; b.idleEndMinutes = a.idleEndMinutes
        b.escapeReasonMinWords = a.escapeReasonMinWords; b.escapeChallengeLength = a.escapeChallengeLength
        b.escapeWaitMinutes = a.escapeWaitMinutes; b.extensionMinutes = a.extensionMinutes
        b.extensionWaitSeconds = a.extensionWaitSeconds; b.extensionMinReasonWords = a.extensionMinReasonWords
        b.intentMinWords = a.intentMinWords; b.warningSeconds = a.warningSeconds
        b.looseningDelayHours = a.looseningDelayHours; b.disableDelayHours = a.disableDelayHours
        a.blocklistSources = []; b.blocklistSources = []   // where lists are downloaded from doesn't loosen anything by itself
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if (try? enc.encode(a)) != (try? enc.encode(b)) { loose("other settings changed") }

        r.changed = (try? enc.encode(old)) != (try? enc.encode(new))
        return r
    }
}
