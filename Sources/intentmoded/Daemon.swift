import Foundation
import Darwin
import OpenDirectory
import IntentCore

/// The single source of truth. All state changes run on `queue`.
///
/// States: locked → session(mode, ends_at) → locked, plus learn(mode) in dev builds.
/// Fails closed: if this process dies, pf rules and the DNS setting stay in place
/// (nothing resolves, nothing connects) until launchd restarts it.
final class Daemon {
    private let queue = DispatchQueue(label: "intentmode.daemon")

    private enum Phase {
        case locked
        case session
        case learn(modeId: String, until: Date)
    }

    private var config: IntentConfig
    private var configMTime: Date?
    private var notice: String?
    private var blocklist = Blocklist()
    private var pstate = PersistentState.load()
    private var phase: Phase = .locked
    private var generation = 0
    /// Monotonic time (seconds since boot, paused during sleep) when +10 was requested.
    private var extensionRequestedAt: TimeInterval?
    private var tickCount = 0
    /// Set during a test install (test-mode.json). Everything is removed when it passes.
    private let testEndsAt: Date? = TestMode.load().map { Date(timeIntervalSince1970: $0.endsAt) }
    private var testStopping = false
    /// A start waiting out its mode's start_delay_seconds (monotonic `readyAt`).
    private struct PendingStart { let modeId: String; let intent: String; let readyAt: TimeInterval; let uid: uid_t }
    private var pendingStart: PendingStart?

    /// Open session (escape hatch) steps: reason → retype challenge → wait → start.
    private struct EscapeFlow {
        enum Stage: String { case challenge, waiting }
        let modeId: String
        let reason: String
        let challenge: String
        var stage: Stage
        var readyAt: TimeInterval?
    }
    private var escape: EscapeFlow?
    private var chromePolicyMissing = false
    private var statsCache: (at: Date, stats: WeekStats)?
    private var macUpdateAvailable = false
    private let clock = TrustedClock()
    private var lockdown: LockdownState? = Lockdown.load()
    private var pending: [PendingChange] = Lockdown.loadPending()
    private var macUpdateName: String?
    private var timer: DispatchSourceTimer?

    private let box: PolicyBox
    private let pf: PFManager
    private let dns: DNSServer
    private let dnsSettings = DNSSettingsEnforcer()
    private let apps: AppWatcher
    private let updater = Updater()
    private let refresher = BlocklistRefresher()
    private var control: ControlServer!

    init() {
        let fm = FileManager.default
        for dir in [Paths.base, Paths.versions, Paths.staging, Paths.learned] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        Self.upgradeConfigFile()
        var loaded: IntentConfig
        var notice: String?
        do {
            loaded = try IntentConfig.load(path: Paths.config)
            try? fm.removeItem(atPath: Paths.configLastGood)
            try? fm.copyItem(atPath: Paths.config, toPath: Paths.configLastGood)
        } catch {
            Log.error("\(error)")
            if let last = try? IntentConfig.load(path: Paths.configLastGood) {
                loaded = last
                notice = "config.json has an error — using the last good version. See daemon.log."
            } else {
                loaded = IntentConfig() // no modes: stays locked (fail closed)
                notice = "config.json could not be loaded — no modes available. See daemon.log."
            }
        }
        config = loaded
        self.notice = notice
        configMTime = FileUtil.mtime(Paths.config)
        let locked = Policy(kind: .locked, generation: 0, allow: DomainMatcher(entries: loaded.expand(loaded.lockedAllowedDomains)),
                            block: Blocklist(), allowAll: false, apps: [], safeSearch: true)
        box = PolicyBox(locked)
        pf = PFManager(config: loaded)
        dns = DNSServer(box: box, pf: pf, upstream: loaded.upstreamDns)
        apps = AppWatcher(config: Self.appsConfig(loaded, testMode: TestMode.load() != nil))
        blocklist = Self.loadBlocklist(loaded)
        control = ControlServer { [unowned self] req, uid in self.handle(req, uid: uid) }
    }

