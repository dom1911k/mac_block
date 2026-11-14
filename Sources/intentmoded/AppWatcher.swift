import Foundation
import Darwin
import Security
import IntentCore

struct AppPolicy {
    let apps: [AppRule]
    let generation: Int
    let label: String
}

/// Quits every GUI app the current mode doesn't allow.
///
/// Endpoint Security needs a paid entitlement, so this polls the process list every 0.5 s
/// (plus instant hints from the intent screen's NSWorkspace launch notifications).
/// Only processes of the logged-in console user that live inside an .app bundle are considered;
/// command-line tools are left alone (the network allowlist still applies to them).
///
/// Decision for an app (by its outermost .app bundle):
///   1. never_allowed_bundle_ids          → quit (browsers, VPN clients) — even during sessions
///   2. the intent screen itself          → allow (only from the IntentMode folder)
///   3. always_allowed_bundle_ids         → allow
///   4. in the current mode's apps        → allow if the signature matches team_id (and Chrome has no forbidden flags)
///   5. bundle under system_path_prefixes → allow (SIP-protected macOS internals: Dock, Finder, Spotlight…)
///   6. anything else                     → quit
final class AppWatcher {
    private enum Decision: Equatable { case allow, screen, kill(String) }
    private struct Entry { let start: UInt64; let decision: Decision; let generation: Int; let bundle: String }

    private let q = DispatchQueue(label: "intentmode.apps")
    private var config: IntentConfig
    private var policy = AppPolicy(apps: [], generation: -1, label: "locked")
    private var cache: [pid_t: Entry] = [:]
    private var bundleIds: [String: String] = [:]
    private var termSent: [pid_t: (start: UInt64, at: Date)] = [:]
    private var lastScreenSeen = Date()
    private var timer: DispatchSourceTimer?
    private var scans = 0

    init(config: IntentConfig) { self.config = config }

    func updateConfig(_ c: IntentConfig) {
        q.async { self.config = c; self.cache.removeAll() }
    }

    func setPolicy(_ p: AppPolicy) {
        q.async {
            self.policy = p
            self.cache.removeAll()
            self.scan()
        }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    /// The intent screen reports launches instantly; check that pid now.
    func hint(pid: pid_t) {
        q.async {
            self.cache[pid] = nil
            self.scan()
        }
    }

    // MARK: scanning

    private func scan() {
        scans += 1
        if scans % 1200 == 0 { bundleIds.removeAll() } // refresh every ~10 min
        guard let uid = consoleUID(), let name = userName(uid), name != "root" else { return }
        if config.exemptUsers.contains(name) { return }

        var alive = Set<pid_t>()
        var screenRunning = false
        for pid in allPids() where pid > 1 {
            guard let info = bsdInfo(pid), info.pbi_uid == uid else { continue }
            alive.insert(pid)
            let start = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
            let entry: Entry
            if let e = cache[pid], e.start == start, e.generation == policy.generation {
                entry = e
            } else {
                entry = evaluate(pid: pid, start: start)
                cache[pid] = entry
                if case .kill(let why) = entry.decision {
                    Log.info("quitting \(entry.bundle) (pid \(pid)): \(why) [\(policy.label)]")
                }
            }
            switch entry.decision {
            case .screen: screenRunning = true
            case .kill: enforce(pid: pid, start: start)
            case .allow: break
            }
        }
        cache = cache.filter { alive.contains($0.key) }
        termSent = termSent.filter { alive.contains($0.key) }

        if screenRunning {
            lastScreenSeen = Date()
        } else if Date().timeIntervalSince(lastScreenSeen) > 15 {
            lastScreenSeen = Date()
            Log.warn("intent screen not running for uid \(uid); relaunching it")
            DispatchQueue.global().async { ensureScreenAgent(uid: uid) }
        }
    }

    private func enforce(pid: pid_t, start: UInt64) {
        if let t = termSent[pid], t.start == start {
            if Date().timeIntervalSince(t.at) > Double(config.appKillGraceSeconds) { kill(pid, SIGKILL) }
        } else {
            kill(pid, SIGTERM)
            termSent[pid] = (start, Date())
        }
    }

    private func evaluate(pid: pid_t, start: UInt64) -> Entry {
        func entry(_ d: Decision, _ b: String) -> Entry { Entry(start: start, decision: d, generation: policy.generation, bundle: b) }
        guard let path = pidPath(pid) else { return entry(.allow, "?") }
        guard let bundle = outerBundle(path) else { return entry(.allow, path) } // command-line tool
        let bid = bundleId(bundle) ?? ""
        let label = bid.isEmpty ? bundle : bid

        if bid == Paths.screenBundleID && bundle.hasPrefix(Paths.base + "/") { return entry(.screen, label) }
        if config.neverAllowedBundleIds.contains(bid) { return entry(.kill("never allowed"), label) }
        if config.alwaysAllowedBundleIds.contains(bid) { return entry(.allow, label) }
        if let rule = policy.apps.first(where: { $0.bundleId == bid }) {
            if let team = rule.teamId, !signatureMatches(pid: pid, team: team) {
                return entry(.kill("code signature does not match team_id \(team)"), label)
            }
            if bid == config.chromeBundleId, path.hasPrefix(bundle + "/Contents/MacOS/"),
               let flag = forbiddenFlag(pid: pid) {
                return entry(.kill("Chrome was started with \(flag)"), label)
            }
            return entry(.allow, label)
        }
        if config.systemPathPrefixes.contains(where: { bundle.hasPrefix($0) }) { return entry(.allow, label) }
        return entry(.kill("not allowed in this mode"), label)
    }

    // MARK: process info (libproc / sysctl)

    private func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return got > 0 ? Array(pids.prefix(Int(got))) : []
    }

    private func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private func pidPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Helper.app/…" → "/Applications/Google Chrome.app"
    /// Apps nested inside a .framework (e.g. Python.framework/…/Python.app, which every `python3` runs from)
    /// are helpers of command-line tools, not apps the user opened: they're treated like CLI tools.
    private func outerBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        if let f = path.range(of: ".framework/"), f.lowerBound < r.lowerBound { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    private func bundleId(_ bundle: String) -> String? {
        if let c = bundleIds[bundle] { return c.isEmpty ? nil : c }
        let id = (NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String) ?? ""
        bundleIds[bundle] = id
        return id.isEmpty ? nil : id
    }

    /// Checks the running process's code signature (fast: the kernel tracks validity).
    private func signatureMatches(pid: pid_t, team: String) -> Bool {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        let reqText = team == "apple"
            ? "anchor apple"
            : "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqText as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    /// Returns the first forbidden command-line flag Chrome was started with, if any.
    private func forbiddenFlag(pid: pid_t) -> String? {
        let args = arguments(pid: pid)
        for a in args.dropFirst() {
            for f in config.chromeForbiddenFlags where a == f || a.hasPrefix(f + "=") { return f }
        }
        return nil
    }

    private func arguments(pid: pid_t) -> [String] {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        var len = buf.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &len, nil, 0) == 0, len > 4 else { return [] }
        let argc = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16 | Int(buf[3]) << 24
        var i = 4
        while i < len && buf[i] != 0 { i += 1 }   // executable path
        while i < len && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc && i < len {
            let s = i
            while i < len && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
