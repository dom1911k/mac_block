import Foundation
import IntentCore

/// Owns the pf anchor and its <im_allow> table.
///
/// - Enables pf with a reference token (`pfctl -E`) so we coexist with anything else using pf.
/// - Loads our rules as a child of Apple's "com.apple/*" anchor; /etc/pf.conf is never edited.
/// - Adds resolver answers to <im_allow> *before* the DNS reply is sent, and expires them later.
/// - A watchdog re-enables pf and reloads the anchor if anything removes them.
final class PFManager {
    private let q = DispatchQueue(label: "intentmode.pf")
    private let pfctl = "/sbin/pfctl"
    private let anchor = Paths.pfAnchor
    private let table = Paths.pfTable

    private var config: IntentConfig
    private var restrictToRoot: Bool
    private var upstreamVerified = false
    private var lastVerifyAttempt = Date.distantPast
    private var entries: [String: Date] = [:]
    private var generation = 0
    /// Called (on the pf queue) after the anchor had to be reloaded, which empties the table.
    var onTableLost: (() -> Void)?

    init(config: IntentConfig) {
        self.config = config
        self.restrictToRoot = config.pfRestrictUpstreamToRoot
    }

    // MARK: setup

    func setup() {
        q.sync {
            enablePF()
            ensureMainRuleset()
            loadAnchor()
        }
    }

    func updateConfig(_ c: IntentConfig) {
        q.sync {
            let changed = c.upstreamDns != config.upstreamDns || c.dohBlockIps != config.dohBlockIps
                || c.pfRestrictUpstreamToRoot != config.pfRestrictUpstreamToRoot
                || c.pfAllowInboundSsh != config.pfAllowInboundSsh
            config = c
            if changed {
                restrictToRoot = c.pfRestrictUpstreamToRoot
                upstreamVerified = false
                loadAnchor()
                onTableLost?()
            }
        }
    }

    private func enablePF() {
        let r = run(pfctl, ["-E"])
        let text = r.out + r.err
        var newToken: String?
        if let range = text.range(of: #"Token\s*:\s*(\d+)"#, options: .regularExpression) {
            newToken = text[range].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        }
        let oldToken = (try? String(contentsOfFile: Paths.pfToken, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = newToken {
            try? FileUtil.writeAtomically(Data(t.utf8), to: Paths.pfToken, mode: 0o600)
            // Release the previous token only after taking the new one, so pf never drops to zero references.
            if let old = oldToken, !old.isEmpty, old != t { run(pfctl, ["-X", old]) }
        } else {
            Log.warn("pfctl -E gave no token: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func ensureMainRuleset() {
        let hook = "anchor \"com.apple/*\""
        if run(pfctl, ["-s", "rules"]).out.contains(hook) { return }
        Log.warn("main pf ruleset lacks the com.apple anchor hook; loading /etc/pf.conf")
        run(pfctl, ["-f", "/etc/pf.conf"])
        if run(pfctl, ["-s", "rules"]).out.contains(hook) { return }
        Log.warn("/etc/pf.conf did not restore it; loading Apple's default main ruleset")
        run(pfctl, ["-f", "-"], input: PFRules.appleDefaultMain)
    }

    private func loadAnchor() {
        let text = PFRules.anchor(config: config, restrictUpstreamToRoot: restrictToRoot)
        var r = run(pfctl, ["-a", anchor, "-f", "-"], input: text)
        if !r.ok && restrictToRoot {
            Log.warn("pf rejected the 'user root' rule (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))); loading without it")
            restrictToRoot = false
            r = run(pfctl, ["-a", anchor, "-f", "-"], input: PFRules.anchor(config: config, restrictUpstreamToRoot: false))
        }
        if r.ok {
            Log.info("pf anchor \(anchor) loaded (upstream DNS restricted to root: \(restrictToRoot))")
        } else {
            Log.error("FAILED to load pf anchor: \(r.err)")
        }
        entries.removeAll()
    }

    // MARK: table

    /// Adds resolver answers to the allow table. Answers from an older policy generation are ignored.
    func allow(_ addrs: [DNSMessage.Address], generation g: Int) {
        q.sync {
            guard g == generation else { return }
            let now = Date()
            var fresh: [String] = []
            for a in addrs {
                // Keep entries a bit longer than the TTL: browsers cache answers beyond it.
                let expiry = now.addingTimeInterval(max(Double(a.ttl), 300) + 300)
                if let e = entries[a.ip], e > now {
                    if expiry > e { entries[a.ip] = expiry }
                } else {
                    entries[a.ip] = expiry
                    fresh.append(a.ip)
                }
            }
            guard !fresh.isEmpty else { return }
            let r = run(pfctl, ["-a", anchor, "-t", table, "-T", "add"] + fresh)
            if !r.ok {
                Log.error("pf table add failed: \(r.err)")
                fresh.forEach { entries[$0] = nil }
            }
        }
    }

    /// Empties the table and kills all existing connections. Called on every session start/end.
    func reset(generation g: Int) {
        q.sync {
            generation = g
            entries.removeAll()
            run(pfctl, ["-a", anchor, "-t", table, "-T", "flush"])
            run(pfctl, ["-F", "states"])
        }
    }

    /// Removes expired addresses. Existing connections keep working (pf keeps their state).
    func expire() {
        q.async {
            let now = Date()
            let dead = self.entries.filter { $0.value < now }.map { $0.key }
            guard !dead.isEmpty else { return }
            var i = 0
            while i < dead.count {
                let chunk = Array(dead[i..<min(i + 200, dead.count)])
                run(self.pfctl, ["-a", self.anchor, "-t", self.table, "-T", "delete"] + chunk)
                i += 200
            }
            dead.forEach { self.entries[$0] = nil }
        }
    }

    // MARK: watchdog

    func watchdog() {
        q.async {
            if !run(self.pfctl, ["-s", "info"]).out.contains("Status: Enabled") {
                Log.warn("pf was disabled by something; re-enabling")
                self.enablePF()
            }
            if !run(self.pfctl, ["-a", self.anchor, "-s", "rules"]).out.contains("block return out") {
                Log.warn("pf anchor was missing; reloading")
                self.ensureMainRuleset()
                self.loadAnchor()
                self.onTableLost?()
            }
            if !self.upstreamVerified { self.verifyUpstream() }
        }
    }

    /// Checks that the daemon (root) can reach the upstream DNS servers through our rules.
    /// If it only works without the "user root" restriction, that restriction is dropped.
    private func verifyUpstream() {
        guard Date().timeIntervalSince(lastVerifyAttempt) > 60 else { return }
        lastVerifyAttempt = Date()
        // No default route = offline; nothing to learn from a failed probe.
        guard run("/sbin/route", ["-n", "get", "default"]).ok else { return }
        let probe = DNSMessage.makeQuery(id: UInt16.random(in: 1...0xFFFE), name: "apple.com", qtype: DNSMessage.typeA)
        let ok = { Upstream.query(probe, servers: self.config.upstreamDns, timeout: 2) != nil }
        if ok() { upstreamVerified = true; return }
        guard restrictToRoot else { return } // probably offline; try again later
        restrictToRoot = false
        loadAnchor()
        if ok() {
            Log.warn("upstream DNS only works without the 'user root' pf rule on this macOS; running without it")
            upstreamVerified = true
            onTableLost?()
        } else {
            restrictToRoot = config.pfRestrictUpstreamToRoot
            loadAnchor()
            onTableLost?()
        }
    }
}