    /// Applies ConfigUpgrader to config.json using this version's bundled defaults.
    static func upgradeConfigFile() {
        let defaultsPath = Paths.current + "/Resources/config.default.json"
        guard let userData = try? Data(contentsOf: URL(fileURLWithPath: Paths.config)),
              let defData = try? Data(contentsOf: URL(fileURLWithPath: defaultsPath)),
              let user = try? JSONSerialization.jsonObject(with: userData) as? [String: Any],
              let defs = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return }
        var state = ConfigUpgrader.State()
        if let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.configUpgradeState)),
           let s = try? JSONDecoder().decode(ConfigUpgrader.State.self, from: d) { state = s }
        let (upgraded, notes, newState) = ConfigUpgrader.upgrade(user: user, defaults: defs, state: state)
        if !notes.isEmpty, let out = try? JSONSerialization.data(withJSONObject: upgraded, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            // Only write if the result is a valid config.
            if (try? IntentConfig.parse(out)) != nil {
                try? FileManager.default.copyItem(atPath: Paths.config, toPath: Paths.config + ".bak-\(Int(Date().timeIntervalSince1970))")
                try? FileUtil.writeAtomically(out + Data("\n".utf8), to: Paths.config, mode: 0o644)
                Log.info("config upgraded: " + notes.joined(separator: "; "))
            } else {
                Log.warn("config upgrade skipped: the result would not be valid")
                return
            }
        }
        if let d = try? JSONEncoder().encode(newState) { try? FileUtil.writeAtomically(d, to: Paths.configUpgradeState, mode: 0o644) }
    }

    /// Reads macOS's own update check results (no network needed here).
    private func checkMacUpdates() {
        DispatchQueue.global().async {
            let prefs = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.SoftwareUpdate.plist")
            let recommended = prefs?["RecommendedUpdates"] as? [[String: Any]] ?? []
            let count = (prefs?["LastRecommendedUpdatesAvailable"] as? Int) ?? recommended.count
            let name = recommended.first?["Display Name"] as? String
            self.queue.async {
                if (count > 0) != self.macUpdateAvailable { Log.info("macOS update available: \(count > 0) \(name ?? "")") }
                self.macUpdateAvailable = count > 0
                self.macUpdateName = name
            }
        }
    }

    // MARK: lifecycle

    func start() {
        Log.info("intentmoded \(BuildInfo.version)\(BuildInfo.isDevBuild ? " (dev build)" : "") starting")
        SessionLog.write(["event": "daemon_start", "version": BuildInfo.version])
        pf.onTableLost = { flushDNSCache() }
        pf.setup()
        dnsSettings.start()
        startDNS()
        do { try control.start() } catch { Log.error("\(error)") }

        queue.sync {
            if let s = pstate.session {
                if s.endsAt > clock.now(), config.mode(s.modeId) != nil {
                    phase = .session
                    Log.info("resuming \(s.modeId) session until \(s.endsAt)")
                } else {
                    SessionLog.write(["event": "session_end", "mode": s.modeId, "ended_early": false, "note": "ended while daemon was not running"])
                    pstate.session = nil
                    pstate.save()
                }
            }
            applyPolicy(reason: "startup")
        }
        apps.onScreenCrashLoop = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                // Only for versions that were just installed by an update; never loop rollbacks.
                guard let st = UpdateState.load(), st.previous != nil else { return }
                do {
                    let msg = try self.updater.rollback()
                    Log.warn("intent screen crash loop → \(msg)")
                    self.restartSoon()
                } catch { Log.error("intent screen crash loop, but no rollback possible: \(error)") }
            }
        }
        apps.start()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        // Tell intentguard we're healthy once everything has been up for a few seconds.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            try? FileUtil.writeAtomically(Data(BuildInfo.version.utf8), to: Paths.health, mode: 0o644)
            guard let self else { return }
            self.updater.prune(alsoKeep: self.pending.compactMap { $0.version })   // already on the daemon queue
        }
    }

    private func startDNS() {
        do { try dns.start() } catch {
            Log.error("\(error) — retrying in 5 s (nothing resolves meanwhile)")
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.startDNS() }
        }
    }

    /// SIGTERM: save and exit, leaving pf and DNS in place (fail closed).
    func shutdown() {
        queue.sync { pstate.save() }
        Log.info("intentmoded stopping (enforcement stays in place)")
    }

    /// In test mode Terminal is never quit, so there is always a way out.
    private static func appsConfig(_ c: IntentConfig, testMode: Bool) -> IntentConfig {
        guard testMode else { return c }
        var copy = c
        copy.alwaysAllowedBundleIds.append("com.apple.Terminal")
        return copy
    }

    private func tick() {
        tickCount += 1
        let jumped = clock.tick()
        if jumped || tickCount % 600 == 3 {
            let up = config.upstreamDns
            DispatchQueue.global().async { [clock] in clock.syncWithNetwork(upstream: up) }
        }
        let now = clock.now()
        if let t = testEndsAt, now >= t, !testStopping {
            Log.warn("test time is over; removing Intent Mode")
            _ = stopTest()
        }
        switch phase {
        case .session:
            if let s = pstate.session, now >= s.endsAt {
                endSession(early: false, reason: "time is up")
            } else if let s = pstate.session, let mode = config.mode(s.modeId) {
                if let b = config.bedtime, b.endIfActive(at: now) != nil, !b.allowedModes.contains(mode.id) {
                    endSession(early: false, reason: "bedtime")
                } else if let limit = idleLimitSeconds(mode), let idle = systemIdleSeconds(), idle >= Double(limit) {
                    endSession(early: true, reason: "no activity for \(limit / 60) minutes")
                }
            }
        case .learn(_, let until):
            if now >= until { _ = stopLearn(apply: false) }
        case .locked:
            if let p = pendingStart, ProcessInfo.processInfo.systemUptime > p.readyAt + 120 {
                Log.info("pending start of \(p.modeId) expired (not confirmed)")
                pendingStart = nil
            }
        }
        if tickCount % 5 == 2 { lockdownTick() }
        if tickCount % 5 == 0 {
            reloadConfigIfChanged()
            pf.watchdog()
        }
        if tickCount % 30 == 0 { pf.expire() }
        if tickCount % 60 == 5 { checkChromePolicy() }
        if tickCount % 600 == 7 { checkMacUpdates() }
        if tickCount % 60 == 0 {
            var inSession = false
            if case .session = phase { inSession = true }
            refresher.maybeRefresh(sources: config.blocklistSources, inSession: inSession) { [weak self] in
                self?.reloadBlocklist()
            }
        }
    }

    // MARK: policy

    /// Builds the always-on blocklist: the list files plus always_blocked_domains, minus exceptions.
    static func loadBlocklist(_ c: IntentConfig) -> Blocklist {
        var m = DomainMatcher()
        for f in c.blocklistFiles {
            let path = f.hasPrefix("/") ? f : Paths.base + "/" + f
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                Log.warn("blocklist file missing: \(path)")
                continue
            }
            for e in DomainMatcher.entries(fromListFile: text) { m.add(e) }
        }
        for e in c.expand(c.alwaysBlockedDomains) { m.add(e) }
        let exceptions = Set(c.blocklistExceptions.map { DomainMatcher.normalize($0.hasPrefix("=") ? String($0.dropFirst()) : $0) })
        Log.info("blocklist loaded: \(m.count) entries, \(exceptions.count) exceptions")
        return Blocklist(matcher: m, exceptions: exceptions)
    }

    /// Swap in a freshly loaded blocklist (after a config change or a weekly list refresh).
    func reloadBlocklist() {
        let c = queue.sync { config }
        let b = Self.loadBlocklist(c)          // slow (~1 s): done off the daemon queue
        queue.async {
            self.blocklist = b
            self.refreshPolicyInPlace()
        }
    }

    private func makePolicy(generation g: Int) -> Policy {
        switch phase {
        case .locked:
            return Policy(kind: .locked, generation: g, allow: DomainMatcher(entries: config.expand(config.lockedAllowedDomains)),
                          block: blocklist, allowAll: false, apps: [], safeSearch: config.forceSafeSearch)
        case .session:
            let mode = pstate.session.flatMap { config.mode($0.modeId) }
            if let mode, mode.isOpenWeb {
                // Open web: everything except the always-on blocklist and the mode's blocked_domains.
                return Policy(kind: .session, generation: g, allow: DomainMatcher(entries: ["*"]), block: blocklist,
                              modeBlock: DomainMatcher(entries: config.blockedDomains(for: mode)),
                              allowAll: true, apps: mode.apps, safeSearch: config.forceSafeSearch)
            }
            return Policy(kind: .session, generation: g, allow: DomainMatcher(entries: mode.map { config.domains(for: $0) } ?? []),
                          block: blocklist, allowAll: false, apps: mode?.apps ?? [], safeSearch: config.forceSafeSearch)
        case .learn(let id, _):
            return Policy(kind: .learn, generation: g, allow: DomainMatcher(entries: ["*"]),
                          block: blocklist, allowAll: true, apps: config.mode(id)?.apps ?? [], safeSearch: config.forceSafeSearch)
        }
    }

    private var policyLabel: String {
        switch phase {
        case .locked: return "locked"
        case .session: return "session:\(pstate.session?.modeId ?? "?")"
        case .learn(let id, _): return "learn:\(id)"
        }
    }

    /// Full switch: new generation, pf table emptied, connections cut, DNS cache flushed, apps re-checked.
    private func applyPolicy(reason: String) {
        generation += 1
        let p = makePolicy(generation: generation)
        pf.reset(generation: generation)   // before publishing, so in-flight answers for the old policy are dropped
        box.set(p)
        flushDNSCache()
        apps.setPolicy(AppPolicy(apps: p.apps, generation: generation, label: policyLabel))
        Log.info("policy → \(policyLabel) (\(reason))")
    }

    /// Config edit during a session: update lists without cutting connections.
    private func refreshPolicyInPlace() {
        let p = makePolicy(generation: generation)
        box.set(p)
        apps.setPolicy(AppPolicy(apps: p.apps, generation: generation, label: policyLabel)) // setPolicy re-checks every app
    }

    private func reloadConfigIfChanged(force: Bool = false, trusted: Bool = false) {
        let m = FileUtil.mtime(Paths.config)
        guard force || m != configMTime else { return }
        configMTime = m
        do {
            let c = try IntentConfig.load(path: Paths.config)
            // During lock-down, a direct edit of config.json that loosens anything is undone.
            if lockdown != nil && !trusted {
                let diff = ConfigDiff.classify(old: config, new: c)
                if !diff.isTightening || !diff.rejected.isEmpty {
                    Log.warn("lock-down: direct config edit loosens (\(diff.loosening.joined(separator: ", "))) — restoring the previous config")
                    try? FileManager.default.removeItem(atPath: Paths.config)
                    try? FileManager.default.copyItem(atPath: Paths.configLastGood, toPath: Paths.config)
                    configMTime = FileUtil.mtime(Paths.config)
                    notice = "A direct edit of config.json was undone (lock-down). Use “Edit Settings” instead."
                    return
                }
            }
            config = c
            notice = nil
            blocklist = Self.loadBlocklist(c)
            try? FileManager.default.removeItem(atPath: Paths.configLastGood)
            try? FileManager.default.copyItem(atPath: Paths.config, toPath: Paths.configLastGood)
            pf.updateConfig(c)
            dns.setUpstream(c.upstreamDns)
            apps.updateConfig(Self.appsConfig(c, testMode: testEndsAt != nil))
            if case .session = phase, let s = pstate.session, c.mode(s.modeId) == nil {
                endSession(early: true, reason: "mode was removed from config")
            } else {
                refreshPolicyInPlace()
            }
            Log.info("config reloaded")
        } catch {
            notice = "config.json has an error — still using the previous version. See daemon.log."
            Log.error("config reload failed, keeping previous config: \(error)")
        }
    }

    // MARK: requests

    func handle(_ r: IPCRequest, uid: uid_t) -> IPCResponse {
        let t0 = Date()
        var waited = 0.0
        let resp: IPCResponse = queue.sync {
            waited = Date().timeIntervalSince(t0)
            return handleOnQueue(r, uid: uid)
        }
        let took = Date().timeIntervalSince(t0)
        if r.cmd != "status" && r.cmd != "app_launched" {
            Log.info("request \(r.cmd)\(r.mode.map { " \($0)" } ?? "") from uid \(uid) → \(resp.ok ? "ok" : "failed: \(resp.error ?? "")") (\(String(format: "%.2f", took)) s)")
        } else if took > 1 {
            Log.warn("slow \(r.cmd) request: waited \(String(format: "%.2f", waited)) s, total \(String(format: "%.2f", took)) s")
        }
        return resp
    }

    private func handleOnQueue(_ r: IPCRequest, uid: uid_t) -> IPCResponse {
        switch r.cmd {
        case "ping":
            return .success("pong")
        case "status":
            return IPCResponse(ok: true, status: status(uid: uid))
        case "start":
            return start(modeId: r.mode ?? "", intent: r.intent ?? "", uid: uid)
        case "stats":
            var r = IPCResponse(ok: true)
            r.stats = weekStats()
            return r
        case "escape_request":
            return escapeRequest(modeId: r.mode ?? "", reason: r.reason ?? "")
        case "escape_challenge":
            return escapeChallenge(typed: r.intent ?? "")
        case "escape_confirm":
            return escapeConfirm(uid: uid)
        case "escape_cancel":
            if let e = escape {
                Log.info("open session request cancelled (stage: \(e.stage.rawValue))")
                SessionLog.write(["event": "escape_cancelled", "mode": e.modeId, "stage": e.stage.rawValue, "reason": e.reason])
            }
            escape = nil
            return .success("Cancelled.")
        case "note_add":
            let text = (r.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .fail("Empty note.") }
            var notes = pstate.notes ?? []
            guard notes.count < 30 else { return .fail("You have 30 notes already — delete some first.") }
            notes.append(NoteItem(id: UUID().uuidString, text: String(text.prefix(300)), created: Date().timeIntervalSince1970))
            pstate.notes = notes
            pstate.save()
            return .success("Saved.")
        case "note_delete":
            pstate.notes = (pstate.notes ?? []).filter { $0.id != r.noteId }
            pstate.save()
            return .success()
        case "start_confirm":
            return confirmStart(uid: uid)
        case "start_cancel":
            if let p = pendingStart { Log.info("start of \(p.modeId) cancelled during the pause") }
            pendingStart = nil
            return .success("Cancelled.")
        case "end":
            guard case .session = phase else { return .fail("No session is running.") }
            endSession(early: true, reason: r.reason?.isEmpty == false ? r.reason! : "ended early")
            return .success("Session ended.")
        case "extend_request":
            return extendRequest()
        case "extend_confirm":
            return extendConfirm(reason: r.reason ?? "")
        case "app_launched":
            if let pid = r.pid { apps.hint(pid: pid) }
            return .success()
        case "reload":
            guard uid == 0 else { return .fail("Run this with sudo.") }
            reloadConfigIfChanged(force: true)
            return notice == nil ? .success("Config reloaded.") : .fail(notice!)
        case "learn_start":
            guard lockdown == nil else { return .fail("learn is off during lock-down.") }
            guard BuildInfo.isDevBuild else { return .fail("learn is only available in dev builds.") }
            guard uid == 0 else { return .fail("Run this with sudo.") }
            return startLearn(modeId: r.mode ?? "")
        case "learn_stop":
            guard BuildInfo.isDevBuild else { return .fail("learn is only available in dev builds.") }
            guard uid == 0 else { return .fail("Run this with sudo.") }
            return stopLearn(apply: r.apply ?? false)
        case "lockdown_enable":
            return lockdownEnable(r, uid: uid)
        case "lockdown_disable_request":
            guard var l = lockdown else { return .fail("Lock-down is not on.") }
            guard l.escapeAvailable else { return .fail("The one-time turn-off is no longer available.") }
            guard l.disableRequestedAt == nil else { return .fail("Turn-off is already requested.") }
            l.disableRequestedAt = clock.now().timeIntervalSince1970
            lockdown = l; Lockdown.save(l)
            Log.warn("lock-down turn-off requested (takes effect in \(config.disableDelayHours) h)")
            SessionLog.write(["event": "lockdown_disable_requested"])
            return .success("Lock-down turns off in \(Self.hours(config.disableDelayHours)). You can cancel until then.")
        case "lockdown_disable_cancel":
            guard var l = lockdown, l.disableRequestedAt != nil else { return .fail("No turn-off is pending.") }
            l.disableRequestedAt = nil
            lockdown = l; Lockdown.save(l)
            Log.info("lock-down turn-off cancelled")
            SessionLog.write(["event": "lockdown_disable_cancelled"])
            return .success("Cancelled. Lock-down stays on.")
        case "lockdown_keep":
            guard var l = lockdown, l.escapeAvailable else { return .fail("Nothing to confirm.") }
            guard (r.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == Lockdown.keepPhrase else {
                return .fail("Type exactly: \(Lockdown.keepPhrase)")
            }
            l.escapeAvailable = false
            l.disableRequestedAt = nil
            lockdown = l; Lockdown.save(l)
            Lockdown.markEscapeUsed()
            Log.warn("lock-down confirmed for good: the one-time turn-off is gone")
            SessionLog.write(["event": "lockdown_kept"])
            return .success("Confirmed. The turn-off option is gone for good.")
        case "config_propose":
            return configPropose(path: r.path ?? "")
        case "pending_cancel":
            guard let i = pending.firstIndex(where: { $0.id == r.noteId }) else { return .fail("Not found.") }
            let p = pending.remove(at: i)
            Lockdown.savePending(pending)
            if let f = p.file { try? FileManager.default.removeItem(atPath: f) }
            if let v = p.version, v != BuildInfo.version { try? FileManager.default.removeItem(atPath: Paths.versions + "/" + v) }
            Log.info("pending change cancelled: \(p.description)")
            SessionLog.write(["event": "pending_cancelled", "kind": p.kind, "description": p.description])
            return .success("Cancelled.")
        case "update_propose":
            guard let p = r.path else { return .fail("missing path") }
            if lockdown != nil {
                do {
                    let (v, changelog) = try updater.stage(path: p)
                    let due = clock.now().addingTimeInterval(config.looseningDelayHours * 3600)
                    pending.removeAll { $0.kind == "update" && $0.version == v }
                    pending.append(PendingChange(id: UUID().uuidString, kind: "update", description: "Update to \(v)",
                                                 dueAt: due.timeIntervalSince1970, version: v, changelog: changelog))
                    Lockdown.savePending(pending)
                    SessionLog.write(["event": "update_proposed", "to": v])
                    return .success("Update \(v) is checked and waiting. It installs in \(Self.hours(config.looseningDelayHours)) (lock-down). Cancel it on the lock screen if you change your mind.")
                } catch { return .fail("\(error)") }
            }
            do {
                let msg = try updater.propose(path: p)
                restartSoon()
                return .success(msg)
            } catch { return .fail("\(error)") }
        case "update_rollback":
            do {
                let msg = try updater.rollback()
                restartSoon()
                return .success(msg)
            } catch { return .fail("\(error)") }
        case "update_list":
            return IPCResponse(ok: true, lines: updater.list())
        case "emergency_off":
            return emergencyOff(r, uid: uid)
        default:
            return .fail("unknown command '\(r.cmd)'")
        }
    }

    /// Is the Chrome policy profile installed? (Checked off the daemon queue every minute.)
    private func checkChromePolicy() {
        DispatchQueue.global().async {
            let managed = FileManager.default.fileExists(atPath: "/Library/Managed Preferences/com.google.Chrome.plist")
            let listed = run("/usr/bin/profiles", ["list", "-all"], timeout: 15).out.contains("com.intentmode.chrome")
            let missing = !(managed || listed)
            self.queue.async {
                if missing != self.chromePolicyMissing { Log.info("Chrome policy profile installed: \(!missing)") }
                self.chromePolicyMissing = missing
            }
        }
    }

    private func idleLimitSeconds(_ m: ModeConfig) -> Int? {
        let minutes = m.idleEndMinutes ?? config.idleEndMinutes
        return minutes > 0 ? minutes * 60 : nil
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private func availability(_ m: ModeConfig) -> (Bool, String?) {
        let now = clock.now()
        if let b = config.bedtime, let end = b.endIfActive(at: now), !b.allowedModes.contains(m.id) {
            return (false, "Bedtime until \(Self.clock(end))")
        }
        if m.isEscapeHatch, let q = config.quietHours.first(where: { $0.endIfActive(at: now) != nil }),
           let end = q.endIfActive(at: now) {
            return (false, "Quiet hours until \(Self.clock(end))")
        }
        if m.scheduleEnd(at: now) == nil {
            return (false, "Only " + (m.schedule ?? []).map { $0.label }.joined(separator: ", "))
        }
        if let cd = m.cooldownMinutes, cd > 0, let last = pstate.lastEnded?[m.id] {
            let again = last.addingTimeInterval(Double(cd) * 60)
            if again > now { return (false, "Available again at \(Self.clock(again))") }
        }
        let used = pstate.used(m.id)
        if let limit = m.dailyLimit, used >= limit {
            return (false, limit == 0 ? "Disabled" : "Used \(used) of \(limit) today")
        }
        if let limit = m.weeklyLimit {
            let week = pstate.usedThisWeek(m.id)
            if week >= limit { return (false, "Used \(week) of \(limit) this week — resets Monday") }
        }
        return (true, nil)
    }

    private func status(uid: uid_t) -> DaemonStatus {
        let modes = config.modes.map { m -> ModeStatus in
            let (ok, why) = availability(m)
            var ms = ModeStatus(id: m.id, name: m.name, description: m.description, minutes: m.minutes,
                                dailyLimit: m.dailyLimit, usedToday: pstate.used(m.id), available: ok, unavailableReason: why)
            ms.weeklyLimit = m.weeklyLimit
            ms.usedThisWeek = pstate.usedThisWeek(m.id)
            ms.openWeb = m.isOpenWeb
            ms.intentMinWords = config.intentMinWords(for: m)
            ms.startDelaySeconds = m.startDelaySeconds ?? 0
            ms.escapeHatch = m.isEscapeHatch
            ms.corner = m.showAs == "corner"
            return ms
        }
        let exempt = userName(uid).map { config.exemptUsers.contains($0) } ?? false
        var st = DaemonStatus(state: "locked", version: BuildInfo.version, devBuild: BuildInfo.isDevBuild, modes: modes,
                              intentMinWords: config.intentMinWords, extensionMinReasonWords: config.extensionMinReasonWords,
                              extensionMinutes: config.extensionMinutes, exempt: exempt, notice: notice)
        st.testEndsAt = testEndsAt?.timeIntervalSince1970
        st.notes = pstate.notes ?? []
        st.chromePolicyMissing = chromePolicyMissing
        st.macUpdateAvailable = macUpdateAvailable
        if let l = lockdown {
            st.lockdownActive = true
            st.lockdownEscapeAvailable = l.escapeAvailable
            st.lockdownDisableHours = config.disableDelayHours
            if let req = l.disableRequestedAt {
                st.lockdownDisableIn = max(0, Int(req + config.disableDelayHours * 3600 - clock.now().timeIntervalSince1970))
            }
        }
        st.pending = pending.map { PendingItem(id: $0.id, kind: $0.kind, description: $0.description,
                                               dueIn: max(0, Int($0.dueAt - clock.now().timeIntervalSince1970))) }
        st.macUpdateName = macUpdateName
        st.escapeReasonMinWords = config.escapeReasonMinWords
        if let e = escape {
            st.escapeStage = e.stage.rawValue
            st.escapeModeName = config.mode(e.modeId)?.name ?? e.modeId
            st.escapeReason = e.reason
            if e.stage == .challenge { st.escapeChallenge = e.challenge }
            if let r = e.readyAt { st.escapeReadyIn = max(0, Int((r - ProcessInfo.processInfo.systemUptime).rounded(.up))) }
        }
        if statsCache == nil || Date().timeIntervalSince(statsCache!.at) > 10 { statsCache = (Date(), weekStats()) }
        let today = StatsBuilder.today(statsCache!.stats)
        st.todayMinutes = today.minutes
        st.todaySessions = today.sessions
        if let b = config.bedtime, let end = b.endIfActive(at: clock.now()) {
            let names = b.allowedModes.compactMap { config.mode($0)?.name }
            st.bedtimeNotice = "Bedtime until \(Self.clock(end))" + (names.isEmpty ? " — everything is locked" : " — only \(names.joined(separator: ", "))")
        }
        if case .session = phase, let s = pstate.session, let mode = config.mode(s.modeId), let limit = idleLimitSeconds(mode) {
            st.idleLimitSeconds = limit
            st.idleSeconds = systemIdleSeconds().map { Int($0) }
        }
        if case .locked = phase, let p = pendingStart {
            st.pendingModeId = p.modeId
            st.pendingModeName = config.mode(p.modeId)?.name ?? p.modeId
            st.pendingIntent = p.intent
            st.pendingReadyIn = max(0, Int((p.readyAt - ProcessInfo.processInfo.systemUptime).rounded(.up)))
        }
        switch phase {
        case .locked:
            break
        case .session:
            guard let s = pstate.session else { break }
            let mode = config.mode(s.modeId)
            let remaining = max(0, Int(s.endsAt.timeIntervalSince(clock.now()).rounded()))
            st.state = "session"
            st.modeId = s.modeId
            st.modeName = mode?.name ?? s.modeId
            st.intent = s.intent
            st.endsAt = s.endsAt.timeIntervalSince1970
            st.remainingSeconds = remaining
            st.warning = remaining <= config.warningSeconds
            st.extended = s.extended
            if mode?.allowExtension == false || config.extensionMinutes == 0 {
                st.extensionState = "unavailable"
            } else if s.extended {
                st.extensionState = "used"
            } else if let at = extensionRequestedAt {
                let left = Double(config.extensionWaitSeconds) - (ProcessInfo.processInfo.systemUptime - at)
                st.extensionState = left > 0 ? "waiting" : "ready"
                st.extensionReadyIn = left > 0 ? Int(left.rounded(.up)) : 0
            } else {
                st.extensionState = "available"
            }
        case .learn(let id, let until):
            st.state = "learn"
            st.modeId = id
            st.modeName = "Learn: " + (config.mode(id)?.name ?? id)
            st.endsAt = until.timeIntervalSince1970
            st.remainingSeconds = max(0, Int(until.timeIntervalSinceNow))
        }
        return st
    }

    private func start(modeId: String, intent: String, uid: uid_t) -> IPCResponse {
        guard case .locked = phase else { return .fail("A session is already running.") }
        guard let mode = config.mode(modeId) else { return .fail("Unknown mode '\(modeId)'.") }
        if mode.isEscapeHatch { return .fail("\(mode.name) has its own steps (reason, retype, wait) — start it from the intent screen.") }
        let text = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = TextUtil.wordCount(text)
        let minWords = config.intentMinWords(for: mode)
        guard words >= minWords else {
            return .fail("Describe what you're here for in at least \(minWords) words (you have \(words)).")
        }
        let (ok, why) = availability(mode)
        guard ok else { return .fail("\(mode.name) is not available: \(why ?? "")") }

        if let delay = mode.startDelaySeconds, delay > 0 {
            pendingStart = PendingStart(modeId: mode.id, intent: text,
                                        readyAt: ProcessInfo.processInfo.systemUptime + Double(delay), uid: uid)
            Log.info("start of \(mode.id) requested; pausing \(delay) s")
            var r = IPCResponse(ok: true, message: "\(mode.name) opens in \(delay) seconds.")
            r.waitSeconds = delay
            return r
        }
        return beginSession(mode: mode, intent: text, uid: uid)
    }

    // MARK: lock-down (Phase 4)

    static func hours(_ h: Double) -> String { h >= 1 ? "\(Int(h.rounded())) hours" : "\(Int((h * 60).rounded())) minutes" }

    private func lockdownEnable(_ r: IPCRequest, uid: uid_t) -> IPCResponse {
        guard uid == 0 else { return .fail("Run this with sudo (it's the last time you'll need it).") }
        guard testEndsAt == nil else { return .fail("Lock-down needs the permanent install, not the test.") }
        guard lockdown == nil else { return .fail("Lock-down is already on.") }
        guard let user = r.username ?? consoleUID().flatMap(userName), user != "root" else { return .fail("Couldn't tell which account to lock down.") }
        if let err = Lockdown.installSudoersRule(user: user) { return .fail("Couldn't block sudo: \(err)") }
        let l = LockdownState(enabledAt: clock.now().timeIntervalSince1970, user: user, escapeAvailable: !Lockdown.escapeWasUsed, disableRequestedAt: nil)
        lockdown = l
        Lockdown.save(l)
        Log.warn("LOCK-DOWN ON for '\(user)' (one-time turn-off available: \(l.escapeAvailable))")
        SessionLog.write(["event": "lockdown_enabled", "user": user])
        return .success("Lock-down is on. sudo is blocked for \(user); loosening changes now wait \(Self.hours(config.looseningDelayHours)).")
    }

    private func lockdownDisable(reason: String) {
        guard let l = lockdown else { return }
        Lockdown.removeSudoersRule()
        Lockdown.markEscapeUsed()
        lockdown = nil
        Lockdown.save(nil)
        Log.warn("LOCK-DOWN OFF for '\(l.user)' (\(reason)); the one-time turn-off is now used up")
        SessionLog.write(["event": "lockdown_disabled", "reason": reason])
        notice = "Lock-down is off. sudo works again; you can uninstall or keep using Intent Mode without lock-down."
    }

    /// Every 5 s: keep the sudo rule in place, finish a requested turn-off, apply due pending changes.
    private func lockdownTick() {
        let now = clock.now().timeIntervalSince1970
        if let l = lockdown {
            if !FileManager.default.fileExists(atPath: Lockdown.sudoersPath) {
                Log.warn("lock-down: sudo rule was removed — restoring it")
                _ = Lockdown.installSudoersRule(user: l.user)
            }
            if let req = l.disableRequestedAt, now >= req + config.disableDelayHours * 3600 {
                lockdownDisable(reason: "requested turn-off took effect")
            }
        }
        guard let due = pending.first(where: { $0.dueAt <= now }) else { return }
        pending.removeAll { $0.id == due.id }
        Lockdown.savePending(pending)
        switch due.kind {
        case "config":
            guard let f = due.file, let data = try? Data(contentsOf: URL(fileURLWithPath: f)) else { return }
            defer { try? FileManager.default.removeItem(atPath: f) }
            if let base = due.baseHash, base != Lockdown.sha(Paths.config) {
                Log.warn("pending config change dropped: config.json changed since it was proposed")
                notice = "A pending settings change was dropped because the settings changed in between. Propose it again."
                return
            }
            applyConfig(data, note: "pending change applied")
        case "update":
            guard let v = due.version else { return }
            do {
                _ = try updater.activate(version: v, changelog: due.changelog ?? "")
                restartSoon()
            } catch { Log.error("pending update \(v) failed: \(error)") }
        default: break
        }
    }

    private func applyConfig(_ data: Data, note: String) {
        try? FileManager.default.copyItem(atPath: Paths.config, toPath: Paths.config + ".bak-\(Int(Date().timeIntervalSince1970))")
        do { try FileUtil.writeAtomically(data, to: Paths.config, mode: 0o644) } catch { Log.error("could not write config: \(error)"); return }
        reloadConfigIfChanged(force: true, trusted: true)
        Log.info("config: \(note)")
        SessionLog.write(["event": "config_applied", "note": note])
    }

    private func configPropose(path: String) -> IPCResponse {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return .fail("Can't read \(path).") }
        let new: IntentConfig
        do { new = try IntentConfig.parse(data) } catch { return .fail("\(error)") }
        let diff = ConfigDiff.classify(old: config, new: new)
        if !diff.rejected.isEmpty { return .fail("Not allowed: " + diff.rejected.joined(separator: "; ")) }
        guard diff.changed else { return .success("Nothing changed.") }
        if lockdown == nil || diff.isTightening {
            applyConfig(data, note: diff.isTightening ? "tightening change applied" : "change applied (no lock-down)")
            return .success(diff.isTightening ? "Applied (tightening applies at once)." : "Applied.")
        }
        try? FileManager.default.createDirectory(atPath: Lockdown.pendingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let file = Lockdown.pendingDir + "/\(id).json"
        do { try FileUtil.writeAtomically(data, to: file, mode: 0o600) } catch { return .fail("\(error)") }
        let desc = "Settings: " + diff.loosening.prefix(3).joined(separator: ", ") + (diff.loosening.count > 3 ? " …" : "")
        pending.append(PendingChange(id: id, kind: "config", description: desc,
                                     dueAt: clock.now().addingTimeInterval(config.looseningDelayHours * 3600).timeIntervalSince1970,
                                     file: file, baseHash: Lockdown.sha(Paths.config)))
        Lockdown.savePending(pending)
        SessionLog.write(["event": "config_proposed", "loosening": diff.loosening])
        return IPCResponse(ok: true, message: "This loosens: \(diff.loosening.joined(separator: "; ")). It applies in \(Self.hours(config.looseningDelayHours)) — cancel it on the lock screen if you change your mind.")
    }

    // MARK: open session (escape hatch)

    private static func makeChallenge(length: Int) -> String {
        // Letters, digits and punctuation; look-alikes (l/1/I, O/0) and quotes left out so it's fair to type.
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!?.,;:-+=*#%&()")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &rng)! })
    }

    private func escapeRequest(modeId: String, reason: String) -> IPCResponse {
        guard case .locked = phase else { return .fail("A session is already running.") }
        guard escape == nil else { return .fail("An open session request is already in progress.") }
        guard let mode = config.mode(modeId), mode.isEscapeHatch else { return .fail("Unknown open-session mode.") }
        let (ok, why) = availability(mode)
        guard ok else { return .fail("\(mode.name) is not available: \(why ?? "")") }
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = TextUtil.wordCount(text)
        guard words >= config.escapeReasonMinWords else {
            return .fail("Give a reason of at least \(config.escapeReasonMinWords) words (you have \(words)).")
        }
        escape = EscapeFlow(modeId: mode.id, reason: text, challenge: Self.makeChallenge(length: config.escapeChallengeLength),
                            stage: .challenge, readyAt: nil)
        Log.info("open session requested")
        SessionLog.write(["event": "escape_requested", "mode": mode.id, "reason": text])
        return .success("Now retype the text exactly.")
    }

    private func escapeChallenge(typed: String) -> IPCResponse {
        guard var e = escape, e.stage == .challenge else { return .fail("No retype step is waiting.") }
        guard typed == e.challenge else { return .fail("That doesn't match. Start the retype again.") }
        e.stage = .waiting
        e.readyAt = ProcessInfo.processInfo.systemUptime + Double(config.escapeWaitMinutes) * 60
        escape = e
        Log.info("open session: challenge passed, waiting \(config.escapeWaitMinutes) min")
        return .success("Waiting \(config.escapeWaitMinutes) minutes.")
    }

    private func escapeConfirm(uid: uid_t) -> IPCResponse {
        guard let e = escape, e.stage == .waiting, let ready = e.readyAt else { return .fail("Nothing is waiting to start.") }
        guard ProcessInfo.processInfo.systemUptime >= ready else { return .fail("The waiting time isn't over yet.") }
        escape = nil
        guard let mode = config.mode(e.modeId) else { return .fail("Unknown mode.") }
        let (ok, why) = availability(mode)
        guard ok else { return .fail("\(mode.name) is not available: \(why ?? "")") }
        SessionLog.write(["event": "escape_started", "mode": mode.id, "reason": e.reason])
        return beginSession(mode: mode, intent: e.reason, uid: uid)
    }

    // MARK: stats

    private func weekStats() -> WeekStats {
        let log = (try? String(contentsOfFile: Paths.sessionLog, encoding: .utf8)) ?? ""
        var names: [String: String] = [:]
        for m in config.modes { names[m.id] = m.name }
        var running: StatsBuilder.Running?
        if case .session = phase, let s = pstate.session { running = .init(mode: s.modeId, intent: s.intent, started: s.startedAt) }
        let escapeModes = Set(config.modes.filter { $0.isEscapeHatch }.map { $0.id })
        let limit = config.modes.first(where: { $0.isEscapeHatch })?.weeklyLimit
        return StatsBuilder.build(log: log, modeNames: names, escapeModes: escapeModes, escapeLimit: limit, running: running)
    }

    /// Second step of a delayed start, after the pause.
    private func confirmStart(uid: uid_t) -> IPCResponse {
        guard case .locked = phase else { return .fail("A session is already running.") }
        guard let p = pendingStart else { return .fail("Nothing is waiting to start.") }
        let left = p.readyAt - ProcessInfo.processInfo.systemUptime
        guard left <= 0 else { return .fail("Wait \(Int(left.rounded(.up))) more seconds.") }
        pendingStart = nil
        guard let mode = config.mode(p.modeId) else { return .fail("Unknown mode '\(p.modeId)'.") }
        let (ok, why) = availability(mode)
        guard ok else { return .fail("\(mode.name) is not available: \(why ?? "")") }
        return beginSession(mode: mode, intent: p.intent, uid: uid)
    }

    /// Sessions of modes not allowed at bedtime end when bedtime starts.
    /// Sessions end when bedtime starts (unless the mode is allowed then) and when their schedule window closes.
    private func capAtBedtime(_ end: Date, mode: ModeConfig, now: Date) -> Date {
        var capped = end
        if let windowEnd = mode.scheduleEnd(at: now) { capped = min(capped, windowEnd) }
        guard let b = config.bedtime, !b.allowedModes.contains(mode.id), let start = b.nextStart(after: now) else { return capped }
        return min(capped, start)
    }

    private func beginSession(mode: ModeConfig, intent text: String, uid: uid_t) -> IPCResponse {
        pendingStart = nil
        let now = clock.now()
        let ends = capAtBedtime(now.addingTimeInterval(Double(mode.minutes) * 60), mode: mode, now: now)
        guard ends.timeIntervalSince(now) >= 60 else { return .fail("Less than a minute left in this mode's time window.") }
        pstate.session = SessionRecord(modeId: mode.id, intent: text, startedAt: now, endsAt: ends, extended: false)
        pstate.increment(mode.id)
        pstate.save()
        phase = .session
        extensionRequestedAt = nil
        applyPolicy(reason: "session started")
        SessionLog.write(["event": "session_start", "mode": mode.id, "intent": text, "minutes": mode.minutes, "uid": Int(uid)])
        let launch = mode.launch ?? mode.apps.prefix(1).map { LaunchItem(bundleId: $0.bundleId) }
        return IPCResponse(ok: true, message: "\(mode.name) for \(mode.minutes) minutes.", launch: launch)
    }

    private func endSession(early: Bool, reason: String) {
        guard case .session = phase, let s = pstate.session else { return }
        SessionLog.write(["event": "session_end", "mode": s.modeId, "intent": s.intent,
                          "started": ISO8601DateFormatter().string(from: s.startedAt),
                          "extended": s.extended, "extension_reason": s.extensionReason ?? "",
                          "ended_early": early, "reason": reason])
        pstate.session = nil
        var ended = pstate.lastEnded ?? [:]
        ended[s.modeId] = clock.now()
        pstate.lastEnded = ended
        pstate.save()
        phase = .locked
        extensionRequestedAt = nil
        statsCache = nil
        applyPolicy(reason: "session ended: \(reason)")
    }

    private func extendRequest() -> IPCResponse {
        guard case .session = phase, let s = pstate.session else { return .fail("No session is running.") }
        guard !s.extended else { return .fail("This session was already extended.") }
        guard config.mode(s.modeId)?.allowExtension != false, config.extensionMinutes > 0 else {
            return .fail("This mode can't be extended.")
        }
        if extensionRequestedAt == nil { extensionRequestedAt = ProcessInfo.processInfo.systemUptime }
        return .success("Wait \(config.extensionWaitSeconds) seconds, then type your reason.")
    }

    private func extendConfirm(reason: String) -> IPCResponse {
        guard case .session = phase, var s = pstate.session else { return .fail("No session is running.") }
        guard !s.extended else { return .fail("This session was already extended.") }
        guard let at = extensionRequestedAt else { return .fail("Request the extension first.") }
        guard ProcessInfo.processInfo.systemUptime - at >= Double(config.extensionWaitSeconds) else {
            return .fail("The waiting time isn't over yet.")
        }
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TextUtil.wordCount(text) >= config.extensionMinReasonWords else {
            return .fail("Give a reason of at least \(config.extensionMinReasonWords) words.")
        }
        if let mode = config.mode(s.modeId) {
            s.endsAt = capAtBedtime(s.endsAt.addingTimeInterval(Double(config.extensionMinutes) * 60), mode: mode, now: clock.now())
        } else {
            s.endsAt = s.endsAt.addingTimeInterval(Double(config.extensionMinutes) * 60)
        }
        s.extended = true
        s.extensionReason = text
        pstate.session = s
        pstate.save()
        extensionRequestedAt = nil
        SessionLog.write(["event": "session_extended", "mode": s.modeId, "reason": text])
        Log.info("session extended by \(config.extensionMinutes) min")
        return .success("+\(config.extensionMinutes) minutes.")
    }

    // MARK: learn (dev builds)

    private func startLearn(modeId: String) -> IPCResponse {
        guard case .locked = phase else { return .fail("End the running session first.") }
        guard let mode = config.mode(modeId) else { return .fail("Unknown mode '\(modeId)'.") }
        _ = box.takeLearned()
        phase = .learn(modeId: mode.id, until: Date().addingTimeInterval(Double(config.learnMaxMinutes) * 60))
        applyPolicy(reason: "learn started")
        return .success("""
            Learn mode for '\(mode.name)' is on for up to \(config.learnMaxMinutes) minutes.
            Every website is reachable now (except the adult filter). Use the mode's apps the way you normally would,
            then run:  sudo intentmode learn stop          (shows the new domains)
                  or:  sudo intentmode learn stop --apply  (also adds them to the mode in config.json)
            """)
    }

    private func stopLearn(apply: Bool) -> IPCResponse {
        guard case .learn(let id, _) = phase else { return .fail("Learn mode is not running.") }
        let names = box.takeLearned()
        var lines: [String] = []
        if let mode = config.mode(id) {
            let known = DomainMatcher(entries: config.domains(for: mode))
            lines = names.filter { $0.contains(".") && !known.matches($0) && !blocklist.blocks($0) && !$0.hasSuffix(".arpa") }.sorted()
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let file = Paths.learned + "/\(id)-\(stamp).txt"
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: file))
            if apply && !lines.isEmpty {
                do {
                    try ConfigEditor.addDomains(lines, toMode: id, path: Paths.config)
                } catch {
                    phase = .locked
                    applyPolicy(reason: "learn stopped")
                    return IPCResponse(ok: false, error: "Could not update config.json: \(error)", lines: lines)
                }
            }
        }
        phase = .locked
        applyPolicy(reason: "learn stopped")
        if apply { reloadConfigIfChanged(force: true) }
        let msg = lines.isEmpty ? "No new domains were seen." :
            (apply ? "Added \(lines.count) domains to '\(id)' in config.json:" : "\(lines.count) new domains (not added; use --apply to add them):")
        return IPCResponse(ok: true, message: msg, lines: lines)
    }

    // MARK: emergency off & restart

    /// Test mode: uninstall everything (logs are kept in /Users/Shared/IntentMode/last-test-logs).
    private func stopTest() -> IPCResponse {
        testStopping = true
        SessionLog.write(["event": "test_stopped"])
        guard spawnDetached("/bin/bash", [Paths.uninstallScript, "--yes", "--delay"]) else {
            testStopping = false
            return .fail("Could not start the uninstaller. Restart your Mac: test mode always switches off on restart.")
        }
        return .success("Turning Intent Mode off. This takes a few seconds.")
    }

    private func emergencyOff(_ r: IPCRequest, uid: uid_t) -> IPCResponse {
        if lockdown != nil && uid != 0 {
            return .fail("Emergency off is disabled during lock-down.")
        }
        if testEndsAt != nil {
            Log.warn("test stopped from the intent screen (uid \(uid))")
            return stopTest()
        }
        guard BuildInfo.isDevBuild else { return .fail("emergency-off is only available in dev builds.") }
        if uid != 0 {
            guard let u = r.username, let p = r.password, Self.verifyAdmin(user: u, password: p) else {
                Log.warn("emergency-off: wrong admin credentials (uid \(uid))")
                return .fail("That is not a valid admin name and password.")
            }
        }
        Log.warn("EMERGENCY OFF requested (uid \(uid))")
        SessionLog.write(["event": "emergency_off", "uid": Int(uid)])
        guard spawnDetached("/bin/bash", [Paths.emergencyScript, "--delay"]) else {
            return .fail("Could not start \(Paths.emergencyScript). Run it with sudo from a Terminal.")
        }
        return .success("Emergency off is running. Enforcement stops in a few seconds.")
    }

    static func verifyAdmin(user: String, password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let rec = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try rec.verifyPassword(password)
        } catch {
            return false
        }
        return run("/usr/sbin/dseditgroup", ["-o", "checkmember", "-m", user, "admin"]).ok
    }

    /// After an update or rollback: restart the intent screen, then exit so intentguard starts the new `current`.
    private func restartSoon() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if let uid = consoleUID() {
                run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(Paths.agentLabel)"])
            }
            Log.info("exiting for restart")
            exit(0)
        }
    }
}
